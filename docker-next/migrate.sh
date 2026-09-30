#!/bin/bash
# SwanLab Self-Hosted 存量迁移脚本（旧版 docker/ → docker-next 架构）
#
# 用法: ./migrate.sh [旧运行目录，默认 ./swanlab] [--fast] [--to <新目录>] [--offline|-o] [--yes|-y]
# 示例:
#   ./migrate.sh /opt/swanlab                       # 默认档：排空后原地升级（推荐）
#   ./migrate.sh /opt/swanlab --fast                # 跳过排空（接受窗口内未消费指标丢失）
#   ./migrate.sh /opt/swanlab --to /data2/swanlab   # 排空后 rsync 数据到新目录，旧目录原样保留
#   ./migrate.sh /opt/swanlab -o -y                 # 离线镜像 + 免确认（自动化场景）
#
# 边界（plan §11 定稿）：仅支持「旧版全 local 部署 → docker-next 全 local 形态」。
#   旧版（fluent-bit 链路）本身无外接形态；借迁移同时切外接会叠加变更变量，且需真正的
#   数据导出导入（pg dump/restore、S3 对象拷贝），均不属于架构迁移职责。
#   迁移完成后如需外接：./configure.sh <运行目录>（有数据组件的搬迁单独规划）。
#
# 数据完整性：
#   - pg/redis/CH/minio 数据目录原地不动（同版本停机文件级复制合法，凭据沿用旧值）
#   - schema 由 swanlab-server 启动命令（prisma migrate deploy，advisory lock 串行化）自动升级
#   - 旧 fluent-bit / swanlab-house 卷（metrics.log 链路）在新架构无消费方，排空后即可清理
#   - pg_dump 快照兜底（默认启用，失败即中止迁移，旧栈不做任何变更）
#
# 回滚：迁移不修改任何数据文件，恢复旧 compose/.env 后 up 即回退（见收尾输出）。
set -o pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

LEGACY_DIR="swanlab"
FAST=0
TO_DIR=""
OFFLINE=0
ASSUME_YES=0

while [ $# -gt 0 ]; do
  case "$1" in
    --fast) FAST=1; shift ;;
    --to) [ -n "${2:-}" ] || die "选项 --to 需要参数"; TO_DIR="$2"; shift 2 ;;
    --offline|-o) OFFLINE=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    -*) die "未知选项: $1" ;;
    *) LEGACY_DIR="$1"; shift ;;
  esac
done

echo "${bold}===== SwanLab Self-Hosted 存量迁移（docker → docker-next）=====${reset}"

require_docker
require_compose_v224
resolve_docker_socket_path
SOCKET_PATH="${DOCKER_SOCKET_PATH}"

# 确认交互（非交互环境必须显式 --yes）
confirm_or_die() {
  local prompt="$1"
  if [ "$ASSUME_YES" -eq 1 ]; then return 0; fi
  if [ ! -t 0 ]; then
    die "非交互环境需要 --yes 显式确认（当前操作: ${prompt}）"
  fi
  read -p "${prompt} (y/N): " ANS_MIGRATE
  [[ "$ANS_MIGRATE" =~ ^[Yy]$ ]] || die "已取消"
}

# ---------------- 1. 旧目录校验（识别旧架构 + 全 local 形态） ----------------
LEGACY_COMPOSE="${LEGACY_DIR}/docker-compose.yaml"
LEGACY_ENV="${LEGACY_DIR}/.env"
{ [ -f "$LEGACY_ENV" ] && [ -f "$LEGACY_COMPOSE" ]; } \
  || die "${LEGACY_DIR} 不是旧版运行目录（缺少 .env / docker-compose.yaml）"

grep -q 'swanlab-fluentbit' "$LEGACY_COMPOSE" \
  || die "未在 ${LEGACY_COMPOSE} 中检测到 swanlab-fluentbit——不是旧版（fluent-bit 链路）部署；已迁移过请使用 upgrade.sh"

for svc in postgres redis clickhouse minio; do
  grep -qE "^  ${svc}:" "$LEGACY_COMPOSE" \
    || die "旧 compose 缺少 ${svc} 服务定义——migrate.sh 仅支持标准「全 local」形态（四件套本机容器）；请先恢复标准形态或参考 docker-next/README.md「迁移边界」"
done

# 旧 .env 五变量（旧版 install.sh 生成；凭据必须沿用——数据目录已按旧凭据初始化）
PG_PASS=$(env_get POSTGRES_PASSWORD "$LEGACY_ENV")
CH_PASS=$(env_get CLICKHOUSE_PASSWORD "$LEGACY_ENV")
MINIO_PASS=$(env_get MINIO_ROOT_PASSWORD "$LEGACY_ENV")
DATA_PATH_V=$(env_get DATA_PATH "$LEGACY_ENV"); [ -z "$DATA_PATH_V" ] && DATA_PATH_V="./data"
DATA_PATH_V="${DATA_PATH_V%/}"
EXPOSE_PORT_V=$(env_get EXPOSE_PORT "$LEGACY_ENV"); [ -z "$EXPOSE_PORT_V" ] && EXPOSE_PORT_V="8000"
{ [ -n "$PG_PASS" ] && [ -n "$CH_PASS" ] && [ -n "$MINIO_PASS" ]; } \
  || die "旧 .env 缺少凭据（POSTGRES_PASSWORD / CLICKHOUSE_PASSWORD / MINIO_ROOT_PASSWORD），无法迁移"

# 旧版本（仅展示；旧版版本硬编码在 compose 镜像 tag 中）
LEGACY_VERSION=$(grep -oE 'swanlab-server:v[0-9]+\.[0-9]+\.[0-9]+' "$LEGACY_COMPOSE" | head -1 | sed 's/.*:v//')
TARGET_VERSION=$(env_get SWANLAB_VERSION "${SCRIPT_DIR}/.env.example")
[ -n "$TARGET_VERSION" ] || die "模板 .env.example 缺少 SWANLAB_VERSION"

# ---------------- 2. 旧栈运行状态（排空与 pg_dump 依赖） ----------------
for c in swanlab-postgres swanlab-redis swanlab-clickhouse swanlab-minio swanlab-fluentbit swanlab-house swanlab-server; do
  running=$(docker ps --filter "name=^/${c}$" --format '{{.Names}}' 2>/dev/null)
  [ "$running" = "$c" ] \
    || die "旧栈容器 ${c} 未在运行——迁移要求旧栈完整运行（数据层四件套 + 摄入链路）；请先在 ${LEGACY_DIR} 执行 docker compose up -d 后重试"
done

# ---------------- 3. 项目一致性（项目名 swanlab 由新栈原地接管） ----------------
if foreign_project_container "$LEGACY_DIR"; then
  die "compose 项目 swanlab 存在其他目录的容器: ${FOREIGN_CONTAINER}（working_dir ${FOREIGN_WD}）——疑似已有 docker-next 部署；请先处理该部署（down 或迁移其目录）后重试"
fi

# ---------------- 4. --to 档校验 ----------------
LEGACY_ABS=$(cd "$LEGACY_DIR" && pwd)
if [ -n "$TO_DIR" ]; then
  command -v rsync >/dev/null 2>&1 || die "--to 档需要 rsync（未安装）"
  if [ -e "$TO_DIR" ] && [ -n "$(ls -A "$TO_DIR" 2>/dev/null)" ]; then
    die "目标目录已存在且非空: ${TO_DIR}"
  fi
  case "$DATA_PATH_V" in
    /*) die "--to 档不支持绝对路径 DATA_PATH（${DATA_PATH_V}，数据不随目录迁移）；请使用默认档原地迁移" ;;
  esac
fi

# ---------------- 5. 磁盘预检 ----------------
# 默认档原地：40Gi 运行余量（同 install 口径；vector 缓冲最坏 30Gi 与数据同盘）
# --to 档：另需容纳整份数据副本（用量 + 40Gi）
case "$DATA_PATH_V" in
  /*) DISK_CHECK_PATH="$DATA_PATH_V" ;;
  *)  DISK_CHECK_PATH="${LEGACY_ABS}/${DATA_PATH_V}" ;;
esac
if [ -n "$TO_DIR" ]; then
  USED_KB=$(du -sk "$DISK_CHECK_PATH" 2>/dev/null | awk '{print $1}')
  [ -n "$USED_KB" ] || die "无法统计数据目录用量: ${DISK_CHECK_PATH}"
  NEED_GIB=$(( USED_KB / 1024 / 1024 + 40 ))
  log_info "--to 档磁盘预检：数据用量 $(( USED_KB / 1024 / 1024 ))GiB，要求剩余 ≥ ${NEED_GIB}GiB（数据副本 + 运行余量）"
  check_disk_space "$TO_DIR" "$NEED_GIB" confirm
else
  check_disk_space "$DISK_CHECK_PATH" 40 confirm
fi

# ---------------- 6. 迁移摘要与确认 ----------------
MODE_DESC="默认档（排空后原地升级）"
[ "$FAST" -eq 1 ] && MODE_DESC="--fast 档（跳过排空等待，接受未消费指标丢失）"
[ -n "$TO_DIR" ]  && MODE_DESC="--to 档（排空后 rsync 数据到 ${TO_DIR}，旧目录原样保留）"

echo
echo "${bold}----- 迁移摘要 -----${reset}"
echo "  旧架构:   fluent-bit 链路 v${LEGACY_VERSION:-未知}（${LEGACY_ABS}）"
echo "  目标:     docker-next v${TARGET_VERSION}（$([ -n "$TO_DIR" ] && echo "$TO_DIR" || echo "原地 ${LEGACY_ABS}")）"
echo "  模式:     ${MODE_DESC}"
echo "  端口:     ${EXPOSE_PORT_V}    数据目录: ${DATA_PATH_V}"
echo "  数据层:   全 local（pg/redis/CH/minio 本机容器，凭据与数据目录沿用）"
echo "  业务副本: server/auth/house/next ×2，cloud ×1（对齐 k8s chart）"
echo
log_warn "迁移为停机操作：down 旧栈 → up 新栈期间服务不可用（分钟级）"
confirm_or_die "确认开始迁移?"

if [ "$FAST" -eq 1 ]; then
  log_warn "--fast 将跳过排空等待（摄入源仍会先断开再 down）：迁移窗口内已写入但未消费到 ClickHouse 的指标将随旧卷废弃而丢失"
  confirm_or_die "   确认接受数据丢失并继续?"
fi

# ---------------- 7. 配置快照 + pg_dump 兜底 ----------------
BACKUP_DIR="${LEGACY_DIR}/backups/pre-migrate-$(date +%Y%m%d%H%M%S)"
mkdir -p "$BACKUP_DIR"
cp "$LEGACY_COMPOSE" "$LEGACY_ENV" "$BACKUP_DIR/" \
  || die "配置快照失败（${BACKUP_DIR}）——旧栈未做任何变更"
{
  echo "date=$(date '+%Y-%m-%dT%H:%M:%S%z')"
  echo "from=legacy-fluentbit v${LEGACY_VERSION:-unknown}"
  echo "to=docker-next v${TARGET_VERSION}"
  echo "mode=${MODE_DESC%%（*}"
  echo "hostname=$(hostname 2>/dev/null)"
} > "$BACKUP_DIR/metadata.txt"
log_ok "配置快照: ${BACKUP_DIR}"

log_info "pg_dump 数据库快照（兜底，失败即中止、旧栈不变）..."
docker exec swanlab-postgres pg_dump -U swanlab -d app 2>/dev/null | gzip > "${BACKUP_DIR}/pg_snapshot.sql.gz" \
  || die "pg_dump 失败——迁移中止，旧栈未做任何变更（可 docker logs swanlab-postgres 排查）"
log_ok "数据库快照: ${BACKUP_DIR}/pg_snapshot.sql.gz"

# 排空判定轮询（第 9 节调用）：断开摄入（stop house/server）后 metrics.log 不再有新写入
# （mtime 必然静止，无信息量），实际判据为 ClickHouse 活跃 parts 行数连续 3 次采样稳定
# = fluent-bit 已消费完存量
drain_poll() {
  local last="" cur stable=0 failures=0 deadline=$((SECONDS + 150))
  log_info "排空判定：轮询 ClickHouse 行数（5s 间隔，连续 3 次稳定即完成，超时 150s）"
  while [ $SECONDS -lt $deadline ]; do
    cur=$(docker exec swanlab-clickhouse clickhouse-client \
            --user swanlab --password "$CH_PASS" \
            --query "SELECT sum(rows) FROM system.parts WHERE active AND database = 'app'" 2>/dev/null)
    if [ -z "$cur" ]; then
      failures=$((failures + 1))
      [ "$failures" -ge 3 ] && return 1
    else
      failures=0
      if [ "$cur" = "$last" ]; then
        stable=$((stable + 1))
        [ "$stable" -ge 2 ] && { log_ok "排空完成（ClickHouse 行数稳定: ${cur} rows）"; return 0; }
      else
        stable=0
      fi
      last="$cur"
    fi
    sleep 5
  done
  return 1
}

# ---------------- 8. 断开摄入（所有档位统一执行，含 --fast） ----------------
# --fast 也断摄入：down 杀容器时 house 可能正在 append metrics.log（截断行），
# 先 stop 数秒即可消除该竞态；区别仅在是否等待 fluent-bit 消费完存量
log_info "停止摄入源（swanlab-house / swanlab-server）..."
(cd "$LEGACY_DIR" && docker compose stop swanlab-house swanlab-server) \
  || die "stop 失败——旧栈状态未知，请在 ${LEGACY_DIR} 执行 docker compose ps 检查后重试"

# 中止路径：恢复旧栈摄入源后退出（数据零丢失；fluent-bit 继续消费存量，可随时重试）
abort_restore() {
  log_warn "中止迁移：恢复旧栈摄入源（house / server）..."
  (cd "$LEGACY_DIR" && docker compose start swanlab-house swanlab-server) \
    || log_err "恢复失败，请手动执行: (cd ${LEGACY_DIR} && docker compose start swanlab-house swanlab-server)"
  die "迁移已中止（数据未受影响；重试时会再次断开摄入并等待排空）"
}

# ---------------- 9. 排空判定（默认档 / --to 档等待；--fast 跳过等待） ----------------
if [ "$FAST" -eq 0 ]; then
  waited_once=0
  while :; do
    if drain_poll; then break; fi
    # 超时或无法判定：--yes 自动化 → 再等一轮，仍超时则中止保数据（无人值守取向是不丢数据）；
    # 交互 → 三选一（再等 / 接受丢失 / 中止恢复）；非交互无 --yes → 中止保数据
    if [ "$ASSUME_YES" -eq 1 ]; then
      if [ "$waited_once" -eq 1 ]; then
        log_err "排空连续两轮超时（ClickHouse 查询失败或行数持续增长）"
        abort_restore
      fi
      waited_once=1
      log_warn "排空超时（--yes 自动化：再等一轮，仍超时将中止保数据）"
      continue
    fi
    if [ ! -t 0 ]; then
      log_err "排空超时且非交互环境无法确认"
      abort_restore
    fi
    read -p "排空超时或无法判定: [w]再等一轮 / [y]接受丢失继续迁移 / [n]中止并恢复旧栈: " ANS_DRAIN
    case "$ANS_DRAIN" in
      [wW]*) log_info "再等一轮排空..."; continue ;;
      [yY]*) log_warn "接受未消费指标丢失，继续迁移"; break ;;
      *)     abort_restore ;;
    esac
  done
else
  log_warn "--fast：跳过排空等待，未消费指标将随旧卷废弃而丢失（摄入源已断开，down 无写入竞态）"
fi

# ---------------- 10. down 旧栈 ----------------
log_info "停止旧栈（docker compose down；数据卷与 bind mount 均保留）..."
(cd "$LEGACY_DIR" && docker compose down) \
  || die "down 失败——旧栈可能部分停止，请在 ${LEGACY_DIR} 执行 docker compose ps 检查；数据未受影响"

# ---------------- 11. 目标目录准备（默认档原地 / --to 档 rsync） ----------------
if [ -n "$TO_DIR" ]; then
  TO_ABS=$(cd "$(dirname "$TO_DIR")" && pwd)/$(basename "$TO_DIR")
  mkdir -p "${TO_ABS}/${DATA_PATH_V}"
  log_info "rsync 数据目录 ${DISK_CHECK_PATH} → ${TO_ABS}/${DATA_PATH_V} ..."
  rsync -a "${DISK_CHECK_PATH}/" "${TO_ABS}/${DATA_PATH_V}/" \
    || die "rsync 失败——旧目录原样保留，可重试；目标半成品目录: ${TO_ABS}"
  log_ok "数据副本完成（旧目录原样保留: ${LEGACY_ABS}）"
  DEST_DIR="$TO_DIR"
else
  # 原地档：旧 compose/.env 就地备份为 .legacy.bak（目录内随手可回滚，快照目录另有完整副本）
  cp "$LEGACY_COMPOSE" "${LEGACY_DIR}/docker-compose.legacy.yaml.bak"
  cp "$LEGACY_ENV" "${LEGACY_DIR}/.env.legacy.bak"
  DEST_DIR="$LEGACY_DIR"
fi

# ---------------- 12. 铺设新模板 + 生成新 .env ----------------
# 以 .env.example 为基底生成（键清单随模板演进，零漂移）；仅覆盖迁移确定的键，
# COMPOSE_PROFILES 固定四件套全开、SS_STORAGE_TYPE 固定 local（迁移流程零外接分支）
log_info "铺设 docker-next 模板到 ${DEST_DIR} ..."
cp -f "${SCRIPT_DIR}/docker-compose.yaml" "${DEST_DIR}/"
rm -rf "${DEST_DIR}/config"
cp -r "${SCRIPT_DIR}/config" "${DEST_DIR}/config"

cp "${SCRIPT_DIR}/.env.example" "${DEST_DIR}/.env"
chmod 600 "${DEST_DIR}/.env"
env_set SWANLAB_VERSION      "$TARGET_VERSION" "${DEST_DIR}/.env"
env_set EXPOSE_PORT          "$EXPOSE_PORT_V"  "${DEST_DIR}/.env"
env_set DATA_PATH            "$DATA_PATH_V"    "${DEST_DIR}/.env"
env_set DOCKER_SOCKET_PATH   "$SOCKET_PATH"    "${DEST_DIR}/.env"
env_set COMPOSE_PROFILES     "postgres,redis,clickhouse,minio" "${DEST_DIR}/.env"
env_set SS_STORAGE_TYPE      "local"           "${DEST_DIR}/.env"
env_set POSTGRES_PASSWORD    "$PG_PASS"        "${DEST_DIR}/.env"
env_set CLICKHOUSE_PASSWORD  "$CH_PASS"        "${DEST_DIR}/.env"
env_set MINIO_ROOT_PASSWORD  "$MINIO_PASS"     "${DEST_DIR}/.env"
log_ok "已生成 ${DEST_DIR}/.env（沿用旧凭据与端口；外接变量全部留空 = 本机默认）"

# ---------------- 13. 防呆校验 + 渲染 + 镜像 ----------------
validate_env "${DEST_DIR}/.env" || die "迁移生成的 .env 校验失败（旧栈已 down；回滚见下方提示）"
render_check "$DEST_DIR"

rollback_hint() {
  echo "   回滚（恢复旧架构，数据层未做任何修改）:"
  if [ -n "$TO_DIR" ]; then
    echo "     1. (cd ${DEST_DIR} && docker compose down)"
    echo "     2. (cd ${LEGACY_ABS} && docker compose up -d)     # 旧目录原样保留"
  else
    echo "     1. (cd ${LEGACY_DIR} && docker compose down)"
    echo "     2. cp docker-compose.legacy.yaml.bak docker-compose.yaml && cp .env.legacy.bak .env"
    echo "     3. (cd ${LEGACY_DIR} && docker compose up -d)"
  fi
}

pull_images "$DEST_DIR" "$OFFLINE" \
  || { log_err "镜像不可用（旧栈已 down）"; rollback_hint; exit 1; }

# ---------------- 14. 启动新栈 + 健康等待 ----------------
log_info "启动 docker-next（docker compose up -d，server 自动执行 schema 迁移）..."
(cd "$DEST_DIR" && docker compose up -d) || { log_err "up -d 失败"; rollback_hint; exit 1; }
wait_services_healthy "$DEST_DIR" || { log_err "服务未恢复健康"; rollback_hint; exit 1; }

# ---------------- 15. 收尾 ----------------
echo
echo "${green}${bold}迁移完成: 旧版(fluent-bit) v${LEGACY_VERSION:-unknown} → docker-next v${TARGET_VERSION}${reset}"
print_access_urls "$EXPOSE_PORT_V"
echo "📁 运行目录: ${DEST_DIR}（数据 ${DATA_PATH_V}，原地未动/已复制）"
echo "🧰 快照: ${BACKUP_DIR}（含旧 compose / .env / pg_snapshot.sql.gz）"
echo
echo "${bold}----- 后续操作 -----${reset}"
echo "  1. 日常巡检:    ${SCRIPT_DIR}/check.sh ${DEST_DIR}"
echo "  2. 切外接依赖:  ${SCRIPT_DIR}/configure.sh ${DEST_DIR}（迁移固定全 local；切外接在此操作，pg/CH/S3 有数据时搬迁单独规划）"
echo "  3. 稳定运行后清理无消费方的旧卷（丢弃未排空的残留缓冲）:"
echo "       docker volume rm swanlab-house fluent-bit"
[ -n "$TO_DIR" ] && echo "  4. 旧目录 ${LEGACY_ABS} 原样保留（回切旧架构需先 down 新栈）"
echo
echo "${bold}----- 回滚（如需恢复旧架构）-----${reset}"
rollback_hint

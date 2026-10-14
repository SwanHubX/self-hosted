#!/bin/bash
# SwanLab Self-Hosted 迁移脚本（旧版 docker → docker-v2）
#
# 用法: ./migrate.sh <旧 swanlab 运行目录> [--to <新目录>] [--offline|-o] [--yes|-y]
# 示例:
#   ./migrate.sh /opt/swanlab                       # 原地迁移
#   ./migrate.sh /opt/swanlab --to /data2/swanlab   # 迁移数据到新目录，保留旧目录
#   ./migrate.sh /opt/swanlab -o -y                 # 离线镜像与免交互确认
#
# 功能：
#   将旧版 SwanLab（docker 单实例架构）迁移至 docker-v2 架构。
#
# 实现思路：
#   1. 校验旧版运行目录与服务运行状态。
#   2. 备份旧版配置文件（compose 与 .env）。
#   3. 停止摄入服务并等待 ClickHouse 数据排空。
#   4. 停止旧版容器，铺设 docker-v2 配置文件并合并环境变量。
#   5. 启动 docker-v2 服务并等待健康检查通过。
set -o pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

# 新栈项目名固定 swanlab，原地迁移依赖同名网络与容器前缀
PROJECT_NAME="swanlab"
# 旧栈业务容器列表
LEGACY_CONTAINERS="swanlab-postgres swanlab-redis swanlab-clickhouse swanlab-minio swanlab-fluentbit swanlab-house swanlab-server"

LEGACY_DIR=""
TO_DIR=""
OFFLINE=0
ASSUME_YES=0

usage() {
  cat <<'EOF'
用法: ./migrate.sh <旧 swanlab 运行目录> [--to <新目录>] [--offline|-o] [--yes|-y]

  <旧 swanlab 运行目录>  必填：旧版（fluent-bit 链路）部署目录，须显式传入（无默认值）
  --to <目录>            排空后 rsync 数据到新目录，旧目录原样保留（缺省 = 原地迁移）
  -o, --offline          离线/内网：不拉取镜像，改为校验本地镜像齐备
  -y, --yes              免交互确认（非交互环境必须显式指定）

示例:
  ./migrate.sh /opt/swanlab
  ./migrate.sh /opt/swanlab --to /data2/swanlab
  ./migrate.sh /opt/swanlab -o -y
EOF
}

# ---------------- 0. 参数解析（严格：无默认目录、无 --fast） ----------------
while [ $# -gt 0 ]; do
  case "$1" in
    --to)
      [ -n "${2:-}" ] || { log_err "选项 --to 需要参数"; usage; exit 1; }
      TO_DIR="$2"; shift 2 ;;
    --offline|-o) OFFLINE=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --fast)
      log_err "--fast 已移除：迁移统一为「断开摄入 → 等待 ClickHouse 排空 → 下线旧栈」标准流线，不再提供丢数据分支"
      usage; exit 1 ;;
    -*)
      log_err "未知选项: $1"; usage; exit 1 ;;
    *)
      if [ -n "$LEGACY_DIR" ]; then
        log_err "多余的位置参数: $1"; usage; exit 1
      fi
      LEGACY_DIR="$1"; shift ;;
  esac
done

if [ -z "$LEGACY_DIR" ]; then
  log_err "必须显式指定旧版运行目录"
  usage
  exit 1
fi

echo "${bold}===== SwanLab Self-Hosted 存量迁移（docker → docker-v2）=====${reset}"

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
# -P：获取物理真实路径，用于比对容器 label
LEGACY_ABS=$(cd "$LEGACY_DIR" && pwd -P)

grep -q 'swanlab-fluentbit' "$LEGACY_COMPOSE" \
  || die "未在 ${LEGACY_COMPOSE} 中检测到 swanlab-fluentbit——不是旧版（fluent-bit 链路）部署；已迁移过请使用 upgrade.sh"

for svc in postgres redis clickhouse minio; do
  grep -qE "^  ${svc}:" "$LEGACY_COMPOSE" \
    || die "旧 compose 缺少 ${svc} 服务定义——migrate.sh 仅支持标准「全 local」形态（四件套本机容器）；请先恢复标准形态或参考 docker-v2/README.md「迁移边界」"
done

# 读取旧版凭据与配置
PG_PASS=$(env_get POSTGRES_PASSWORD "$LEGACY_ENV")
CH_PASS=$(env_get CLICKHOUSE_PASSWORD "$LEGACY_ENV")
MINIO_PASS=$(env_get MINIO_ROOT_PASSWORD "$LEGACY_ENV")
DATA_PATH_V=$(env_get DATA_PATH "$LEGACY_ENV"); [ -z "$DATA_PATH_V" ] && DATA_PATH_V="./data"
DATA_PATH_V="${DATA_PATH_V%/}"
EXPOSE_PORT_V=$(env_get EXPOSE_PORT "$LEGACY_ENV"); [ -z "$EXPOSE_PORT_V" ] && EXPOSE_PORT_V="8000"
{ [ -n "$PG_PASS" ] && [ -n "$CH_PASS" ] && [ -n "$MINIO_PASS" ]; } \
  || die "旧 .env 缺少凭据（POSTGRES_PASSWORD / CLICKHOUSE_PASSWORD / MINIO_ROOT_PASSWORD），无法迁移"

# 读取旧版本号
LEGACY_VERSION=$(grep -oE 'swanlab-server:v[0-9]+\.[0-9]+\.[0-9]+' "$LEGACY_COMPOSE" | head -1 | sed 's/.*:v//')
TARGET_VERSION=$(env_get SWANLAB_VERSION "${SCRIPT_DIR}/.env.example")
[ -n "$TARGET_VERSION" ] || die "模板 .env.example 缺少 SWANLAB_VERSION"

# ---------------- 2. 检查旧栈运行状态 ----------------
for c in $LEGACY_CONTAINERS; do
  running=$(docker ps --filter "name=^/${c}$" --format '{{.Names}}' 2>/dev/null)
  [ "$running" = "$c" ] \
    || die "旧栈容器 ${c} 未在运行——迁移要求旧栈完整运行（数据层四件套 + 摄入链路）；请先在 ${LEGACY_ABS} 执行 docker compose up -d 后重试"
done

# ---------------- 3. 项目一致性检查 ----------------
# 判定项目中是否存在非旧版 compose 定义的容器。
# 若容器工作目录不同但服务均定义在旧版 compose 中，允许继续迁移；
# 若存在未定义的服务，判定为存在其他部署，终止执行。
project_containers_within_legacy_compose() {
  local ids id svc
  ids=$(docker ps -a --filter "label=com.docker.compose.project=${PROJECT_NAME}" --format '{{.ID}}' 2>/dev/null)
  for id in $ids; do
    svc=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.service"}}' "$id" 2>/dev/null)
    grep -qE "^  ${svc}:" "$LEGACY_COMPOSE" 2>/dev/null || return 1
  done
  return 0
}

if foreign_project_container "$LEGACY_DIR" "$PROJECT_NAME"; then
  if project_containers_within_legacy_compose; then
    log_warn "compose 项目 ${PROJECT_NAME} 的容器 ${FOREIGN_CONTAINER} 记录的启动目录为 ${FOREIGN_WD}，与传入目录 ${LEGACY_ABS} 不一致"
    log_warn "旧运行目录应是被移动/重命名过（容器 label 停留在旧路径）；这些容器即本次要迁移的旧栈，继续迁移"
  else
    die "compose 项目 ${PROJECT_NAME} 存在其他目录的容器: ${FOREIGN_CONTAINER}
     • 容器记录的启动目录: ${FOREIGN_WD}
     • 本次传入的目录:     ${LEGACY_ABS}
  两者不一致，且容器不属于 ${LEGACY_COMPOSE} 定义的服务（疑似另一份 docker-v2/docker 部署）。
  两栈并存时 down 会互相接管容器，因此拒绝迁移。请确认传入目录是否为旧版运行目录；
  若确为另一份部署，请先在它的运行目录执行 docker compose down 后重试。"
  fi
fi

# ---------------- 4. --to 档校验 ----------------
if [ -n "$TO_DIR" ]; then
  command -v rsync >/dev/null 2>&1 || die "--to 档需要 rsync（未安装）"
  if [ -e "$TO_DIR" ] && [ -n "$(ls -A "$TO_DIR" 2>/dev/null)" ]; then
    die "目标目录已存在且非空: ${TO_DIR}"
  fi
  case "$DATA_PATH_V" in
    /*) die "--to 档不支持绝对路径 DATA_PATH（${DATA_PATH_V}，数据不随目录迁移）；请改用原地迁移" ;;
  esac
fi

# ---------------- 5. 磁盘预检 ----------------
# 原地迁移预留 40GiB 运行余量；--to 模式额外计入数据目录体积
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
echo
echo "${bold}----- 迁移摘要 -----${reset}"
echo "  旧架构:   docker（fluent-bit 链路）v${LEGACY_VERSION:-未知}（${LEGACY_ABS}）"
echo "  目标:     docker-v2 v${TARGET_VERSION}（$([ -n "$TO_DIR" ] && echo "$TO_DIR" || echo "原地 ${LEGACY_ABS}")）"
echo "  端口:     ${EXPOSE_PORT_V}    数据目录: ${DATA_PATH_V}"
echo "  数据层:   全 local（pg/redis/CH/minio 本机容器，凭据与数据目录沿用）"
echo "  业务副本: server/auth/house/next ×2，cloud ×1（可在新 .env 调整）"
echo
log_warn "迁移为停机操作：down 旧栈 → up 新栈期间服务不可用（分钟级）"
confirm_or_die "确认开始迁移?"

# ---------------- 7. 备份旧版配置文件 ----------------
BACKUP_DIR="${LEGACY_ABS}/backups/pre-migrate-$(date +%Y%m%d%H%M%S)"
mkdir -p "$BACKUP_DIR"
cp "$LEGACY_COMPOSE" "$LEGACY_ENV" "$BACKUP_DIR/" \
  || die "配置快照失败（${BACKUP_DIR}）——旧栈未做任何变更"
{
  echo "date=$(date '+%Y-%m-%dT%H:%M:%S%z')"
  echo "from=docker(fluent-bit) v${LEGACY_VERSION:-unknown}"
  echo "to=docker-v2 v${TARGET_VERSION}"
  echo "dir=${LEGACY_ABS}"
  echo "hostname=$(hostname 2>/dev/null)"
} > "$BACKUP_DIR/metadata.txt"
# 在运行目录备份旧版 compose 与 .env 文件
cp "$LEGACY_COMPOSE" "${LEGACY_ABS}/docker-compose.legacy.yaml.bak"
cp "$LEGACY_ENV" "${LEGACY_ABS}/.env.legacy.bak"
log_ok "配置快照: ${BACKUP_DIR}（compose / .env / metadata；数据卷未做快照——未修改即可回滚）"

# 排空判定：停止摄入后，轮询 ClickHouse 活跃 parts 行数。连续采样稳定表示存量数据写入完成。
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

# ---------------- 8. 停止摄入服务 ----------------
log_info "停止摄入源（swanlab-house / swanlab-server）..."
(cd "$LEGACY_DIR" && docker compose stop swanlab-house swanlab-server) \
  || die "stop 失败——旧栈状态未知，请在 ${LEGACY_ABS} 执行 docker compose ps 检查后重试"

# 中止处理：重新启动摄入服务并退出
abort_restore() {
  log_warn "中止迁移：恢复旧栈摄入源（house / server）..."
  (cd "$LEGACY_DIR" && docker compose start swanlab-house swanlab-server) \
    || log_err "恢复失败，请手动执行: (cd ${LEGACY_ABS} && docker compose start swanlab-house swanlab-server)"
  die "迁移已中止（数据未受影响，旧栈继续运行；确认 ClickHouse 状态后可重试）"
}

# ---------------- 9. 排空判定 ----------------
drain_poll || abort_restore

# ---------------- 10. down 旧栈 ----------------
log_info "停止旧栈（docker compose down；数据卷与 bind mount 均保留）..."
(cd "$LEGACY_DIR" && docker compose down) \
  || die "down 失败——旧栈可能部分停止，请在 ${LEGACY_ABS} 执行 docker compose ps 检查；数据未受影响"

# ---------------- 11. 准备目标目录 ----------------
if [ -n "$TO_DIR" ]; then
  # 创建目标目录并获取物理绝对路径
  mkdir -p "$TO_DIR"
  TO_ABS=$(cd "$TO_DIR" && pwd -P)
  mkdir -p "${TO_ABS}/${DATA_PATH_V}"
  log_info "rsync 数据目录 ${DISK_CHECK_PATH} → ${TO_ABS}/${DATA_PATH_V} ..."
  rsync -a "${DISK_CHECK_PATH}/" "${TO_ABS}/${DATA_PATH_V}/" \
    || die "rsync 失败——旧目录原样保留，可重试；目标半成品目录: ${TO_ABS}"
  log_ok "数据副本完成（旧目录原样保留: ${LEGACY_ABS}）"
  DEST_DIR="$TO_ABS"
else
  DEST_DIR="$LEGACY_DIR"
fi

# ---------------- 12. 铺设配置文件与合并环境变量 ----------------
log_info "铺设 docker-v2 模板到 ${DEST_DIR} ..."
cp -f "${SCRIPT_DIR}/docker-compose.yaml" "${DEST_DIR}/" || die "铺设 docker-compose.yaml 失败"
rm -rf "${DEST_DIR}/config"
cp -r "${SCRIPT_DIR}/config" "${DEST_DIR}/config" || die "铺设 config 失败"

# 以 .env.example 为模板，合并旧版 .env 配置项，并写入新架构参数。
# 合并数据源使用备份文件，避免覆盖影响。
LEGACY_ENV_SRC="${BACKUP_DIR}/.env"
ENV_FILE="${DEST_DIR}/.env"
cp "${SCRIPT_DIR}/.env.example" "$ENV_FILE" || die "生成 ${ENV_FILE} 失败"
chmod 600 "$ENV_FILE"

merged=0
while IFS='=' read -r key val || [ -n "$key" ]; do
  key="${key//[[:space:]]/}"            # 去键名空白/CR（含 Windows 换行残留）
  val="${val%$'\r'}"                     # 值只裁掉 CR，保留其余字符原样
  case "$key" in ''|'#'*) continue ;; esac
  case "$key" in *[!A-Za-z0-9_]*) log_warn "旧 .env 键名非法，已跳过: ${key}"; continue ;; esac
  [ -n "$val" ] || continue              # 空值保留模板默认配置
  env_set "$key" "$val" "$ENV_FILE"
  merged=$((merged + 1))
done < "$LEGACY_ENV_SRC"
log_ok "已合并旧 .env 存量配置（${merged} 项；空值不覆盖模板默认）"

# 写入新架构参数与已有凭据
env_set COMPOSE_PROJECT_NAME    "$PROJECT_NAME"        "$ENV_FILE"
env_set SWANLAB_VERSION         "$TARGET_VERSION"      "$ENV_FILE"
env_set DOCKER_SOCKET_PATH      "$SOCKET_PATH"         "$ENV_FILE"
env_set COMPOSE_PROFILES        "postgres,redis,clickhouse,minio" "$ENV_FILE"
env_set SS_STORAGE_TYPE         "local"                "$ENV_FILE"
env_set EXPOSE_PORT             "$EXPOSE_PORT_V"       "$ENV_FILE"
env_set DATA_PATH               "$DATA_PATH_V"         "$ENV_FILE"
env_set POSTGRES_PASSWORD       "$PG_PASS"             "$ENV_FILE"
env_set CLICKHOUSE_PASSWORD     "$CH_PASS"             "$ENV_FILE"
env_set MINIO_ROOT_PASSWORD     "$MINIO_PASS"          "$ENV_FILE"
log_ok "已生成 ${ENV_FILE}（沿用旧凭据、端口与数据目录；外接变量留空 = 本机默认）"

# ---------------- 13. 校验配置与拉取镜像 ----------------
validate_env "$ENV_FILE" || die "迁移生成的 .env 校验失败（旧栈已 down；回滚见下方提示）"
render_check "$DEST_DIR"

rollback_hint() {
  echo "   回滚（恢复旧架构，数据层未做任何修改）:"
  if [ -n "$TO_DIR" ]; then
    echo "     1. (cd ${DEST_DIR} && docker compose down)"
    echo "     2. (cd ${LEGACY_ABS} && docker compose up -d)     # 旧目录原样保留"
  else
    echo "     1. (cd ${LEGACY_ABS} && docker compose down)"
    echo "     2. cd ${LEGACY_ABS} && cp docker-compose.legacy.yaml.bak docker-compose.yaml && cp .env.legacy.bak .env"
    echo "     3. (cd ${LEGACY_ABS} && docker compose up -d)"
  fi
}

pull_images "$DEST_DIR" "$OFFLINE" \
  || { log_err "镜像不可用（旧栈已 down）"; rollback_hint; exit 1; }

# ---------------- 14. 启动服务与健康检查 ----------------
log_info "启动 docker-v2（docker compose up -d，schema 迁移由 server-migrate 先行完成）..."
(cd "$DEST_DIR" && docker compose up -d) || { log_err "up -d 失败"; rollback_hint; exit 1; }
wait_services_healthy "$DEST_DIR" || { log_err "服务未恢复健康"; rollback_hint; exit 1; }

# ---------------- 15. 输出迁移结果 ----------------
echo
echo "${green}${bold}迁移完成: 旧版(docker + fluent-bit) v${LEGACY_VERSION:-unknown} → docker-v2 v${TARGET_VERSION}${reset}"
print_access_urls "$EXPOSE_PORT_V"
echo "📁 运行目录: ${DEST_DIR}（数据 ${DATA_PATH_V}，原地未动/已复制）"
echo "🧰 快照: ${BACKUP_DIR}（旧 compose / .env / metadata.txt；pg 等数据卷未修改）"
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

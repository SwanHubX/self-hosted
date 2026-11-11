#!/bin/bash
# SwanLab Self-Hosted（docker-v2 架构）升级脚本
#
# 用法: ./upgrade.sh [运行目录(默认 ./swanlab)] [选项]
#   (默认)              快照 → (本机 PG 自动 pg_dump) → 铺设新模板 → 拉镜像 → up -d → 健康等待
#   --check             只读体检：版本对比 / 磁盘 / 防呆校验 / 渲染 / 容器状态，不做任何变更
#   --version X.Y.Z     覆盖目标版本（默认取模板 .env.example 的 SWANLAB_VERSION）
#   --offline | -o      离线/内网：跳过 docker compose pull，仅校验所需镜像已在本地
#   --rollback <dir>    从 backups/pre-upgrade-<ts>/ 回滚 compose / .env / config
#                       （数据库快照按需手动导入，脚本会给出命令）
#   --yes | -y          跳过交互确认
#   --ingestion-paused   声明已暂停外部上报并完成在途请求对账，升级与回滚必须提供
#
# 数据库迁移由一次性服务 server-migrate 在 server 副本启动前执行。
# 自定义服务/镜像请写入运行目录的 docker-compose.override.yaml；升级只覆盖模板文件。
#
# 从 docker-v2 模板目录运行（自动定位模板文件），目标为安装时创建的运行目录。
set -o pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

TARGET_DIR="swanlab"
CHECK_ONLY=0
ROLLBACK_DIR=""
TARGET_VERSION=""
ASSUME_YES=0
OFFLINE=0
INGESTION_PAUSED=0

POSITIONAL=()
while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK_ONLY=1; shift ;;
    --rollback) [ -n "${2:-}" ] || die "--rollback 需要备份目录"; ROLLBACK_DIR="$2"; shift 2 ;;
    --version) [ -n "${2:-}" ] || die "--version 需要版本号"; TARGET_VERSION="$2"; shift 2 ;;
    --offline|-o) OFFLINE=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --ingestion-paused) INGESTION_PAUSED=1; shift ;;
    -*) die "未知选项: $1" ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done
[ ${#POSITIONAL[@]} -gt 0 ] && TARGET_DIR="${POSITIONAL[0]}"

echo "${bold}===== SwanLab Self-Hosted（docker-v2）升级 =====${reset}"

require_compose_v224
[ "$CHECK_ONLY" -eq 0 ] || [ -z "$ROLLBACK_DIR" ] || die "--check 与 --rollback 不能同时使用"
[ -d "$TARGET_DIR" ] && TARGET_DIR=$(cd "$TARGET_DIR" && pwd -P)

if [ "$CHECK_ONLY" -eq 0 ] || [ -n "$ROLLBACK_DIR" ]; then
  [ "$INGESTION_PAUSED" -eq 1 ] \
    || die "请先暂停外部指标上报并完成在途请求对账，再加 --ingestion-paused；--yes 不替代维护窗口要求"
fi

# ---------------- --rollback 分支 ----------------
if [ -n "$ROLLBACK_DIR" ]; then
  [ -d "$ROLLBACK_DIR" ] || die "回滚目录不存在: ${ROLLBACK_DIR}"
  ROLLBACK_DIR=$(cd "$ROLLBACK_DIR" && pwd -P)
  { [ -f "${ROLLBACK_DIR}/docker-compose.yaml" ] && [ -f "${ROLLBACK_DIR}/.env" ]; } \
    || die "回滚目录缺少 docker-compose.yaml 或 .env（应为 backups/pre-upgrade-<ts>/）"
  [ -f "${TARGET_DIR}/.env" ] || die "目标目录未安装（缺少 ${TARGET_DIR}/.env），请先运行 install.sh"

  require_docker
  validate_env "${ROLLBACK_DIR}/.env" || die "备份 .env 校验失败，当前配置未修改"
  ROLLBACK_OVERRIDE="${ROLLBACK_DIR}/docker-compose.override.yaml"
  ROLLBACK_COMPOSE=(-f "${ROLLBACK_DIR}/docker-compose.yaml")
  [ -f "$ROLLBACK_OVERRIDE" ] && ROLLBACK_COMPOSE+=(-f "$ROLLBACK_OVERRIDE")
  (cd "$TARGET_DIR" && docker compose --project-directory "$TARGET_DIR" --env-file "${ROLLBACK_DIR}/.env" \
    "${ROLLBACK_COMPOSE[@]}" config --quiet) \
    || die "备份 compose 无法渲染，当前配置未修改"
  log_info "暂停 House，检查当前 Vector 缓冲后再回滚..."
  pause_house "$TARGET_DIR" || die "暂停 House 失败，当前配置未修改"
  wait_vector_buffers_drained "$TARGET_DIR" \
    || die "无法确认缓冲已排空，回滚中止；配置与 WAL 保留，House 保持暂停"
  stop_vector_services "$TARGET_DIR" || die "停止 Vector 失败，当前配置未修改"

  # 回滚前先快照当前状态（防回滚本身出错）
  PRE_ROLLBACK="${TARGET_DIR}/backups/pre-rollback-$(date +%Y%m%d%H%M%S)"
  mkdir -p "$PRE_ROLLBACK"
  cp "${TARGET_DIR}/docker-compose.yaml" "${TARGET_DIR}/.env" "$PRE_ROLLBACK/"
  [ -f "${TARGET_DIR}/docker-compose.override.yaml" ] \
    && cp "${TARGET_DIR}/docker-compose.override.yaml" "$PRE_ROLLBACK/"
  [ -d "${TARGET_DIR}/config" ] && cp -r "${TARGET_DIR}/config" "$PRE_ROLLBACK/"
  log_ok "已快照当前状态到 ${PRE_ROLLBACK}"

  # 还原文件
  cp -f "${ROLLBACK_DIR}/docker-compose.yaml" "${ROLLBACK_DIR}/.env" "${TARGET_DIR}/"
  if [ -f "$ROLLBACK_OVERRIDE" ]; then
    cp -f "$ROLLBACK_OVERRIDE" "${TARGET_DIR}/docker-compose.override.yaml"
  elif [ -f "${TARGET_DIR}/docker-compose.override.yaml" ]; then
    rm -f "${TARGET_DIR}/docker-compose.override.yaml"
    log_warn "回滚快照不含 docker-compose.override.yaml，已移除当前 override（原文件快照于 ${PRE_ROLLBACK}）"
  fi
  if [ -d "${ROLLBACK_DIR}/config" ]; then
    rm -rf "${TARGET_DIR}/config"
    cp -r "${ROLLBACK_DIR}/config" "${TARGET_DIR}/"
  fi

  validate_env "${TARGET_DIR}/.env" || die "回滚的 .env 校验失败（当前状态已备份于 ${PRE_ROLLBACK}）"
  render_check "${TARGET_DIR}"

  require_docker   # 回滚需重建容器（--check 只读路径不经过此门）
  log_info "以回滚配置重建服务..."
  (cd "${TARGET_DIR}" && docker compose up -d) || die "回滚 up -d 失败（当前状态已备份于 ${PRE_ROLLBACK}）"
  wait_services_healthy "${TARGET_DIR}" || exit 1

  # 数据库快照提示（破坏性操作只提示不自动执行）
  if [ -f "${ROLLBACK_DIR}/pg_snapshot.sql.gz" ]; then
    log_warn "如需同时回滚数据库结构（破坏性，会覆盖升级后的数据）："
    echo "  gunzip -c ${ROLLBACK_DIR}/pg_snapshot.sql.gz | (cd ${TARGET_DIR} && docker compose exec -T postgres psql -U swanlab -d app)"
  fi
  log_ok "回滚完成（回滚前状态备份于 ${PRE_ROLLBACK}）"
  exit 0
fi

# ---------------- 通用前置 ----------------
{ [ -f "${TARGET_DIR}/.env" ] && [ -f "${TARGET_DIR}/docker-compose.yaml" ]; } \
  || die "${TARGET_DIR} 不是已安装的运行目录（缺少 .env / docker-compose.yaml），请先运行 install.sh"

TEMPLATE_VERSION=$(env_get SWANLAB_VERSION "${SCRIPT_DIR}/.env.example")
[ -n "$TEMPLATE_VERSION" ] || die "模板 .env.example 缺少 SWANLAB_VERSION"
CURRENT_VERSION=$(env_get SWANLAB_VERSION "${TARGET_DIR}/.env")
[ -n "$TARGET_VERSION" ] || TARGET_VERSION="$TEMPLATE_VERSION"
case "$TARGET_VERSION" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) die "--version 格式应为 X.Y.Z（当前: ${TARGET_VERSION}）" ;;
esac

# ---------------- 体检（--check 与正式升级共用） ----------------
echo "${bold}----- 升级体检 -----${reset}"
echo "  当前版本: ${CURRENT_VERSION:-未知}"
echo "  目标版本: ${TARGET_VERSION}（模板版本: ${TEMPLATE_VERSION}）"
if [ "$CURRENT_VERSION" = "$TARGET_VERSION" ]; then
  log_warn "当前版本与目标版本相同（重跑迁移与重建，不改变版本）"
fi

# 检查双实例缓冲与运行余量
DATA_PATH_V=$(env_get DATA_PATH "${TARGET_DIR}/.env")
[ -z "$DATA_PATH_V" ] && DATA_PATH_V="./data"
case "$DATA_PATH_V" in
  /*) CHECK_PATH="$DATA_PATH_V" ;;
  *)  CHECK_PATH="${TARGET_DIR}/${DATA_PATH_V}" ;;
esac
check_disk_space "$CHECK_PATH" "$VECTOR_DISK_RECOMMENDED_GIB" warn

# 配置校验与渲染
validate_env "${TARGET_DIR}/.env" || die "当前 .env 防呆校验未通过，请先修正再升级"
render_check "${TARGET_DIR}"

OVERRIDE_FILE=$(compose_override_file "$TARGET_DIR" || true)
[ -n "$OVERRIDE_FILE" ] && log_info "检测到 Compose override: ${OVERRIDE_FILE}（升级保留并自动合并）"
if [ -z "$OVERRIDE_FILE" ] && [ -f "${TARGET_DIR}/docker-compose.override.yml" ]; then
  log_warn "检测到 docker-compose.override.yml；升级快照/回滚只处理 docker-compose.override.yaml，建议重命名"
fi

# 新模板（含 override）预检：现有 Vector 实例升级后必须仍有定义，避免模板覆盖 compose 后实例丢失
OLD_VECTOR_SERVICES=$(vector_services "$TARGET_DIR") || die "无法解析当前配置中的 Vector 服务"
NEW_COMPOSE=(-f "${SCRIPT_DIR}/docker-compose.yaml")
[ -n "$OVERRIDE_FILE" ] && NEW_COMPOSE+=(-f "$OVERRIDE_FILE")
(cd "$TARGET_DIR" && docker compose --project-directory "$TARGET_DIR" --env-file "${TARGET_DIR}/.env" \
  "${NEW_COMPOSE[@]}" config --quiet) \
  || die "新模板无法渲染，升级中止，当前配置与服务未修改"
NEW_VECTOR_SERVICES=$( (cd "$TARGET_DIR" && docker compose --project-directory "$TARGET_DIR" \
  --env-file "${TARGET_DIR}/.env" "${NEW_COMPOSE[@]}" config --services) ) \
  || die "无法解析新模板中的服务列表，升级中止"
NEW_VECTOR_SERVICES=$(printf '%s\n' "$NEW_VECTOR_SERVICES" | awk '/^vector(-[0-9]+)?$/ {print}' | sort)
[ -n "$NEW_VECTOR_SERVICES" ] || die "新模板中没有 Vector 服务，升级中止"
LOST_VECTOR=""
for svc in $OLD_VECTOR_SERVICES; do
  # 单实例 vector → vector-1 是受支持的升级路径，不算丢失
  case "$svc" in vector) continue ;; esac
  case " $(printf '%s' "$NEW_VECTOR_SERVICES" | tr '\n' ' ') " in
    *" $svc "*) ;;
    *) LOST_VECTOR="${LOST_VECTOR} ${svc}" ;;
  esac
done
if [ -n "$LOST_VECTOR" ]; then
  log_err "新模板 + override 不再包含 Vector 服务:${LOST_VECTOR}"
  log_err "升级会覆盖 ${TARGET_DIR}/docker-compose.yaml，直接写在该文件中的实例会丢失。"
  log_err "请将自定义实例（如 vector-3）迁移到 ${TARGET_DIR}/docker-compose.override.yaml 后重试。"
  exit 1
fi

# 容器状态概览
(cd "${TARGET_DIR}" && docker compose ps) || true

if [ "$CHECK_ONLY" -eq 1 ]; then
  log_ok "--check 体检完成，未做任何变更"
  exit 0
fi

# 正式升级需要 daemon；--check 只读路径已在上方退出（校验/渲染均不依赖 daemon）
require_docker

# ---------------- 确认 ----------------
if [ "$ASSUME_YES" -eq 0 ]; then
  read -p "升级将拉取镜像并重启服务（${CURRENT_VERSION:-?} → ${TARGET_VERSION}），继续? (y/N): " CONFIRM
  [[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "已取消"; exit 1; }
fi

# ---------------- 1. 快照当前部署 ----------------
BACKUP_DIR="${TARGET_DIR}/backups/pre-upgrade-$(date +%Y%m%d%H%M%S)"
mkdir -p "$BACKUP_DIR"
# 绝对化：下方 pg_dump 在 (cd TARGET_DIR) 子 shell 内做重定向，BACKUP_DIR 为相对路径时会按新 CWD 解析错位
BACKUP_DIR=$(cd "$BACKUP_DIR" && pwd)
cp "${TARGET_DIR}/docker-compose.yaml" "${TARGET_DIR}/.env" "$BACKUP_DIR/" \
  || die "快照失败（compose/.env → ${BACKUP_DIR}）"
if [ -n "$OVERRIDE_FILE" ]; then
  cp "$OVERRIDE_FILE" "$BACKUP_DIR/" || die "快照失败（override → ${BACKUP_DIR}）"
fi
cp -r "${TARGET_DIR}/config" "$BACKUP_DIR/" \
  || die "config 快照失败——回滚将缺少 config 还原（${BACKUP_DIR}）"
{
  echo "date=$(date '+%Y-%m-%dT%H:%M:%S%z')"
  echo "from_version=${CURRENT_VERSION}"
  echo "to_version=${TARGET_VERSION}"
  echo "compose_override=$([ -n "$OVERRIDE_FILE" ] && echo yes || echo no)"
  echo "hostname=$(hostname 2>/dev/null)"
} > "$BACKUP_DIR/metadata.txt"
log_ok "已快照当前部署到 ${BACKUP_DIR}"

# ---------------- 2. 数据库快照 ----------------
PROFILES=$(env_get COMPOSE_PROFILES "${TARGET_DIR}/.env")
case ",$PROFILES," in
  *,postgres,*)
    log_info "检测到本机 postgres，自动 pg_dump 数据库快照..."
    (cd "${TARGET_DIR}" && docker compose exec -T postgres pg_dump -U swanlab -d app | gzip > "${BACKUP_DIR}/pg_snapshot.sql.gz") \
      || die "pg_dump 失败——为安全起见升级中止（可 --check 排查，或手动备份后重试）"
    log_ok "数据库快照: ${BACKUP_DIR}/pg_snapshot.sql.gz"
    ;;
  *)
    log_warn "PostgreSQL 为外接部署，请确认已有数据库快照"
    if [ "$ASSUME_YES" -eq 0 ]; then
      read -p "   确认已有快照并继续? (y/N): " CONFIRM_SNAPSHOT
      [[ "$CONFIRM_SNAPSHOT" =~ ^[Yy]$ ]] || { echo "已取消"; exit 1; }
    fi
    ;;
esac

# 先按现有配置停写，避免旧 service 在配置更换后继续占用 WAL。
log_info "暂停 House 并停止当前 Vector writer；数据目录和停止容器均保留..."
pause_house "$TARGET_DIR" || die "暂停 House 失败，升级中止"
stop_vector_services "$TARGET_DIR" || die "停止 Vector 失败，升级中止，尚未替换配置"

# ---------------- 3. 铺设新模板与更新版本号 ----------------
cp -f "${SCRIPT_DIR}/docker-compose.yaml" "${TARGET_DIR}/"
rm -rf "${TARGET_DIR}/config"
cp -r "${SCRIPT_DIR}/config" "${TARGET_DIR}/config"
# 更新 .env 中的 SWANLAB_VERSION 配置
env_set SWANLAB_VERSION "$TARGET_VERSION" "${TARGET_DIR}/.env"

# 检查并提示模板新增配置项
MISSING_KEYS=""
while IFS='=' read -r key _; do
  case "$key" in ''|'#'*) continue ;; esac
  grep -qE "^${key}=" "${TARGET_DIR}/.env" || MISSING_KEYS="${MISSING_KEYS} ${key}"
done < "${SCRIPT_DIR}/.env.example"
[ -n "$MISSING_KEYS" ] && log_warn "模板新增变量（未写入 .env，使用默认值）:${MISSING_KEYS}；可对照 ${SCRIPT_DIR}/.env.example 手动补充"

# ---------------- 4. 校验与拉取镜像 ----------------
validate_env "${TARGET_DIR}/.env" || die "升级后的 .env 校验失败（回滚: ./upgrade.sh ${TARGET_DIR} --rollback ${BACKUP_DIR}）"
render_check "${TARGET_DIR}"

# 拉取目标版本镜像；离线模式校验本地镜像
pull_images "${TARGET_DIR}" "${OFFLINE}" \
  || die "镜像不可用（回滚: ./upgrade.sh ${TARGET_DIR} --rollback ${BACKUP_DIR}；离线环境请先 scripts/pull-images.sh --v2 --save 打包，在目标机 docker load 后加 --offline 重试）"

# ---------------- 5. 重建服务 ----------------
# 先确认已有 WAL 完成恢复，再让 House 发送新事件。
VECTOR_SERVICES=$(vector_services "$TARGET_DIR") \
  || die "无法解析新配置中的 Vector 服务，House 保持暂停；配置快照与 WAL 均已保留"
[ -n "$VECTOR_SERVICES" ] \
  || die "新配置中没有 Vector 服务，House 保持暂停；配置快照与 WAL 均已保留"
log_info "先恢复网关与 Vector（${VECTOR_SERVICES}），确认旧缓冲排空..."
# shellcheck disable=SC2086  # 按空格展开为多个 service
(cd "$TARGET_DIR" && docker compose up -d --wait --wait-timeout 180 gateway $VECTOR_SERVICES) \
  || die "网关或 Vector 未恢复健康，House 保持暂停；配置快照与 WAL 均已保留"
wait_vector_buffers_drained "$TARGET_DIR" \
  || die "旧缓冲尚未恢复完成，House 保持暂停；请恢复下游后重试升级"

# 启动服务；数据库迁移由 server-migrate 在 server 副本启动前完成
log_info "重建服务（docker compose up -d）..."
(cd "${TARGET_DIR}" && docker compose up -d) \
  || die "up -d 失败（回滚: ./upgrade.sh ${TARGET_DIR} --rollback ${BACKUP_DIR}）"
wait_services_healthy "${TARGET_DIR}" || {
  log_err "服务未恢复健康；如需回滚: ./upgrade.sh ${TARGET_DIR} --rollback ${BACKUP_DIR}"
  exit 1
}

# ---------------- 6. 收尾 ----------------
log_ok "升级完成: ${CURRENT_VERSION:-?} → ${TARGET_VERSION}"
echo "💡 配置回滚入口: ./upgrade.sh ${TARGET_DIR} --rollback ${BACKUP_DIR}"
echo "   （若需回滚数据库结构，该备份内的 pg_snapshot.sql.gz 导入命令见 --rollback 输出）"

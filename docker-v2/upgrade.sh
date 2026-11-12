#!/bin/bash
# SwanLab Self-Hosted（docker-v2 架构）升级脚本
#
# 用法: ./upgrade.sh [运行目录(默认 ./swanlab)] [选项]
#   (默认)              配置快照 → 铺设模板 → 拉取镜像 → 启动 → 健康检查
#   --check             只读体检：版本对比 / 磁盘 / 配置校验 / 渲染 / 容器状态，不做任何变更
#   --version X.Y.Z     覆盖目标版本（默认取模板 .env.example 的 SWANLAB_VERSION）
#   --offline | -o      离线/内网：跳过 docker compose pull，仅校验所需镜像已在本地
#   --rollback <dir>    从 backups/pre-upgrade-<ts>/ 回滚 compose / .env / config（不改动数据库）
#   --yes | -y          跳过交互确认
#
# 升级会短暂中断服务，请在维护窗口执行，并提前通知使用中的用户。
# 数据库迁移由一次性服务 server-migrate 在 server 副本启动前执行。
# 自定义服务/镜像请写入运行目录的 docker-compose.override.yaml；升级只覆盖模板文件。
#
# 从 docker-v2 模板目录运行（自动定位模板文件），目标为安装时创建的运行目录。
set -o pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

TARGET_DIR="swanlab"
CHECK_ONLY=0
ROLLBACK_DIR=""
TARGET_VERSION=""
ASSUME_YES=0
OFFLINE=0

POSITIONAL=()
while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK_ONLY=1; shift ;;
    --rollback) [ -n "${2:-}" ] || die "--rollback 需要备份目录"; ROLLBACK_DIR="$2"; shift 2 ;;
    --version) [ -n "${2:-}" ] || die "--version 需要版本号"; TARGET_VERSION="$2"; shift 2 ;;
    --offline|-o) OFFLINE=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    -*) die "未知选项: $1" ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done
[ ${#POSITIONAL[@]} -gt 0 ] && TARGET_DIR="${POSITIONAL[0]}"

echo "${bold}===== SwanLab Self-Hosted（docker-v2）升级 =====${reset}"

require_compose_v224
[ "$CHECK_ONLY" -eq 0 ] || [ -z "$ROLLBACK_DIR" ] || die "--check 与 --rollback 不能同时使用"
[ -d "$TARGET_DIR" ] && TARGET_DIR=$(cd "$TARGET_DIR" && pwd -P)

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
    || die "无法确认缓冲已排空，回滚中止；配置与缓冲数据均已保留，House 保持暂停"
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

  log_ok "回滚完成（仅恢复配置与镜像版本，数据库未改动；回滚前状态备份于 ${PRE_ROLLBACK}）"
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
  log_warn "当前版本与目标版本相同（将重新部署服务，版本不变）"
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
validate_env "${TARGET_DIR}/.env" || die "当前 .env 配置校验未通过，请先修正再升级"
render_check "${TARGET_DIR}"

OVERRIDE_FILE=$(compose_override_file "$TARGET_DIR" || true)
[ -n "$OVERRIDE_FILE" ] && log_info "检测到 Compose override: ${OVERRIDE_FILE}（升级保留并自动合并）"
if [ -z "$OVERRIDE_FILE" ] && [ -f "${TARGET_DIR}/docker-compose.override.yml" ]; then
  log_warn "检测到 docker-compose.override.yml；升级快照/回滚只处理 docker-compose.override.yaml，建议重命名"
fi

# 预检新模板：确保现有 Vector 实例在升级后仍有定义
OLD_VECTOR_SERVICES=$(vector_services "$TARGET_DIR") || die "无法解析当前配置中的 Vector 服务"
NEW_COMPOSE=(-f "${SCRIPT_DIR}/docker-compose.yaml")
[ -n "$OVERRIDE_FILE" ] && NEW_COMPOSE+=(-f "$OVERRIDE_FILE")
(cd "$TARGET_DIR" && docker compose --project-directory "$TARGET_DIR" --env-file "${TARGET_DIR}/.env" \
  "${NEW_COMPOSE[@]}" config --quiet) \
  || die "新模板无法渲染，升级中止，当前配置与服务未修改"
NEW_VECTOR_SERVICES=$( (cd "$TARGET_DIR" && docker compose --project-directory "$TARGET_DIR" \
  --env-file "${TARGET_DIR}/.env" "${NEW_COMPOSE[@]}" config --services) ) \
  || die "无法解析新模板中的服务列表，升级中止"
NEW_VECTOR_SERVICES=$(printf '%s\n' "$NEW_VECTOR_SERVICES" | awk '/^vector-[0-9]+$/ {print}' | sort)
[ -n "$NEW_VECTOR_SERVICES" ] || die "新模板中没有 Vector 服务，升级中止"
LOST_VECTOR=""
for svc in $OLD_VECTOR_SERVICES; do
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

# 正式升级需要 Docker daemon（--check 已在上方退出）
require_docker

# ---------------- 确认 ----------------
if [ "$ASSUME_YES" -eq 0 ]; then
  read -p "升级将拉取镜像并重启服务（${CURRENT_VERSION:-?} → ${TARGET_VERSION}），继续? (y/N): " CONFIRM
  [[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "已取消"; exit 1; }
fi

# ---------------- 1. 快照当前部署 ----------------
BACKUP_DIR="${TARGET_DIR}/backups/pre-upgrade-$(date +%Y%m%d%H%M%S)"
mkdir -p "$BACKUP_DIR"
# 转为绝对路径：后续步骤会切换目录，相对路径会解析到错误位置
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

# 先停止当前 Vector，避免更换配置期间继续写入缓冲目录。
log_info "暂停 House 并停止当前 Vector；数据目录和已停止的容器均保留..."
pause_house "$TARGET_DIR" || die "暂停 House 失败，升级中止"
stop_vector_services "$TARGET_DIR" || die "停止 Vector 失败，升级中止，尚未替换配置"

# ---------------- 2. 铺设新模板与更新版本号 ----------------
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

# ---------------- 3. 校验与拉取镜像 ----------------
validate_env "${TARGET_DIR}/.env" || die "升级后的 .env 校验失败（回滚: ./upgrade.sh ${TARGET_DIR} --rollback ${BACKUP_DIR}）"
render_check "${TARGET_DIR}"

# 拉取目标版本镜像；离线模式校验本地镜像
pull_images "${TARGET_DIR}" "${OFFLINE}" \
  || die "镜像不可用（回滚: ./upgrade.sh ${TARGET_DIR} --rollback ${BACKUP_DIR}；离线环境请先 scripts/pull-images.sh --v2 --save 打包，在目标机 docker load 后加 --offline 重试）"

# ---------------- 4. 重建服务 ----------------
# 先确认已有缓冲数据写入完成，再让 House 发送新事件。
VECTOR_SERVICES=$(vector_services "$TARGET_DIR") \
  || die "无法解析新配置中的 Vector 服务，House 保持暂停；配置快照与缓冲数据均已保留"
[ -n "$VECTOR_SERVICES" ] \
  || die "新配置中没有 Vector 服务，House 保持暂停；配置快照与缓冲数据均已保留"
log_info "先恢复网关与 Vector（${VECTOR_SERVICES}），确认旧缓冲排空..."
# shellcheck disable=SC2086  # 按空格展开为多个 service
(cd "$TARGET_DIR" && docker compose up -d --wait --wait-timeout 180 gateway $VECTOR_SERVICES) \
  || die "网关或 Vector 未恢复健康，House 保持暂停；配置快照与缓冲数据均已保留"
wait_vector_buffers_drained "$TARGET_DIR" \
  || die "旧缓冲尚未排空完成，House 保持暂停；请恢复下游后重试升级"

# 启动服务；数据库迁移由 server-migrate 在 server 副本启动前完成
log_info "重建服务（docker compose up -d）..."
(cd "${TARGET_DIR}" && docker compose up -d) \
  || die "up -d 失败（回滚: ./upgrade.sh ${TARGET_DIR} --rollback ${BACKUP_DIR}）"
wait_services_healthy "${TARGET_DIR}" || {
  log_err "服务未恢复健康；如需回滚: ./upgrade.sh ${TARGET_DIR} --rollback ${BACKUP_DIR}"
  exit 1
}

# 系统日志表已停写，存量数据设置 7 天 TTL（按分区异步回收）
log_info "设置存量 ClickHouse 系统日志 TTL（7 天）..."
apply_system_log_ttl "${TARGET_DIR}"

# ---------------- 5. 收尾 ----------------
log_ok "升级完成: ${CURRENT_VERSION:-?} → ${TARGET_VERSION}"
echo "💡 配置回滚入口: ./upgrade.sh ${TARGET_DIR} --rollback ${BACKUP_DIR}"

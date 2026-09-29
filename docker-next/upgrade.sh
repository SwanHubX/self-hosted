#!/bin/bash
# SwanLab Self-Hosted（docker-next 架构）升级脚本
#
# 用法: ./upgrade.sh [运行目录(默认 ./swanlab)] [选项]
#   (默认)              快照 → (本机 PG 自动 pg_dump) → 铺设新模板 → 拉镜像 → up -d → 健康等待
#   --check             只读体检：版本对比 / 磁盘 / 防呆校验 / 渲染 / 容器状态，不做任何变更
#   --version X.Y.Z     覆盖目标版本（默认取模板 .env.example 的 SWANLAB_VERSION）
#   --rollback <dir>    从 backups/pre-upgrade-<ts>/ 回滚 compose / .env / config
#                       （数据库快照按需手动导入，脚本会给出命令）
#   --yes | -y          跳过交互确认
#
# 数据库迁移由 swanlab-server 启动命令自带（chart 同款），脚本不做迁移预跑。
#
# 从 docker-next 模板目录运行（自动定位模板文件），目标为安装时创建的运行目录。
set -o pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

TARGET_DIR="swanlab"
CHECK_ONLY=0
ROLLBACK_DIR=""
TARGET_VERSION=""
ASSUME_YES=0

POSITIONAL=()
while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK_ONLY=1; shift ;;
    --rollback) ROLLBACK_DIR="${2:-}"; shift 2 ;;
    --version) TARGET_VERSION="${2:-}"; shift 2 ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    -*) die "未知选项: $1" ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done
[ ${#POSITIONAL[@]} -gt 0 ] && TARGET_DIR="${POSITIONAL[0]}"

echo "${bold}===== SwanLab Self-Hosted（docker-next）升级 =====${reset}"

require_docker
require_compose_v224

# ---------------- --rollback 分支 ----------------
if [ -n "$ROLLBACK_DIR" ]; then
  [ -d "$ROLLBACK_DIR" ] || die "回滚目录不存在: ${ROLLBACK_DIR}"
  { [ -f "${ROLLBACK_DIR}/docker-compose.yaml" ] && [ -f "${ROLLBACK_DIR}/.env" ]; } \
    || die "回滚目录缺少 docker-compose.yaml 或 .env（应为 backups/pre-upgrade-<ts>/）"
  [ -f "${TARGET_DIR}/.env" ] || die "目标目录未安装（缺少 ${TARGET_DIR}/.env），请先运行 install.sh"

  # 回滚前先快照当前状态（防回滚本身出错）
  PRE_ROLLBACK="${TARGET_DIR}/backups/pre-rollback-$(date +%Y%m%d%H%M%S)"
  mkdir -p "$PRE_ROLLBACK"
  cp "${TARGET_DIR}/docker-compose.yaml" "${TARGET_DIR}/.env" "$PRE_ROLLBACK/"
  [ -d "${TARGET_DIR}/config" ] && cp -r "${TARGET_DIR}/config" "$PRE_ROLLBACK/"
  log_ok "已快照当前状态到 ${PRE_ROLLBACK}"

  # 还原文件
  cp -f "${ROLLBACK_DIR}/docker-compose.yaml" "${ROLLBACK_DIR}/.env" "${TARGET_DIR}/"
  if [ -d "${ROLLBACK_DIR}/config" ]; then
    rm -rf "${TARGET_DIR}/config"
    cp -r "${ROLLBACK_DIR}/config" "${TARGET_DIR}/"
  fi

  validate_env "${TARGET_DIR}/.env" || die "回滚的 .env 校验失败（当前状态已备份于 ${PRE_ROLLBACK}）"
  render_check "${TARGET_DIR}"

  log_info "以回滚配置重建服务..."
  (cd "${TARGET_DIR}" && docker compose up -d) || die "回滚 up -d 失败（当前状态已备份于 ${PRE_ROLLBACK}）"
  wait_services_healthy "${TARGET_DIR}" || exit 1

  # 数据库快照提示（破坏性操作只提示不自动执行）
  if [ -f "${ROLLBACK_DIR}/pg_snapshot.sql.gz" ]; then
    log_warn "如需同时回滚数据库结构（破坏性，会覆盖升级后的数据）："
    echo "  gunzip -c ${ROLLBACK_DIR}/pg_snapshot.sql.gz | docker compose -f ${TARGET_DIR}/docker-compose.yaml exec -T postgres psql -U swanlab -d app"
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

# 磁盘剩余（数据目录所在分区）
DATA_PATH_V=$(env_get DATA_PATH "${TARGET_DIR}/.env")
[ -z "$DATA_PATH_V" ] && DATA_PATH_V="./data"
CHECK_PATH="${TARGET_DIR}/${DATA_PATH_V}"
[ -d "$CHECK_PATH" ] || CHECK_PATH="${TARGET_DIR}"
AVAIL_KB=$(df -k "$CHECK_PATH" 2>/dev/null | awk 'NR==2{print $4}')
if [ -n "$AVAIL_KB" ]; then
  if [ "$AVAIL_KB" -lt 10485760 ]; then
    log_warn "数据目录所在磁盘剩余 $((AVAIL_KB / 1024 / 1024))GiB（< 10GiB），升级与迁移缓冲可能不足"
  else
    log_ok "磁盘剩余空间: $((AVAIL_KB / 1024 / 1024))GiB"
  fi
fi

# 配置校验与渲染
validate_env "${TARGET_DIR}/.env" || die "当前 .env 防呆校验未通过，请先修正再升级"
render_check "${TARGET_DIR}"

# 容器状态概览
(cd "${TARGET_DIR}" && docker compose ps) || true

if [ "$CHECK_ONLY" -eq 1 ]; then
  log_ok "--check 体检完成，未做任何变更"
  exit 0
fi

# ---------------- 确认 ----------------
if [ "$ASSUME_YES" -eq 0 ]; then
  read -p "升级将拉取镜像并重启服务（${CURRENT_VERSION:-?} → ${TARGET_VERSION}），继续? (y/N): " CONFIRM
  [[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "已取消"; exit 1; }
fi

# ---------------- 1. 快照当前部署 ----------------
BACKUP_DIR="${TARGET_DIR}/backups/pre-upgrade-$(date +%Y%m%d%H%M%S)"
mkdir -p "$BACKUP_DIR"
cp "${TARGET_DIR}/docker-compose.yaml" "${TARGET_DIR}/.env" "$BACKUP_DIR/"
cp -r "${TARGET_DIR}/config" "$BACKUP_DIR/"
{
  echo "date=$(date '+%Y-%m-%dT%H:%M:%S%z')"
  echo "from_version=${CURRENT_VERSION}"
  echo "to_version=${TARGET_VERSION}"
  echo "hostname=$(hostname 2>/dev/null)"
} > "$BACKUP_DIR/metadata.txt"
log_ok "已快照当前部署到 ${BACKUP_DIR}"

# ---------------- 2. 数据库快照（prisma 迁移前向单向，不可 down） ----------------
PROFILES=$(env_get COMPOSE_PROFILES "${TARGET_DIR}/.env")
case ",$PROFILES," in
  *,postgres,*)
    log_info "检测到本机 postgres，自动 pg_dump 数据库快照..."
    (cd "${TARGET_DIR}" && docker compose exec -T postgres pg_dump -U swanlab -d app | gzip > "${BACKUP_DIR}/pg_snapshot.sql.gz") \
      || die "pg_dump 失败——为安全起见升级中止（可 --check 排查，或手动备份后重试）"
    log_ok "数据库快照: ${BACKUP_DIR}/pg_snapshot.sql.gz"
    ;;
  *)
    log_warn "PostgreSQL 为外接部署：prisma 迁移为前向单向操作，请自行确认已有数据库快照"
    if [ "$ASSUME_YES" -eq 0 ]; then
      read -p "   确认已有快照并继续? (y/N): " CONFIRM_SNAPSHOT
      [[ "$CONFIRM_SNAPSHOT" =~ ^[Yy]$ ]] || { echo "已取消"; exit 1; }
    fi
    ;;
esac

# ---------------- 3. 铺设新模板（compose + config；.env 保留用户配置，仅更新版本号） ----------------
cp -f "${SCRIPT_DIR}/docker-compose.yaml" "${TARGET_DIR}/"
rm -rf "${TARGET_DIR}/config"
cp -r "${SCRIPT_DIR}/config" "${TARGET_DIR}/config"
sed -i.bak "s/^SWANLAB_VERSION=.*/SWANLAB_VERSION=${TARGET_VERSION}/" "${TARGET_DIR}/.env" && rm -f "${TARGET_DIR}/.env.bak"

# 模板新增变量提示（当前 .env 缺失的键 → compose 用内嵌默认值，提示用户可手动补充）
MISSING_KEYS=""
while IFS='=' read -r key _; do
  case "$key" in ''|'#'*) continue ;; esac
  grep -qE "^${key}=" "${TARGET_DIR}/.env" || MISSING_KEYS="${MISSING_KEYS} ${key}"
done < "${SCRIPT_DIR}/.env.example"
[ -n "$MISSING_KEYS" ] && log_warn "模板新增变量（未写入 .env，使用默认值）:${MISSING_KEYS}；可对照 ${SCRIPT_DIR}/.env.example 手动补充"

# ---------------- 4. 校验 + 拉取新镜像 ----------------
validate_env "${TARGET_DIR}/.env" || die "升级后的 .env 校验失败（回滚: ./upgrade.sh ${TARGET_DIR} --rollback ${BACKUP_DIR}）"
render_check "${TARGET_DIR}"

# 先铺设新模板再 pull：此时 TARGET_DIR 内已是目标版本 compose/.env，
# 显式 pull 拉到的才是新镜像（否则拉旧 tag，新镜像反由 up -d 隐式拉取）
log_info "拉取新镜像（docker compose pull）..."
(cd "${TARGET_DIR}" && docker compose pull) \
  || die "镜像拉取失败（回滚: ./upgrade.sh ${TARGET_DIR} --rollback ${BACKUP_DIR}；离线环境请先用 scripts/pull-images.sh --next 导入后重试）"

# ---------------- 5. 重建 ----------------
# server 启动命令自带 prisma migrate deploy（chart 同款），重建即完成升级迁移
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

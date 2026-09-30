#!/bin/bash
# SwanLab Self-Hosted（docker-next 架构）内外接配置切换脚本
#
# 用法: ./configure.sh [运行目录(默认 ./swanlab)] [--status]
#   --status    只读显示当前数据层形态与外接配置，不做任何变更
#
# 数据层逐项切换 本机容器 ↔ 外部实例（plan §10.3）：
#   交互更新 .env → 备份 → 防呆校验 → 渲染 → 按需 up -d 生效
#
# ⚠️ 切换只改连接指向，不迁移数据：
#   - 外接 → 本机：连接的是全新空库/空桶（外部数据不会被导回）
#   - 本机 → 外接：外部库/桶需预先准备（表结构由 server 启动迁移创建，桶需手动建）
set -o pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

TARGET_DIR="swanlab"
STATUS_ONLY=0

POSITIONAL=()
while [ $# -gt 0 ]; do
  case "$1" in
    --status) STATUS_ONLY=1; shift ;;
    -*) die "未知选项: $1" ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done
[ ${#POSITIONAL[@]} -gt 0 ] && TARGET_DIR="${POSITIONAL[0]}"

echo "${bold}===== SwanLab Self-Hosted（docker-next）配置切换 =====${reset}"

ENV_FILE="${TARGET_DIR}/.env"
{ [ -f "$ENV_FILE" ] && [ -f "${TARGET_DIR}/docker-compose.yaml" ]; } \
  || die "${TARGET_DIR} 不是已安装的运行目录（缺少 .env / docker-compose.yaml），请先运行 install.sh"

PROFILES=$(env_get COMPOSE_PROFILES "$ENV_FILE")
has_profile() {
  case ",${PROFILES}," in *",$1,"*) return 0 ;; esac
  return 1
}

changed_keys=""

# 记录一次变更（供收尾汇总）
mark_change() { changed_keys="${changed_keys}${changed_keys:+ }$1"; }

# ---------------- 形态总览 ----------------
pg_mode="本机容器";    has_profile postgres    || pg_mode="外部实例"
redis_mode="本机容器"; has_profile redis       || redis_mode="外部实例"
ch_mode="本机容器";    has_profile clickhouse  || ch_mode="外部实例"
sst=$(env_get SS_STORAGE_TYPE "$ENV_FILE")
[ "$sst" = "remote" ] && s3_mode="外部对象存储" || s3_mode="本机 MinIO"

echo "${bold}----- 当前数据层形态 -----${reset}"
echo "  PostgreSQL : ${pg_mode}"
echo "  Redis      : ${redis_mode}"
echo "  ClickHouse : ${ch_mode}"
echo "  对象存储 S3: ${s3_mode}（SS_STORAGE_TYPE=${sst}）"
echo "  COMPOSE_PROFILES=${PROFILES:-<空>}"

if [ "$STATUS_ONLY" -eq 1 ]; then
  echo
  echo "（--status 只读模式，未做任何变更；外接连接串等敏感值请直接查看 ${ENV_FILE}）"
  exit 0
fi

if [ ! -t 0 ]; then
  die "configure.sh 需要交互终端（非交互环境请直接编辑 ${ENV_FILE} 后 docker compose up -d）"
fi

# 变更操作需要 docker；--status 只读路径已在上方退出，不受 daemon 状态门控
require_docker
require_compose_v224

# 变更前备份 .env（此后 env_set 直接修改原文件）
BACKUP_DIR="${TARGET_DIR}/backups/pre-configure-$(date +%Y%m%d%H%M%S)"
mkdir -p "$BACKUP_DIR"
cp "$ENV_FILE" "$BACKUP_DIR/.env"

# ---------------- 逐项切换 ----------------
read -p "是否重新配置数据层? (y/N): " ANS_RECONFIG
[[ "$ANS_RECONFIG" =~ ^[Yy]$ ]] || { echo "未做任何变更"; rm -rf "$BACKUP_DIR"; exit 0; }

# ---- PostgreSQL ----
echo
echo "1. PostgreSQL 当前: ${pg_mode}"
read -p "   切换到 (1=本机容器 2=外部实例, 回车=保持): " ANS
case "$ANS" in
  1)
    if ! has_profile postgres; then
      log_warn "外接 → 本机：将连接全新空库（外部库数据不导回），首次启动由 server 自动建表"
      read -p "   确认继续? (y/N): " C
      [[ "$C" =~ ^[Yy]$ ]] || { echo "   已跳过 PostgreSQL"; ANS=""; }
    fi
    if [ "$ANS" = "1" ]; then
      PROFILES=$(profile_add "$PROFILES" postgres)
      [ -z "$(env_get POSTGRES_PASSWORD "$ENV_FILE")" ] && { POSTGRES_PASSWORD=$(random_password); env_set POSTGRES_PASSWORD "$POSTGRES_PASSWORD" "$ENV_FILE"; mark_change "POSTGRES_PASSWORD"; }
      env_set DATABASE_URL "" "$ENV_FILE"
      env_set DATABASE_URL_REPLICA "" "$ENV_FILE"
      mark_change "DATABASE_URL DATABASE_URL_REPLICA"
      echo "   ✅ PostgreSQL → 本机容器"
    fi
    ;;
  2)
    if has_profile postgres; then
      log_warn "本机 → 外接：本机 postgres 数据保留在数据目录，不会被删除"
    fi
    read -p "   PostgreSQL 连接串 DATABASE_URL: " V
    [ -z "$V" ] && die "外接 postgres 必须提供 DATABASE_URL"
    read -p "   只读副本连接串 DATABASE_URL_REPLICA (回车 = 同主库): " V2
    [ -z "$V2" ] && V2="$V"
    PROFILES=$(profile_remove "$PROFILES" postgres)
    env_set DATABASE_URL "$V" "$ENV_FILE"
    env_set DATABASE_URL_REPLICA "$V2" "$ENV_FILE"
    mark_change "DATABASE_URL DATABASE_URL_REPLICA"
    echo "   ✅ PostgreSQL → 外部实例"
    ;;
esac

# ---- Redis ----
echo
echo "2. Redis 当前: ${redis_mode}"
read -p "   切换到 (1=本机容器 2=外部实例, 回车=保持): " ANS
case "$ANS" in
  1)
    if ! has_profile redis; then
      log_warn "外接 → 本机：将连接全新空 Redis（会话/缓存数据不导回）"
      read -p "   确认继续? (y/N): " C
      [[ "$C" =~ ^[Yy]$ ]] || ANS=""
    fi
    if [ "$ANS" = "1" ]; then
      PROFILES=$(profile_add "$PROFILES" redis)
      env_set REDIS_URL "" "$ENV_FILE"
      mark_change "REDIS_URL"
      echo "   ✅ Redis → 本机容器"
    fi
    ;;
  2)
    read -p "   Redis 连接串 REDIS_URL (如 redis://default:pass@host:6379): " V
    [ -z "$V" ] && die "外接 redis 必须提供 REDIS_URL"
    PROFILES=$(profile_remove "$PROFILES" redis)
    env_set REDIS_URL "$V" "$ENV_FILE"
    mark_change "REDIS_URL"
    echo "   ✅ Redis → 外部实例"
    ;;
esac

# ---- ClickHouse ----
echo
echo "3. ClickHouse 当前: ${ch_mode}"
read -p "   切换到 (1=本机容器 2=外部实例, 回车=保持): " ANS
case "$ANS" in
  1)
    if ! has_profile clickhouse; then
      log_warn "外接 → 本机：将连接全新空库（外部指标数据不导回），scalar/media/log 表由 house 启动自动创建"
      read -p "   确认继续? (y/N): " C
      [[ "$C" =~ ^[Yy]$ ]] || ANS=""
    fi
    if [ "$ANS" = "1" ]; then
      PROFILES=$(profile_add "$PROFILES" clickhouse)
      [ -z "$(env_get CLICKHOUSE_PASSWORD "$ENV_FILE")" ] && { env_set CLICKHOUSE_PASSWORD "$(random_password)" "$ENV_FILE"; mark_change "CLICKHOUSE_PASSWORD"; }
      # 清空外接指向（含库名与端口），口径回本机默认；避免 validate_env 的"本机部署但 HOST 已填写"告警
      env_set CLICKHOUSE_HOST "" "$ENV_FILE"
      env_set CLICKHOUSE_USER "" "$ENV_FILE"
      env_set CLICKHOUSE_DATABASE "" "$ENV_FILE"
      env_set CLICKHOUSE_HTTP_PORT "" "$ENV_FILE"
      env_set CLICKHOUSE_TCP_PORT "" "$ENV_FILE"
      mark_change "CLICKHOUSE_HOST CLICKHOUSE_USER CLICKHOUSE_DATABASE CLICKHOUSE_HTTP_PORT CLICKHOUSE_TCP_PORT"
      echo "   ✅ ClickHouse → 本机容器"
    fi
    ;;
  2)
    read -p "   ClickHouse 主机 CLICKHOUSE_HOST: " V_HOST
    [ -z "$V_HOST" ] && die "外接 clickhouse 必须提供 CLICKHOUSE_HOST"
    read -p "   HTTP 端口 [8123]: " V_HTTP; [ -z "$V_HTTP" ] && V_HTTP="8123"
    read -p "   TCP  端口 [9000]: " V_TCP;  [ -z "$V_TCP" ] && V_TCP="9000"
    read -p "   数据库名 [app]: " V_DB;     [ -z "$V_DB" ] && V_DB="app"
    read -p "   用户名 CLICKHOUSE_USER: " V_USER
    [ -z "$V_USER" ] && die "外接 clickhouse 必须提供用户名"
    read -p "   密码 CLICKHOUSE_PASSWORD: " V_PASS
    [ -z "$V_PASS" ] && die "外接 clickhouse 必须提供密码"
    PROFILES=$(profile_remove "$PROFILES" clickhouse)
    env_set CLICKHOUSE_HOST "$V_HOST" "$ENV_FILE"
    env_set CLICKHOUSE_HTTP_PORT "$V_HTTP" "$ENV_FILE"
    env_set CLICKHOUSE_TCP_PORT "$V_TCP" "$ENV_FILE"
    env_set CLICKHOUSE_DATABASE "$V_DB" "$ENV_FILE"
    env_set CLICKHOUSE_USER "$V_USER" "$ENV_FILE"
    env_set CLICKHOUSE_PASSWORD "$V_PASS" "$ENV_FILE"
    mark_change "CLICKHOUSE_*"
    echo "   ✅ ClickHouse → 外部实例"
    ;;
esac

# ---- S3 对象存储 ----
echo
echo "4. 对象存储 S3 当前: ${s3_mode}"
read -p "   切换到 (1=本机 MinIO 2=外部对象存储, 回车=保持): " ANS
case "$ANS" in
  1)
    if [ "$sst" = "remote" ]; then
      log_warn "外接 → 本机：应用将连接本机 MinIO 的空桶（外部桶对象不再被引用，数据仍在外部存储）"
      read -p "   确认继续? (y/N): " C
      [[ "$C" =~ ^[Yy]$ ]] || ANS=""
    fi
    if [ "$ANS" = "1" ]; then
      PROFILES=$(profile_add "$PROFILES" minio)
      [ -z "$(env_get MINIO_ROOT_PASSWORD "$ENV_FILE")" ] && { env_set MINIO_ROOT_PASSWORD "$(random_password)" "$ENV_FILE"; mark_change "MINIO_ROOT_PASSWORD"; }
      env_set SS_STORAGE_TYPE "local" "$ENV_FILE"
      # 外接字段清空、口径回本机默认
      env_set S3_PUBLIC_ENDPOINT "" "$ENV_FILE";  env_set S3_PRIVATE_ENDPOINT "" "$ENV_FILE"
      env_set S3_PUBLIC_REGION "" "$ENV_FILE";    env_set S3_PRIVATE_REGION "" "$ENV_FILE"
      env_set S3_PUBLIC_DOMAIN "" "$ENV_FILE";    env_set S3_ACCESS_KEY "" "$ENV_FILE"
      env_set S3_SECRET_KEY "" "$ENV_FILE"
      env_set S3_PUBLIC_PORT "9000" "$ENV_FILE";  env_set S3_PRIVATE_PORT "9000" "$ENV_FILE"
      env_set S3_PUBLIC_USE_SSL "false" "$ENV_FILE"; env_set S3_PRIVATE_USE_SSL "false" "$ENV_FILE"
      env_set S3_PUBLIC_PATH_STYLE "true" "$ENV_FILE"; env_set S3_PRIVATE_PATH_STYLE "true" "$ENV_FILE"
      env_set S3_PUBLIC_BUCKET "swanlab-public" "$ENV_FILE"; env_set S3_PRIVATE_BUCKET "swanlab-private" "$ENV_FILE"
      mark_change "SS_STORAGE_TYPE S3_*"
      echo "   ✅ S3 → 本机 MinIO（桶由 minio-init 幂等创建）"
    fi
    ;;
  2)
    if [ "$sst" != "remote" ]; then
      log_warn "本机 → 外接：需预先在外部存储创建桶 swanlab-public（公共读）/ swanlab-private（私有）"
    fi
    read -p "   公开桶 endpoint S3_PUBLIC_ENDPOINT (如 s3.example.com): " V_EP
    [ -z "$V_EP" ] && die "外接 S3 必须提供 endpoint"
    read -p "   私有桶 endpoint (回车 = 同公开桶): " V_EPP
    [ -z "$V_EPP" ] && V_EPP="$V_EP"
    read -p "   AccessKey: " V_AK
    [ -z "$V_AK" ] && die "外接 S3 必须提供 AccessKey"
    read -p "   SecretKey: " V_SK
    [ -z "$V_SK" ] && die "外接 S3 必须提供 SecretKey"
    # required 字段对齐 chart integrations.s3（_helpers.tpl）：region / domain 缺失即坏配置
    read -p "   Region (如 cn-north-1 / us-east-1): " V_REGION
    [ -z "$V_REGION" ] && die "外接 S3 必须提供 region（chart 语义：required）"
    read -p "   公开桶访问域名 S3_PUBLIC_DOMAIN (如 https://cdn.example.com): " V_DOMAIN
    [ -z "$V_DOMAIN" ] && die "外接 S3 必须提供公开桶访问域名（chart 语义：required）"
    read -p "   启用 SSL? (Y/n): " ANS_SSL
    if [ -n "$ANS_SSL" ] && [[ ! "$ANS_SSL" =~ ^[Yy]$ ]]; then V_SSL="false"; else V_SSL="true"; fi
    V_DPORT=443; [ "$V_SSL" = "false" ] && V_DPORT=80
    read -p "   端口 [${V_DPORT}]: " V_PORT
    [ -z "$V_PORT" ] && V_PORT="$V_DPORT"
    PROFILES=$(profile_remove "$PROFILES" minio)
    env_set SS_STORAGE_TYPE "remote" "$ENV_FILE"
    env_set S3_PUBLIC_ENDPOINT "$V_EP" "$ENV_FILE"
    env_set S3_PRIVATE_ENDPOINT "$V_EPP" "$ENV_FILE"
    env_set S3_PUBLIC_REGION "$V_REGION" "$ENV_FILE"
    env_set S3_PRIVATE_REGION "$V_REGION" "$ENV_FILE"
    env_set S3_PUBLIC_DOMAIN "$V_DOMAIN" "$ENV_FILE"
    env_set S3_ACCESS_KEY "$V_AK" "$ENV_FILE"
    env_set S3_SECRET_KEY "$V_SK" "$ENV_FILE"
    env_set S3_PUBLIC_PORT "$V_PORT" "$ENV_FILE"
    env_set S3_PRIVATE_PORT "$V_PORT" "$ENV_FILE"
    env_set S3_PUBLIC_USE_SSL "$V_SSL" "$ENV_FILE"
    env_set S3_PRIVATE_USE_SSL "$V_SSL" "$ENV_FILE"
    mark_change "SS_STORAGE_TYPE S3_*"
    echo "   ✅ S3 → 外部对象存储"
    ;;
esac

# ---------------- 收尾：写回 profiles + 校验 + 渲染 + 按需生效 ----------------
if [ -z "$changed_keys" ]; then
  echo
  log_info "未发生任何变更"
  rm -rf "$BACKUP_DIR"   # 无变更，清理刚才的备份
  exit 0
fi

env_set COMPOSE_PROFILES "$PROFILES" "$ENV_FILE"

echo
echo "${bold}----- 变更汇总 -----${reset}"
echo "  变更键: ${changed_keys}"
echo "  COMPOSE_PROFILES: ${PROFILES:-<空>}"

echo
validate_env "$ENV_FILE" || die "防呆校验未通过：请检查上方报错，修正后重跑（或对照 ${BACKUP_DIR}/.env 还原）"
render_check "$TARGET_DIR"

echo
log_warn "注意：切换只改连接指向，不迁移数据（外接→本机 = 空库/空桶起步）"
read -p "立即 docker compose up -d 生效? (Y/n): " ANS_UP
if [[ -z "$ANS_UP" || "$ANS_UP" =~ ^[Yy]$ ]]; then
  log_info "重建服务（docker compose up -d）..."
  (cd "${TARGET_DIR}" && docker compose up -d) || die "up -d 失败：配置已写入 ${ENV_FILE}，可手动排查后重试"
  wait_services_healthy "${TARGET_DIR}" || exit 1
  log_ok "配置已生效（变更前 .env 备份于 ${BACKUP_DIR}）"
else
  log_info "已跳过生效步骤：配置已写入 ${ENV_FILE}，稍后手动执行 cd ${TARGET_DIR} && docker compose up -d"
fi

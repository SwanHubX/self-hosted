#!/bin/bash
# SwanLab Self-Hosted（docker-next 架构）全新安装脚本
#
# 用法: ./install.sh [运行目录(默认 ./swanlab)] [-d 数据路径] [-p 暴露端口] [-s 跳过交互]
# 示例:
#   ./install.sh                          # 交互式安装到 ./swanlab
#   ./install.sh -s                       # 免交互：本机四件套 + 默认副本数（冒烟/测试）
#   ./install.sh /opt/swanlab -d /data -p 80
#
# 流程（plan §10.1）：环境检查 → 运行目录 → 交互收集（路径/端口/外接选择）
#   → 生成密码与 .env → 拷贝 compose 与 config → 防呆校验 + 渲染
#   → 预拉取镜像 → up -d → 逐服务健康等待
# 数据库迁移由 swanlab-server 启动命令自带（chart 同款：prisma migrate deploy + advisory lock）
set -o pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

RUN_DIR="swanlab"
DATA_PATH="./data"
EXPOSE_PORT="8000"
SKIP_INPUT=0

# 第一个位置参数 = 运行目录，其余走 getopts
POSITIONAL=()
while [ $# -gt 0 ]; do
  case "$1" in
    -*) break ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done
[ ${#POSITIONAL[@]} -gt 0 ] && RUN_DIR="${POSITIONAL[0]}"

while getopts ":d:p:s" opt; do
  case ${opt} in
    d) DATA_PATH="$OPTARG" ;;
    p) EXPOSE_PORT="$OPTARG" ;;
    s) SKIP_INPUT=1 ;;
    \?) die "无效选项: -$OPTARG" ;;
    :) die "选项 -$OPTARG 需要参数" ;;
  esac
done

echo "${bold}===== SwanLab Self-Hosted（docker-next）安装 =====${reset}"

# ---- 1. 环境检查 ----
require_docker
require_compose_v224
resolve_docker_socket_path
SOCKET_PATH="${DOCKER_SOCKET_PATH}"
# 项目名 swanlab 被其他目录的部署占用（如旧版 docker 版）则拒绝安装，引导走 migrate.sh
require_project_name_free "${RUN_DIR}"

# ---- 2. 运行目录 ----
if [ -e "${RUN_DIR}/.env" ]; then
  die "${RUN_DIR}/.env 已存在——似乎安装过？请使用 upgrade.sh 升级，或指定其他运行目录"
fi
mkdir -p "${RUN_DIR}"

# ---- 3. 交互收集配置 ----
PG_EXTERNAL=0; REDIS_EXTERNAL=0; CH_EXTERNAL=0; S3_EXTERNAL=0

if [ "$SKIP_INPUT" -eq 0 ]; then
  read -p "1. 数据目录使用默认值 (${bold}${DATA_PATH}${reset}) ? (y/n): " USE_DEFAULT
  if [[ -n "$USE_DEFAULT" && ! "$USE_DEFAULT" =~ ^[Yy]$ ]]; then
    read -p "   输入自定义路径: " DATA_PATH
  fi
  DATA_PATH=$(echo "$DATA_PATH" | sed 's:/*$::')
  echo "   数据目录: ${green}${DATA_PATH}${reset}"

  read -p "2. 暴露端口使用默认值 (${bold}${EXPOSE_PORT}${reset}) ? (y/n): " USE_DEFAULT
  if [[ -n "$USE_DEFAULT" && ! "$USE_DEFAULT" =~ ^[Yy]$ ]]; then
    read -p "   输入自定义端口: " EXPOSE_PORT
  fi
  echo "   暴露端口: ${green}${EXPOSE_PORT}${reset}"

  echo "   数据层逐项选择本机部署（回车默认本机）或外接已有实例："
  read -p "3. PostgreSQL 使用本机内置容器? (Y/n): " ANS; [[ "$ANS" =~ ^[Nn]$ ]] && PG_EXTERNAL=1
  read -p "4. Redis      使用本机内置容器? (Y/n): " ANS; [[ "$ANS" =~ ^[Nn]$ ]] && REDIS_EXTERNAL=1
  read -p "5. ClickHouse 使用本机内置容器? (Y/n): " ANS; [[ "$ANS" =~ ^[Nn]$ ]] && CH_EXTERNAL=1
  read -p "6. 对象存储(S3) 使用本机 MinIO? (Y/n): " ANS; [[ "$ANS" =~ ^[Nn]$ ]] && S3_EXTERNAL=1
else
  log_info "跳过交互（-s）：数据层全部本机部署"
fi

# 外接参数收集（免交互模式下全部留空 = 本机默认）
DATABASE_URL=""; DATABASE_URL_REPLICA=""; REDIS_URL=""
CH_HOST=""; CH_HTTP_PORT="8123"; CH_TCP_PORT="9000"; CH_DATABASE="app"; CH_USER=""
# S3：本机模式保持 MinIO 口径（false/9000）；外接分支按交互结果覆盖
S3_PUBLIC_ENDPOINT=""; S3_PRIVATE_ENDPOINT=""; S3_ACCESS_KEY=""; S3_SECRET_KEY=""
S3_REGION=""; S3_PUBLIC_DOMAIN=""; S3_USE_SSL="false"; S3_PORT="9000"

if [ "$PG_EXTERNAL" -eq 1 ] && [ "$SKIP_INPUT" -eq 0 ]; then
  read -p "   PostgreSQL 连接串 DATABASE_URL: " DATABASE_URL
  [ -z "$DATABASE_URL" ] && die "外接 postgres 必须提供 DATABASE_URL"
  read -p "   只读副本连接串 DATABASE_URL_REPLICA (回车 = 同主库): " DATABASE_URL_REPLICA
  [ -z "$DATABASE_URL_REPLICA" ] && DATABASE_URL_REPLICA="$DATABASE_URL"
fi
if [ "$REDIS_EXTERNAL" -eq 1 ] && [ "$SKIP_INPUT" -eq 0 ]; then
  read -p "   Redis 连接串 REDIS_URL (如 redis://default:pass@host:6379): " REDIS_URL
  [ -z "$REDIS_URL" ] && die "外接 redis 必须提供 REDIS_URL"
fi
if [ "$CH_EXTERNAL" -eq 1 ] && [ "$SKIP_INPUT" -eq 0 ]; then
  read -p "   ClickHouse 主机 CLICKHOUSE_HOST: " CH_HOST
  [ -z "$CH_HOST" ] && die "外接 clickhouse 必须提供 CLICKHOUSE_HOST"
  read -p "   HTTP 端口 [8123]: " CH_HTTP_PORT
  [ -z "$CH_HTTP_PORT" ] && CH_HTTP_PORT="8123"
  read -p "   TCP  端口 [9000]: " CH_TCP_PORT
  [ -z "$CH_TCP_PORT" ] && CH_TCP_PORT="9000"
  read -p "   数据库名 [app]: " CH_DATABASE
  [ -z "$CH_DATABASE" ] && CH_DATABASE="app"
  read -p "   用户名 CLICKHOUSE_USER: " CH_USER
  [ -z "$CH_USER" ] && die "外接 clickhouse 必须提供用户名"
fi
if [ "$S3_EXTERNAL" -eq 1 ] && [ "$SKIP_INPUT" -eq 0 ]; then
  read -p "   公开桶 endpoint S3_PUBLIC_ENDPOINT (如 s3.example.com): " S3_PUBLIC_ENDPOINT
  [ -z "$S3_PUBLIC_ENDPOINT" ] && die "外接 S3 必须提供 endpoint"
  read -p "   私有桶 endpoint (回车 = 同公开桶): " S3_PRIVATE_ENDPOINT
  [ -z "$S3_PRIVATE_ENDPOINT" ] && S3_PRIVATE_ENDPOINT="$S3_PUBLIC_ENDPOINT"
  read -p "   AccessKey: " S3_ACCESS_KEY
  [ -z "$S3_ACCESS_KEY" ] && die "外接 S3 必须提供 AccessKey"
  read -p "   SecretKey: " S3_SECRET_KEY
  [ -z "$S3_SECRET_KEY" ] && die "外接 S3 必须提供 SecretKey"
  # 以下字段对齐 chart integrations.s3 的 required 语义（_helpers.tpl），缺失即坏配置
  read -p "   Region (如 cn-north-1 / us-east-1): " S3_REGION
  [ -z "$S3_REGION" ] && die "外接 S3 必须提供 region（chart 语义：required）"
  read -p "   公开桶访问域名 S3_PUBLIC_DOMAIN (如 https://cdn.example.com): " S3_PUBLIC_DOMAIN
  [ -z "$S3_PUBLIC_DOMAIN" ] && die "外接 S3 必须提供公开桶访问域名（chart 语义：required）"
  read -p "   启用 SSL? (Y/n): " ANS_SSL
  if [ -n "$ANS_SSL" ] && [[ ! "$ANS_SSL" =~ ^[Yy]$ ]]; then S3_USE_SSL="false"; else S3_USE_SSL="true"; fi
  S3_DEFAULT_PORT=443; [ "$S3_USE_SSL" = "false" ] && S3_DEFAULT_PORT=80
  read -p "   端口 [${S3_DEFAULT_PORT}]: " S3_PORT
  [ -z "$S3_PORT" ] && S3_PORT="$S3_DEFAULT_PORT"
  log_warn "外接 S3 需预先创建桶：swanlab-public（公共读）/ swanlab-private（私有）"
fi

# ---- 4. 组装 profile 与凭据 ----
PROFILE_LIST=""
append_profile() { PROFILE_LIST="${PROFILE_LIST:+${PROFILE_LIST},}$1"; }
[ "$PG_EXTERNAL" -eq 0 ] && append_profile postgres
[ "$REDIS_EXTERNAL" -eq 0 ] && append_profile redis
[ "$CH_EXTERNAL" -eq 0 ] && append_profile clickhouse
[ "$S3_EXTERNAL" -eq 0 ] && append_profile minio

SS_STORAGE_TYPE="local"
[ "$S3_EXTERNAL" -eq 1 ] && SS_STORAGE_TYPE="remote"

POSTGRES_PASSWORD=""; CLICKHOUSE_PASSWORD=""; MINIO_ROOT_PASSWORD=""
[ "$PG_EXTERNAL" -eq 0 ] && POSTGRES_PASSWORD=$(random_password)
[ "$CH_EXTERNAL" -eq 0 ] && CLICKHOUSE_PASSWORD=$(random_password)
[ "$S3_EXTERNAL" -eq 0 ] && MINIO_ROOT_PASSWORD=$(random_password)
# 外接时 CLICKHOUSE_PASSWORD / 用户凭据共用同一变量位（vector 与 house 读取 CLICKHOUSE_PASSWORD）
if [ "$CH_EXTERNAL" -eq 1 ] && [ "$SKIP_INPUT" -eq 0 ]; then
  read -p "   密码 CLICKHOUSE_PASSWORD: " CLICKHOUSE_PASSWORD
  [ -z "$CLICKHOUSE_PASSWORD" ] && die "外接 clickhouse 必须提供密码"
fi

SWANLAB_VERSION=$(env_get SWANLAB_VERSION "${SCRIPT_DIR}/.env.example")
[ -n "$SWANLAB_VERSION" ] || die "模板 .env.example 缺少 SWANLAB_VERSION"

# ---- 5. 生成 .env ----
log_info "生成 ${RUN_DIR}/.env（权限 600）"
cat > "${RUN_DIR}/.env" <<EOF
# SwanLab Self-Hosted（docker-next）配置 — 由 install.sh 生成于 $(date '+%Y-%m-%d %H:%M:%S')
# 修改后执行 docker compose up -d 生效；升级请使用 upgrade.sh

# ---- 公共 ----
COMPOSE_PROJECT_NAME=swanlab
SWANLAB_VERSION=${SWANLAB_VERSION}
EXPOSE_PORT=${EXPOSE_PORT}
DATA_PATH=${DATA_PATH}
DOCKER_SOCKET_PATH=${SOCKET_PATH}
PUBLIC_HOST=
MAX_METRICS_PER_COPY=20000
COMPOSE_PROFILES=${PROFILE_LIST}

# ---- 业务副本数（默认对齐 k8s chart；单机内存紧张可降为 1）----
SERVER_REPLICAS=2
AUTH_REPLICAS=2
HOUSE_REPLICAS=2
NEXT_REPLICAS=2
CLOUD_REPLICAS=1

# ---- S3 模式（枚举 local|remote）----
SS_STORAGE_TYPE=${SS_STORAGE_TYPE}

# ---- 数据层凭据（本机激活时随机生成；外接时为外部凭据）----
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
CLICKHOUSE_PASSWORD=${CLICKHOUSE_PASSWORD}
MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD}

# ---- 外接配置（留空 = 本机默认）----
DATABASE_URL=${DATABASE_URL}
DATABASE_URL_REPLICA=${DATABASE_URL_REPLICA}
REDIS_URL=${REDIS_URL}
CLICKHOUSE_HOST=${CH_HOST}
CLICKHOUSE_HTTP_PORT=${CH_HTTP_PORT}
CLICKHOUSE_TCP_PORT=${CH_TCP_PORT}
CLICKHOUSE_DATABASE=${CH_DATABASE}
CLICKHOUSE_USER=${CH_USER}
S3_PUBLIC_ENDPOINT=${S3_PUBLIC_ENDPOINT}
S3_PUBLIC_REGION=${S3_REGION}
S3_PUBLIC_PORT=${S3_PORT}
S3_PUBLIC_USE_SSL=${S3_USE_SSL}
S3_PUBLIC_PATH_STYLE=true
S3_PUBLIC_BUCKET=swanlab-public
S3_PUBLIC_DOMAIN=${S3_PUBLIC_DOMAIN}
S3_PRIVATE_ENDPOINT=${S3_PRIVATE_ENDPOINT}
S3_PRIVATE_REGION=${S3_REGION}
S3_PRIVATE_PORT=${S3_PORT}
S3_PRIVATE_USE_SSL=${S3_USE_SSL}
S3_PRIVATE_PATH_STYLE=true
S3_PRIVATE_BUCKET=swanlab-private
S3_ACCESS_KEY=${S3_ACCESS_KEY}
S3_SECRET_KEY=${S3_SECRET_KEY}

# ---- 镜像仓库前缀 ----
REGISTRY_PREFIX=repo.swanlab.cn
EOF
chmod 600 "${RUN_DIR}/.env"

# ---- 6. 拷贝 compose 与 config ----
cp "${SCRIPT_DIR}/docker-compose.yaml" "${RUN_DIR}/"
rm -rf "${RUN_DIR}/config"
cp -r "${SCRIPT_DIR}/config" "${RUN_DIR}/config"
log_ok "已铺设 docker-compose.yaml 与 config/ 到 ${RUN_DIR}"

# ---- 7. 防呆校验 + 渲染 ----
validate_env "${RUN_DIR}/.env" || die "防呆校验未通过，请修正 ${RUN_DIR}/.env 后重试"
render_check "${RUN_DIR}"

# ---- 8. 预拉取镜像 ----
# 显式 pull 走带进度条的输出；避免后续 compose run / up 隐式拉取时输出无进度条的重复行
log_info "拉取全部镜像（docker compose pull）..."
(cd "${RUN_DIR}" && docker compose pull) \
  || die "镜像拉取失败（离线环境请先 scripts/pull-images.sh --next 导入后重试）"

# ---- 9. 启动 + 健康等待（server 启动命令自带 prisma migrate，advisory lock 串行化）----
log_info "启动全部服务（docker compose up -d）..."
(cd "${RUN_DIR}" && docker compose up -d) || die "docker compose up -d 失败"
wait_services_healthy "${RUN_DIR}" || exit 1

# ---- 10. 收尾 ----
echo "${green}${bold}"
cat <<'BANNER'
   _____                    _           _
  / ____|                  | |         | |
 | (_____      ____ _ _ __ | |     __ _| |__
  \___ \ \ /\ / / _` | '_ \| |    / _` | '_ \
  ____) \ V  V / (_| | | | | |___| (_| | |_) |
 |_____/ \_/\_/ \__,_|_| |_|______\__,_|_.__/
BANNER
echo " Self-Hosted Docker-Next v${SWANLAB_VERSION} - @SwanLab"
echo "${reset}"
print_access_urls "$EXPOSE_PORT"
echo "📁 运行目录: ${RUN_DIR}（配置 ${RUN_DIR}/.env，数据 ${DATA_PATH}）"
echo "🔧 常用操作:"
echo "   - 调整副本数: 编辑 ${RUN_DIR}/.env 的 *_REPLICAS 后 docker compose up -d"
echo "   - 升级版本:   ${SCRIPT_DIR}/upgrade.sh ${RUN_DIR}"
echo "   - 日常巡检:   docker compose ps && docker compose logs -f <service>"

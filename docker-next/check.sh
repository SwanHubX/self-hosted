#!/bin/bash
# SwanLab Self-Hosted（docker-next 架构）巡检脚本
#
# 用法: ./check.sh [运行目录(默认 ./swanlab)]
#
# 无副作用只读巡检（plan §10.3）：环境版本 / 运行目录完整性 / 防呆校验 /
# 渲染 / 项目一致性（混栈检测）/ 容器健康 / 磁盘余量
# 退出码: 0 = 无 FAIL（允许有 WARN）；1 = 存在 FAIL；2 = 运行目录不存在
# 供运维日常与 CI 复用
set -o pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

TARGET_DIR="swanlab"
[ $# -gt 0 ] && TARGET_DIR="$1"

echo "${bold}===== SwanLab Self-Hosted（docker-next）巡检 =====${reset}"
echo "目标目录: ${TARGET_DIR}"

if [ ! -d "$TARGET_DIR" ]; then
  log_err "运行目录不存在: ${TARGET_DIR}"
  exit 2
fi

PASS=0; WARN=0; FAIL=0
pass_() { PASS=$((PASS + 1)); echo "[PASS] $*"; }
warn_() { WARN=$((WARN + 1)); echo "${yellow}[WARN]${reset} $*"; }
fail_() { FAIL=$((FAIL + 1)); echo "${red}[FAIL]${reset} $*"; }

ENV_FILE="${TARGET_DIR}/.env"

# ---------------- 1. 环境版本 ----------------
echo "${bold}----- 1. 环境 -----${reset}"
if command -v docker >/dev/null 2>&1; then
  if docker info >/dev/null 2>&1; then
    pass_ "Docker daemon 运行中"
  else
    fail_ "Docker daemon 未运行"
  fi
  ver=$(docker compose version --short 2>/dev/null | sed 's/^v//' | cut -d- -f1)
  if compose_version_ok; then
    pass_ "docker compose ${ver} >= 2.24"
  else
    fail_ "docker compose ${ver:-不可用} < 2.24（depends_on.required 长语法不可用）"
  fi
else
  fail_ "Docker 未安装"
fi

# ---------------- 2. 运行目录完整性 ----------------
echo "${bold}----- 2. 运行目录 -----${reset}"
for f in ".env" "docker-compose.yaml" "config/traefik/traefik.yaml" "config/vector/vector.yaml"; do
  if [ -e "${TARGET_DIR}/${f}" ]; then
    pass_ "${f} 存在"
  else
    fail_ "缺少 ${f}（重新铺设模板: cp 模板目录 docker-compose.yaml 与 config/）"
  fi
done

if [ -f "$ENV_FILE" ]; then
  perm=$(stat -c %a "$ENV_FILE" 2>/dev/null || stat -f %Lp "$ENV_FILE" 2>/dev/null)
  if [ "$perm" = "600" ]; then
    pass_ ".env 权限 600"
  else
    warn_ ".env 权限为 ${perm}（建议 600，内含数据层凭据）"
  fi
fi

# docker socket（gateway 发现容器依赖）
SOCKET_V=$(env_get DOCKER_SOCKET_PATH "$ENV_FILE")
[ -n "$SOCKET_V" ] || SOCKET_V="/var/run/docker.sock"
if [ -S "$SOCKET_V" ]; then
  pass_ "Docker socket 存在: ${SOCKET_V}"
else
  warn_ "Docker socket 不存在: ${SOCKET_V}（gateway 将无法发现容器，检查 .env DOCKER_SOCKET_PATH）"
fi

# ---------------- 3. 防呆校验 ----------------
echo "${bold}----- 3. 防呆校验 -----${reset}"
if [ -f "$ENV_FILE" ]; then
  if validate_env "$ENV_FILE" 2>&1; then
    :
  else
    fail_ "防呆校验未通过（详见上方输出）"
  fi
fi

# ---------------- 4. 渲染检查 ----------------
echo "${bold}----- 4. 配置渲染 -----${reset}"
if [ -f "${TARGET_DIR}/docker-compose.yaml" ]; then
  if (cd "$TARGET_DIR" && docker compose config --quiet 2>/dev/null); then
    pass_ "docker compose config 渲染通过"
  else
    fail_ "渲染失败: cd ${TARGET_DIR} && docker compose config（查看具体报错）"
  fi
fi

# ---------------- 5. 项目一致性（混栈检测） ----------------
echo "${bold}----- 5. 项目一致性 -----${reset}"
if foreign_project_container "$TARGET_DIR"; then
  fail_ "项目 swanlab 混入其他目录的容器: ${FOREIGN_CONTAINER}（working_dir ${FOREIGN_WD}）——两栈并存，清理任一侧会波及另一侧；请完成 migrate.sh 原地迁移或 down 掉另一栈"
else
  pass_ "项目 swanlab 无外来容器（无混栈）"
fi

# ---------------- 6. 容器健康 ----------------
echo "${bold}----- 6. 容器状态 -----${reset}"
ids=$( (cd "$TARGET_DIR" && docker compose ps -aq 2>/dev/null) )
if [ -z "$ids" ]; then
  warn_ "无运行容器（服务未启动或已 down）"
else
  for id in $ids; do
    name=$(docker inspect --format '{{.Name}}' "$id" 2>/dev/null | sed 's#^/##')
    svc=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.service"}}' "$id" 2>/dev/null)
    case "$svc" in gateway-plugins|minio-init) continue ;; esac   # 一次性服务，退出即正常
    state=$(docker inspect --format '{{.State.Status}}' "$id" 2>/dev/null)
    health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$id" 2>/dev/null)
    case "$state":$health in
      running:healthy)   pass_ "${name}: healthy" ;;
      running:starting)  warn_ "${name}: 启动中（healthcheck starting）" ;;
      running:unhealthy) fail_ "${name}: unhealthy（docker logs ${name} 排查）" ;;
      running:none)      warn_ "${name}: 运行中但无 healthcheck" ;;
      exited:*)          warn_ "${name}: 已退出（docker logs ${name} 查看）" ;;
      created:*)         warn_ "${name}: 已创建未启动" ;;
      *)                 warn_ "${name}: 状态 ${state:-未知} / health ${health:-未知}" ;;
    esac
  done
fi

# ---------------- 7. 磁盘余量 ----------------
echo "${bold}----- 7. 磁盘 -----${reset}"
DATA_PATH_V=$(env_get DATA_PATH "$ENV_FILE")
[ -z "$DATA_PATH_V" ] && DATA_PATH_V="./data"
case "$DATA_PATH_V" in
  /*) CHECK_PATH="$DATA_PATH_V" ;;
  *)  CHECK_PATH="${TARGET_DIR}/${DATA_PATH_V}" ;;
esac
p="$CHECK_PATH"
while [ ! -d "$p" ] && [ "$p" != "/" ]; do p=$(dirname "$p"); done
avail_kb=$(df -k "$p" 2>/dev/null | awk 'NR==2{print $4}')
if [ -n "$avail_kb" ]; then
  avail_gib=$((avail_kb / 1024 / 1024))
  if [ "$avail_gib" -ge 40 ]; then
    pass_ "磁盘剩余 ${avail_gib}GiB（≥ 40GiB，vector 缓冲 30Gi 余量足够）"
  elif [ "$avail_gib" -ge 10 ]; then
    warn_ "磁盘剩余 ${avail_gib}GiB（< 40GiB；vector 磁盘缓冲最坏 30Gi 且与数据同盘）"
  else
    fail_ "磁盘剩余 ${avail_gib}GiB（< 10GiB，随时可能写满连坐全部数据服务）"
  fi
else
  warn_ "无法检测 ${p} 的磁盘剩余（df 无输出）"
fi

# ---------------- 汇总 ----------------
echo
echo "${bold}----- 汇总 -----${reset}"
echo "  ${PASS} PASS / ${WARN} WARN / ${FAIL} FAIL"
if [ "$FAIL" -gt 0 ]; then
  log_err "巡检发现 ${FAIL} 项 FAIL，请处理后再执行变更操作"
  exit 1
fi
log_ok "巡检完成，无阻断性问题"
exit 0

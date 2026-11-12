#!/bin/bash
# SwanLab Self-Hosted（docker-v2 架构）巡检脚本
#
# 用法: ./check.sh [运行目录(默认 ./swanlab)]
#
# 只读巡检脚本：环境版本、运行目录完整性、配置校验、
# 渲染检查、项目一致性、vector 实例校验、容器健康状态、磁盘余量
# 退出码: 0 = 无 FAIL（允许有 WARN）；1 = 存在 FAIL；2 = 运行目录不存在
# 供运维日常与 CI 复用
set -o pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

TARGET_DIR="swanlab"
[ $# -gt 0 ] && TARGET_DIR="$1"

echo "${bold}===== SwanLab Self-Hosted（docker-v2）巡检 =====${reset}"
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
for f in ".env" "docker-compose.yaml" "config/traefik/traefik.yaml" "config/traefik/dynamic/middlewares.yaml" "config/vector/vector.yaml" "config/vector/render.sh" "config/clickhouse/system-logs.xml"; do
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

# ---------------- 3. 配置校验 ----------------
echo "${bold}----- 3. 配置校验 -----${reset}"
if [ -f "$ENV_FILE" ]; then
  if validate_env "$ENV_FILE" 2>&1; then
    :
  else
    fail_ "配置校验未通过（详见上方输出）"
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

# ---------------- 5. 项目一致性（跨目录容器检测） ----------------
echo "${bold}----- 5. 项目一致性 -----${reset}"
if foreign_project_container "$TARGET_DIR"; then
  fail_ "项目 swanlab 中存在由其他目录启动的容器: ${FOREIGN_CONTAINER}（working_dir ${FOREIGN_WD}）——两套部署会互相干扰，请先完成 migrate.sh 原地迁移，或在另一个目录执行 docker compose down"
else
  pass_ "项目 swanlab 无其他目录的容器"
fi

# ---------------- 6. vector 实例检查 ----------------
# 实例按 vector-N 命名，每个进程独占自己的数据目录；默认 vector-1 / vector-2
echo "${bold}----- 6. vector 实例 -----${reset}"
vector_service_list=$(vector_services "$TARGET_DIR") || vector_service_list=""
if [ -z "$vector_service_list" ]; then
  fail_ "配置中未找到 Vector 服务（应为 vector-1 / vector-2 或 vector-N）"
elif printf '%s\n' "$vector_service_list" | grep -qx 'vector'; then
  fail_ "运行目录仍是单实例 vector 配置，请按升级流程切换到 vector-1 / vector-2"
else
  vector_service_n=$(printf '%s\n' "$vector_service_list" | awk 'NF {n++} END {print n+0}')
  if [ "$vector_service_n" -lt 2 ]; then
    fail_ "配置中只有 ${vector_service_n} 个 Vector 服务；默认部署应为 vector-1 / vector-2"
  fi
  VECTOR_SOURCES=()
  for vector_service in $vector_service_list; do
    if ! vector_n=$(vector_replica_count "$TARGET_DIR" "$vector_service"); then
      fail_ "无法查询 ${vector_service}，请检查运行目录是否已升级为多实例配置"
      continue
    fi
    if [ "$vector_n" -eq 0 ]; then
      warn_ "未发现 ${vector_service} 容器"
    elif [ "$vector_n" -ne 1 ]; then
      fail_ "${vector_service} 有 ${vector_n} 个容器；每个服务必须独占缓冲目录，禁止 --scale"
    else
      vector_id=$(cd "$TARGET_DIR" && docker compose ps -aq "$vector_service")
      vector_source=$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/var/lib/vector"}}{{.Source}}{{end}}{{end}}' "$vector_id")
      if [ -z "$vector_source" ]; then
        fail_ "${vector_service} 未挂载 /var/lib/vector"
      else
        pass_ "${vector_service} 单进程挂载缓冲目录: ${vector_source}"
        VECTOR_SOURCES+=("$vector_source")
      fi
    fi
  done
  vector_mount_conflict=0
  for ((i = 0; i < ${#VECTOR_SOURCES[@]}; i++)); do
    for ((j = i + 1; j < ${#VECTOR_SOURCES[@]}; j++)); do
      if [ "${VECTOR_SOURCES[i]}" = "${VECTOR_SOURCES[j]}" ] || [ "${VECTOR_SOURCES[i]}" -ef "${VECTOR_SOURCES[j]}" ]; then
        fail_ "Vector 实例挂载了同一个数据目录（${VECTOR_SOURCES[i]}），请停止写入并修正挂载，保留缓冲数据"
        vector_mount_conflict=1
      fi
    done
  done
  if [ "$vector_mount_conflict" -eq 0 ] && [ "${#VECTOR_SOURCES[@]}" -ge 2 ] && [ "${#VECTOR_SOURCES[@]}" -eq "$vector_service_n" ]; then
    pass_ "各 Vector 实例的数据目录互相独立"
  fi
fi
vector_project=$(compose_project_name "$TARGET_DIR")
legacy_ids=$(docker ps -aq --filter "label=com.docker.compose.project=${vector_project}" --filter 'label=com.docker.compose.service=vector')
for legacy_id in $legacy_ids; do
  if [ "$(docker inspect --format '{{.State.Running}}' "$legacy_id")" = "true" ]; then
    fail_ "旧 vector 容器仍在运行，可能占用实例 1 的缓冲目录；请按升级流程停止旧容器"
  else
    warn_ "旧 vector 容器已停止并保留；vector/ 是实例 1 的有效数据目录，请勿清空"
  fi
done

# ---------------- 7. 容器健康 ----------------
echo "${bold}----- 7. 容器状态 -----${reset}"
ids=$( (cd "$TARGET_DIR" && docker compose ps -aq 2>/dev/null) )
if [ -z "$ids" ]; then
  warn_ "无运行容器（服务未启动或已 down）"
else
  for id in $ids; do
    name=$(docker inspect --format '{{.Name}}' "$id" 2>/dev/null | sed 's#^/##')
    svc=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.service"}}' "$id" 2>/dev/null)
    case "$svc" in gateway-plugins|minio-init|server-migrate) continue ;; esac   # 一次性服务，退出即正常
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

# ---------------- 8. 磁盘余量 ----------------
echo "${bold}----- 8. 磁盘 -----${reset}"
DATA_PATH_V=$(env_get DATA_PATH "$ENV_FILE")
[ -z "$DATA_PATH_V" ] && DATA_PATH_V="./data"
case "$DATA_PATH_V" in
  /*) CHECK_PATH="$DATA_PATH_V" ;;
  *)  CHECK_PATH="${TARGET_DIR}/${DATA_PATH_V}" ;;
esac
p="$CHECK_PATH"
while [ ! -d "$p" ] && [ "$p" != "/" ]; do p=$(dirname "$p"); done
# -P：POSIX 格式输出，避免长设备名折行
avail_kb=$(df -kP "$p" 2>/dev/null | awk 'NR==2{print $4}')
if [ -n "$avail_kb" ]; then
  avail_gib=$((avail_kb / 1024 / 1024))
  if [ "$avail_gib" -ge "$VECTOR_DISK_RECOMMENDED_GIB" ]; then
    pass_ "磁盘剩余 ${avail_gib}GiB（≥ ${VECTOR_DISK_RECOMMENDED_GIB}GiB，满足 Vector 缓冲与运行余量）"
  elif [ "$avail_gib" -ge "$VECTOR_DISK_MIN_FREE_GIB" ]; then
    warn_ "磁盘剩余 ${avail_gib}GiB（< ${VECTOR_DISK_RECOMMENDED_GIB}GiB，低于推荐余量）"
  else
    fail_ "磁盘剩余 ${avail_gib}GiB（< ${VECTOR_DISK_MIN_FREE_GIB}GiB，磁盘空间不足）"
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

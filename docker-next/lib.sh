#!/bin/bash
# lib.sh — docker-next 脚本共用函数库
# 由 install.sh / upgrade.sh（以及后续 configure.sh / check.sh / migrate.sh）source，不单独执行
# 兼容 bash 3.2（macOS 系统自带），不使用 mapfile / 关联数组等 bash4 特性

# ---------------- 输出 ----------------
if command -v tput >/dev/null 2>&1; then
  red=$(tput setaf 1)
  green=$(tput setaf 2)
  yellow=$(tput setaf 3)
  bold=$(tput bold)
  reset=$(tput sgr0)
else
  red=""; green=""; yellow=""; bold=""; reset=""
fi

log_info() { echo "🧐 $*"; }
log_ok()   { echo "✅ ${green}$*${reset}"; }
log_warn() { echo "⚠️  ${yellow}$*${reset}"; }
log_err()  { echo "❌ ${red}$*${reset}" >&2; }
die()      { log_err "$@"; exit 1; }

# ---------------- 环境检查 ----------------

# docker 已安装且 daemon 运行（Linux 提供自动拉起选项，对齐旧版 install.sh 交互）
require_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    die "Docker 未安装，请先安装 Docker"
  fi
  if docker info >/dev/null 2>&1; then
    log_ok "Docker daemon 运行中"
    return 0
  fi
  log_warn "Docker daemon 未运行"
  if [ "$(uname -s)" = "Linux" ]; then
    read -p "😁 是否现在启动 Docker? (y/n): " START_DOCKER
    if [[ "$START_DOCKER" =~ ^[Yy]$ ]]; then
      systemctl start docker || die "启动 Docker 失败（可能需要 sudo）"
      local i
      for i in 1 2 3 4 5 6 7 8 9 10; do
        systemctl is-active --quiet docker && break
        sleep 1
      done
      systemctl is-active --quiet docker && log_ok "Docker 已启动" || die "Docker 启动失败"
    else
      die "Docker 未运行，操作取消"
    fi
  else
    die "请手动启动 Docker Desktop 后重试"
  fi
}

# compose >= v2.24（depends_on.required 长语法的版本闸门）
# compose_version_ok：仅返回码判断（0=满足 2=不可用 1=版本过低），不输出不退出
compose_version_ok() {
  local ver major minor
  ver=$(docker compose version --short 2>/dev/null | sed 's/^v//' | cut -d- -f1)
  [ -n "$ver" ] || return 2
  major=$(echo "$ver" | cut -d. -f1)
  minor=$(echo "$ver" | cut -d. -f2)
  major=${major:-0}
  minor=${minor:-0}
  [ "$major" -gt 2 ] || { [ "$major" -eq 2 ] && [ "$minor" -ge 24 ]; }
}

require_compose_v224() {
  local ver
  ver=$(docker compose version --short 2>/dev/null | sed 's/^v//' | cut -d- -f1)
  if ! compose_version_ok; then
    die "需要 docker compose >= v2.24（当前 ${ver:-不可用}；depends_on.required 长语法依赖此版本）"
  fi
  log_ok "docker compose 版本满足要求（${ver} >= 2.24）"
}

# 探测 docker socket 路径（rootless / OrbStack 差异），结果写入 DOCKER_SOCKET_PATH
resolve_docker_socket_path() {
  local docker_host="${DOCKER_HOST:-}"
  local rootless_socket
  rootless_socket="/run/user/$(id -u)/docker.sock"

  if [ -z "$docker_host" ]; then
    docker_host=$(docker context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null || true)
  fi

  if [[ "$docker_host" == unix://* ]]; then
    DOCKER_SOCKET_PATH="${docker_host#unix://}"
  elif [ -S "$rootless_socket" ]; then
    DOCKER_SOCKET_PATH="$rootless_socket"
  else
    DOCKER_SOCKET_PATH="/var/run/docker.sock"
  fi

  if [ ! -S "$DOCKER_SOCKET_PATH" ]; then
    log_warn "未在 ${DOCKER_SOCKET_PATH} 找到 docker socket，gateway 可能无法访问 Docker 事件"
  else
    log_ok "使用 Docker socket: ${DOCKER_SOCKET_PATH}"
  fi
}

# 随机密码（数字 + 大小写字母，10 位）
random_password() {
  openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | cut -c1-10
}

# 探测混入本项目的"外来"容器：属于 compose 项目 <project>、但 working_dir 不是 <run_dir>
# 结果写入全局 FOREIGN_CONTAINER / FOREIGN_WD（未发现时 FOREIGN_CONTAINER 为空，返回 1）
# 供 install 预检、check.sh 混栈巡检与 migrate.sh 共用
# 第二个参数为 compose 项目名（默认 swanlab）；migrate.sh 的旧目录名不保证是 swanlab
foreign_project_container() {
  local run_dir="$1" project="${2:-swanlab}" run_dir_abs parent ids id
  FOREIGN_CONTAINER=""
  FOREIGN_WD=""
  if [ -d "$run_dir" ]; then
    run_dir_abs=$(cd "$run_dir" && pwd)
  else
    parent=$(dirname "$run_dir")
    [ -d "$parent" ] || parent="."
    run_dir_abs=$(cd "$parent" && pwd)/$(basename "$run_dir")
  fi

  ids=$(docker ps -a --filter "label=com.docker.compose.project=${project}" --format '{{.ID}}' 2>/dev/null)
  for id in $ids; do
    FOREIGN_WD=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$id" 2>/dev/null)
    [ -z "$FOREIGN_WD" ] && continue
    if [ "$FOREIGN_WD" != "$run_dir_abs" ]; then
      FOREIGN_CONTAINER=$(docker inspect --format '{{.Name}}' "$id" 2>/dev/null | sed 's#^/##')
      return 0
    fi
  done
  FOREIGN_WD=""
  return 1
}

# 项目名占用预检（install 专用；migrate.sh 原地迁移有意沿用项目名，不调用此函数）
# 项目名固定 swanlab（原地迁移依赖同名接管网络/卷/容器前缀）。若同名 compose 项目
# 已存在于其他运行目录（如旧版 docker 部署——旧安装器默认目录也叫 swanlab/），
# 并存安装会导致：宿主机端口抢占、两栈容器互为 orphan、docker compose 将两份
# compose 文件合并进同一项目视图（清理任一侧波及另一侧）——必须拒绝。
require_project_name_free() {
  if foreign_project_container "$1"; then
    log_err "检测到 compose 项目 swanlab 已部署于其他目录：容器 ${FOREIGN_CONTAINER}（working_dir ${FOREIGN_WD}）"
    log_err "项目名固定为 swanlab（原地迁移语义），并存安装会造成端口抢占与容器互为 orphan。"
    log_err "存量部署请使用 migrate.sh 原地迁移（./migrate.sh <旧目录>）；或先在旧目录执行 docker compose down 后重试。"
    exit 1
  fi
  return 0
}

# ---------------- .env 解析与防呆校验 ----------------

# env_get <key> <file>：取值（支持值中含 =），文件或键不存在时输出空
# 同一文件存在重复键时取最后一条——与 docker compose 的 .env 解析语义一致
# （compose 渲染时后写的键覆盖先写的；校验侧若取首条会与实际生效配置脱节）
env_get() {
  [ -f "$2" ] || return 0
  grep -E "^${1}=" "$2" 2>/dev/null | tail -1 | cut -d= -f2-
}

# 防呆校验（install / upgrade / 后续 configure / check / migrate 共用）
# 规则（plan §7.3）：
#   - profile 开 + 外接串已填 → 警告（外接串生效，本机容器空转）
#   - profile 关 + 外接串为空 → 错误（compose 回退本机默认连接串，指向不存在的容器）
#   - SS_STORAGE_TYPE 枚举校验 + 与 minio profile / S3_* 变量一致性
validate_env() {
  local envfile="$1"
  [ -f "$envfile" ] || die ".env 不存在: ${envfile}"

  local profiles
  profiles=$(env_get COMPOSE_PROFILES "$envfile")
  has_profile() {
    case ",${profiles}," in *",$1,"*) return 0 ;; esac
    return 1
  }

  local errors=0 v

  # compose 镜像 tag 不设回退默认（v${SWANLAB_VERSION}），丢键会渲染出 ":v" 到拉镜像才失败——在此显式拦截
  [ -z "$(env_get SWANLAB_VERSION "$envfile")" ] && { log_err "SWANLAB_VERSION 不能为空（镜像 tag 依赖此值；对照 .env.example 补写）"; errors=$((errors + 1)); }

  v=$(env_get DATABASE_URL "$envfile")
  if has_profile postgres; then
    [ -n "$v" ] && log_warn "postgres 为本机部署，但 DATABASE_URL 已填写（将连外部实例，本机容器空转）"
    [ -z "$(env_get POSTGRES_PASSWORD "$envfile")" ] && { log_err "本机 postgres 需要 POSTGRES_PASSWORD"; errors=$((errors + 1)); }
  else
    [ -z "$v" ] && { log_err "外接 postgres：DATABASE_URL 不能为空（或把 postgres 加回 COMPOSE_PROFILES）"; errors=$((errors + 1)); }
  fi

  v=$(env_get REDIS_URL "$envfile")
  if has_profile redis; then
    [ -n "$v" ] && log_warn "redis 为本机部署，但 REDIS_URL 已填写（将连外部实例，本机容器空转）"
  else
    [ -z "$v" ] && { log_err "外接 redis：REDIS_URL 不能为空（或把 redis 加回 COMPOSE_PROFILES）"; errors=$((errors + 1)); }
  fi

  v=$(env_get CLICKHOUSE_HOST "$envfile")
  if has_profile clickhouse; then
    [ -n "$v" ] && log_warn "clickhouse 为本机部署，但 CLICKHOUSE_HOST 已填写（house/vector 将连外部实例）"
    [ -z "$(env_get CLICKHOUSE_PASSWORD "$envfile")" ] && { log_err "本机 clickhouse 需要 CLICKHOUSE_PASSWORD"; errors=$((errors + 1)); }
  else
    if [ -z "$v" ]; then
      log_err "外接 clickhouse：CLICKHOUSE_HOST 不能为空（或把 clickhouse 加回 COMPOSE_PROFILES）"
      errors=$((errors + 1))
    fi
    [ -z "$(env_get CLICKHOUSE_PASSWORD "$envfile")" ] && { log_err "外接 clickhouse：CLICKHOUSE_PASSWORD 不能为空"; errors=$((errors + 1)); }
    [ -z "$(env_get CLICKHOUSE_USER "$envfile")" ] && { log_err "外接 clickhouse：CLICKHOUSE_USER 不能为空"; errors=$((errors + 1)); }
  fi

  local sst missing
  sst=$(env_get SS_STORAGE_TYPE "$envfile")
  case "$sst" in
    local)
      has_profile minio || { log_err "SS_STORAGE_TYPE=local 需要 minio 在 COMPOSE_PROFILES 中"; errors=$((errors + 1)); }
      [ -z "$(env_get MINIO_ROOT_PASSWORD "$envfile")" ] && { log_err "本机 minio 需要 MINIO_ROOT_PASSWORD"; errors=$((errors + 1)); }
      ;;
    remote)
      has_profile minio && { log_err "SS_STORAGE_TYPE=remote 时不应保留 minio profile（请从 COMPOSE_PROFILES 移除）"; errors=$((errors + 1)); }
      # required 字段对齐 chart templates/s3/_helpers.tpl（integrations.s3.enabled 时
      # endpoint/region/port/bucket/domain 均 required，渲染即失败）——compose 侧静默
      # 给本机口径（region=local/port=9000/ssl=false/domain=""）是云 S3 必坏配置，须拦下
      missing=""
      [ -z "$(env_get S3_PUBLIC_ENDPOINT "$envfile")" ] && missing="${missing} S3_PUBLIC_ENDPOINT"
      [ -z "$(env_get S3_PRIVATE_ENDPOINT "$envfile")" ] && missing="${missing} S3_PRIVATE_ENDPOINT"
      [ -z "$(env_get S3_PUBLIC_REGION "$envfile")" ] && missing="${missing} S3_PUBLIC_REGION"
      [ -z "$(env_get S3_PRIVATE_REGION "$envfile")" ] && missing="${missing} S3_PRIVATE_REGION"
      [ -z "$(env_get S3_PUBLIC_DOMAIN "$envfile")" ] && missing="${missing} S3_PUBLIC_DOMAIN"
      [ -z "$(env_get S3_ACCESS_KEY "$envfile")" ] && missing="${missing} S3_ACCESS_KEY"
      [ -z "$(env_get S3_SECRET_KEY "$envfile")" ] && missing="${missing} S3_SECRET_KEY"
      [ -n "$missing" ] && { log_err "SS_STORAGE_TYPE=remote 缺少必要变量:${missing}（桶需预先创建）"; errors=$((errors + 1)); }
      # 端口/协议不强拦（内网 http S3 合法），但疑似本机 MinIO 口径时强提示
      if [ "$(env_get S3_PUBLIC_PORT "$envfile")" = "9000" ] && [ "$(env_get S3_PUBLIC_USE_SSL "$envfile")" = "false" ]; then
        log_warn "外接 S3 端口 9000 且未启用 SSL——疑似本机 MinIO 口径（chart 外接默认 443/true），请确认与外部存储实际一致"
      fi
      # path-style 同理：外接默认 false（vhost，云 S3 口径），true 仅 MinIO 兼容存储需要
      if [ "$(env_get S3_PUBLIC_PATH_STYLE "$envfile")" = "true" ] && [ "$(env_get S3_PRIVATE_PATH_STYLE "$envfile")" = "true" ]; then
        log_warn "外接 S3 path-style=true——云 S3 通常为 false（virtual-hosted style）；仅 MinIO 兼容存储需要 true，请确认"
      fi
      ;;
    *)
      log_err "SS_STORAGE_TYPE 必须为 local 或 remote（当前: '${sst}'）"
      errors=$((errors + 1))
      ;;
  esac

  [ "$errors" -eq 0 ] || return 1
  log_ok "防呆校验通过（COMPOSE_PROFILES=${profiles:-<空>} / SS_STORAGE_TYPE=${sst}）"
}

# env_set <key> <value> <file>：更新或追加一个键（值原样写入，不经 shell/sed 解释）
# 先剔除该键全部旧行（顺带消重复键）再追加——与 compose "最后一条生效"语义一致
# 经 cat > 写回，保留原文件权限（.env 的 600）
env_set() {
  local key="$1" value="$2" file="$3" tmp
  [ -f "$file" ] || die ".env 不存在: ${file}"
  tmp=$(mktemp) || die "mktemp 失败"
  grep -vE "^${key}=" "$file" > "$tmp" 2>/dev/null || true
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  cat "$tmp" > "$file" || { rm -f "$tmp"; die "写入 ${file} 失败"; }
  rm -f "$tmp"
}

# profile 列表维护（COMPOSE_PROFILES 逗号串）
profile_add() {  # <profiles> <name>
  case ",$1," in *",$2,"*) echo "$1" ;; *) echo "${1:+$1,}$2" ;; esac
}

profile_remove() {  # <profiles> <name>
  echo "$1" | tr ',' '\n' | grep -vx -- "$2" | paste -sd, -
}

# 磁盘剩余空间检查（对齐 chart vector persistence 40Gi / buffer ≥3× 语义：
# 三个 sink 各 10Gi disk buffer，when_full=block 最坏 30Gi，且与 pg/CH/minio 数据同盘）
# check_disk_space <路径> <最小GiB> <模式: strict|confirm|warn>
#   strict  不足即 die（安装等不可降级场景）
#   confirm 交互确认后继续；非交互终端（管道/CI）降级为 warn
#   warn    仅警告
# 路径不存在时向上取最近存在的祖先目录（安装前数据目录尚未创建）
check_disk_space() {
  local path="$1" min_gib="$2" mode="${3:-warn}" p avail_kb avail_gib
  p="$path"
  while [ ! -d "$p" ] && [ "$p" != "/" ]; do p=$(dirname "$p"); done
  # -P：POSIX 单行输出——GNU df 对长设备名（LVM /dev/mapper/*）会折行，NR==2 会取到 Use%
  avail_kb=$(df -kP "$p" 2>/dev/null | awk 'NR==2{print $4}')
  if [ -z "$avail_kb" ]; then
    log_warn "无法检测磁盘剩余空间（df 无输出），跳过检查"
    return 0
  fi
  avail_gib=$((avail_kb / 1024 / 1024))
  if [ "$avail_gib" -ge "$min_gib" ]; then
    log_ok "磁盘剩余空间: ${avail_gib}GiB（要求 ≥ ${min_gib}GiB）"
    return 0
  fi
  local reason="vector 磁盘缓冲最坏 30Gi（3 sink × 10Gi，when_full=block），与 pg/ClickHouse/minio 数据同盘，不足可能连坐故障"
  case "$mode" in
    strict)
      die "磁盘剩余空间 ${avail_gib}GiB < ${min_gib}GiB：${reason}——请更换数据路径或清理磁盘后重试"
      ;;
    confirm)
      log_warn "磁盘剩余空间 ${avail_gib}GiB < ${min_gib}GiB（${reason}）"
      if [ -t 0 ]; then
        read -p "   仍要继续? (y/N): " ANS_DISK
        [[ "$ANS_DISK" =~ ^[Yy]$ ]] || die "已取消（可指定其他数据路径后重试）"
      else
        log_warn "非交互环境，继续执行（自担风险）"
      fi
      ;;
    warn)
      log_warn "磁盘剩余空间 ${avail_gib}GiB < ${min_gib}GiB（${reason}）"
      ;;
  esac
}

# ---------------- compose 操作 ----------------

# 运行目录对应的 compose 项目名（.env 的 COMPOSE_PROJECT_NAME 优先，否则 compose 取目录名）
# 解析失败（compose 不可渲染）时回退为目录名——旧版 docker 部署的 .env 不含该键，即取 swanlab/
compose_project_name() {
  local run_dir="$1" name=""
  if [ -d "$run_dir" ]; then
    name=$( (cd "$run_dir" && docker compose config 2>/dev/null) | sed -n 's/^name:[[:space:]]*//p' | head -1 )
  fi
  [ -n "$name" ] || name=$(basename "${run_dir%/}")
  printf '%s\n' "$name"
}

# 本项目 vector 容器数（含已停止；-a），供 check.sh 防呆
# plan §6：vector 固定单实例——compose 的 --scale 副本共享同一 bind mount，
# 而 vector disk buffer 是单写者 WAL + ack ledger，多进程共写同一目录必然损坏
vector_replica_count() {
  local run_dir="$1" n
  n=$( (cd "$run_dir" && docker compose ps -aq vector 2>/dev/null) | grep -c . )
  printf '%s\n' "${n:-0}"
}

# 渲染检查（cwd 无关，内部 cd；compose 自动读取运行目录的 .env）
render_check() {
  local run_dir="$1"
  (cd "$run_dir" && docker compose config --quiet) \
    || die "docker compose 渲染失败，请检查 ${run_dir}/.env 与 docker-compose.yaml"
  log_ok "compose 渲染通过"
}

# compose 当前实际启用（按 .env 的 COMPOSE_PROFILES 过滤）的镜像清单，去重
# compose >= 2.20 提供 config --images；旧版本无此 flag 时回退解析 config 的 image 字段
# 解析失败/为空时返回 1——调用方须与"无需镜像"区分
compose_required_images() {
  local run_dir="$1" out
  out=$( (cd "$run_dir" && docker compose config --images 2>/dev/null) )
  if [ -z "$out" ]; then
    out=$( (cd "$run_dir" && docker compose config 2>/dev/null) \
      | awk '/^[[:space:]]+image: /{print $2}' | tr -d '"' )
  fi
  [ -n "$out" ] || return 1
  printf '%s\n' "$out" | sort -u
}

# 校验 compose 所需镜像是否已全部存在于本地 Docker（离线/内网部署前置检查）
# 齐备返回 0；缺失时打印缺失清单并返回 1
verify_local_images() {
  local run_dir="$1" images img missing="" count
  images=$(compose_required_images "$run_dir") || {
    log_err "无法解析 compose 所需镜像清单（docker compose config 失败？）"
    return 1
  }
  for img in $images; do
    docker image inspect "$img" >/dev/null 2>&1 || missing="${missing} ${img}"
  done
  if [ -n "$missing" ]; then
    log_err "本地缺少以下镜像:${missing}"
    return 1
  fi
  count=$(printf '%s\n' "$images" | wc -l | tr -d ' ')
  log_ok "所需镜像均已存在于本地（${count} 个）"
  return 0
}

# 拉取镜像，带离线降级：pull 失败时只要所需镜像已全部在本地就继续，不直接 die
# pull_images <run_dir> <offline: 0|1>
# 依据：离线/内网环境下 docker compose pull 即使本地已有镜像也会尝试连接 registry
# 校验元数据，连接失败即整体退出——若因此终止，离线部署（docker load 导入镜像）无法进行
pull_images() {
  local run_dir="$1" offline="${2:-0}"
  if [ "$offline" -eq 1 ]; then
    log_info "离线模式：跳过 docker compose pull，直接校验本地镜像"
    verify_local_images "$run_dir"
    return $?
  fi
  log_info "拉取全部镜像（docker compose pull）..."
  if (cd "$run_dir" && docker compose pull); then
    return 0
  fi
  log_warn "docker compose pull 失败（离线/内网或 Registry 不可达）"
  log_info "降级：校验 compose 所需镜像是否已在本地..."
  verify_local_images "$run_dir"
}

# 由 .env 推导需要健康等待的服务清单（不含一次性 gateway-plugins / minio-init）
compose_services_for_profiles() {
  local envfile="$1"
  local profiles
  profiles=$(env_get COMPOSE_PROFILES "$envfile")
  local svcs="gateway vector swanlab-server swanlab-auth swanlab-house swanlab-cloud swanlab-next"
  case ",$profiles," in *,postgres,*) svcs="$svcs postgres" ;; esac
  case ",$profiles," in *,redis,*) svcs="$svcs redis" ;; esac
  case ",$profiles," in *,clickhouse,*) svcs="$svcs clickhouse" ;; esac
  case ",$profiles," in *,minio,*) svcs="$svcs minio" ;; esac
  echo "$svcs"
}

# 副本感知的健康等待：逐服务枚举其全部容器，等待每一个 healthcheck 变 healthy
# 容器退出/崩溃重启时健康探针不再推进（restart 策略下停在 State.Status=restarting），
# 只观察 Health.Status 会盲等到 timeout（默认 300s）——须同时观察 State.Status 快速失败
wait_services_healthy() {
  local run_dir="$1" timeout="${2:-300}"
  local svcs failed svc ids id name status run_state info i
  svcs=$(compose_services_for_profiles "$run_dir/.env")
  failed=""

  for svc in $svcs; do
    ids=$( (cd "$run_dir" && docker compose ps -aq "$svc") )
    if [ -z "$ids" ]; then
      log_warn "服务 ${svc} 没有容器（profile 未激活或未启动），跳过健康等待"
      continue
    fi
    for id in $ids; do
      name=$(docker inspect --format '{{.Name}}' "$id" 2>/dev/null | sed 's#^/##')
      echo -n "🔍 等待 ${name} ..."
      status=""
      run_state=""
      i=0
      while [ "$i" -lt "$timeout" ]; do
        # 一次 inspect 同时取运行态与健康态（run_state 不含空格，可安全按空格切分）
        info=$(docker inspect --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$id" 2>/dev/null)
        run_state=${info%% *}
        status=${info##* }
        case "$run_state" in
          # 容器从未启动(created) / 已退出 / 崩溃重启 / 已被移除：健康检查不会再有结果，立即失败不空等
          created|exited|dead|restarting|"") break ;;
        esac
        [ "$status" = "healthy" ] && break
        [ "$status" = "none" ] && break
        sleep 2
        i=$((i + 2))
      done
      case "$run_state" in
        created|exited|dead|restarting)
          echo " ❌ 容器未运行（State.Status=${run_state}，未启动/启动失败或崩溃重启）"
          failed="$failed $name"
          ;;
        "")
          echo " ❌ 容器不存在（inspect 失败，可能已被重建/移除）"
          failed="$failed $name"
          ;;
        *)
          if [ "$status" = "healthy" ]; then
            echo " ✅ healthy"
          elif [ "$status" = "none" ]; then
            echo " ⏭️  无健康检查，跳过"
          else
            echo " ❌ ${status:-timeout}"
            failed="$failed $name"
          fi
          ;;
      esac
    done
  done

  if [ -n "$failed" ]; then
    log_err "以下容器未在 ${timeout}s 内变为健康:${failed}"
    echo "💡 查看日志: cd ${run_dir} && docker compose logs <service>"
    return 1
  fi
  log_ok "全部服务健康"
}

# ---------------- 收尾输出 ----------------

print_access_urls() {
  local port="$1"
  local lan_ip="" wan_ip="" os_type
  echo "🎉 安装完成！可通过以下地址访问 SwanLab："
  echo "   > Local:    http://localhost:${port}"
  echo "               http://127.0.0.1:${port}"
  os_type=$(uname -s)
  if [ "$os_type" = "Linux" ]; then
    lan_ip=$(ip route get 1 2>/dev/null | awk '{print $7; exit}')
    [ -z "$lan_ip" ] && lan_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  elif [ "$os_type" = "Darwin" ]; then
    lan_ip=$(ifconfig 2>/dev/null | grep "inet " | grep -v "127.0.0.1" | awk '{print $2}' | head -n 1)
  fi
  [ -n "$lan_ip" ] && echo "   > Network:  http://${lan_ip}:${port}"
  if command -v curl >/dev/null 2>&1; then
    wan_ip=$(curl -s --max-time 2 ifconfig.me 2>/dev/null)
  fi
  [ -n "$wan_ip" ] && echo "   > Internet: http://${wan_ip}:${port}（需开放端口/防火墙）"
  echo
}

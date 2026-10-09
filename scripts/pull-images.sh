#!/bin/bash

# 拉取 self-hosted 全量镜像；默认仅拉取，加 --save 时才打包为 tar（离线部署用）
# 用法: ./pull-images.sh [--v2] [--save] [--list]
#   (默认)  只 docker pull 旧 docker 版（v1，fluent-bit 架构）镜像，存量维护
#   --v2    拉取 docker-v2 架构镜像（基于 vector 管道）
#   --save  额外执行 docker save 打包到 ./swanlab_images.tar
#   --list  只打印将拉取的镜像清单，不执行 pull
#
# 镜像清单定义于本脚本与 docker-v2/docker-compose.yaml 中。
# 应用镜像 tag 与 docker-v2/.env 的 SWANLAB_VERSION 保持一致。

# 旧 docker 版（存量架构）镜像
images_legacy=(
  "repo.swanlab.cn/self-hosted/traefik:v3.1"
  "repo.swanlab.cn/self-hosted/postgres:16.1"
  "repo.swanlab.cn/self-hosted/redis-stack:7.2.0-v15"
  "repo.swanlab.cn/self-hosted/clickhouse-server:24.3"
  "repo.swanlab.cn/self-hosted/logrotate:1.0"
  "repo.swanlab.cn/self-hosted/fluent-bit:3.1"
  "repo.swanlab.cn/self-hosted/minio/minio:RELEASE.2025-02-28T09-55-16Z"
  "repo.swanlab.cn/self-hosted/minio/mc:RELEASE.2025-04-08T15-39-49Z"
  "repo.swanlab.cn/self-hosted/swanlab-server:v3.4.0"
  "repo.swanlab.cn/self-hosted/swanlab-house:v3.4.0"
  "repo.swanlab.cn/self-hosted/swanlab-cloud:v3.4.0"
  "repo.swanlab.cn/self-hosted/swanlab-next:v3.4.0"
)

# docker-v2 架构镜像
images_v2=(
  "repo.swanlab.cn/public/traefik:3.6"
  "repo.swanlab.cn/public/swanlab-helper/identify:v1.2"
  "repo.swanlab.cn/public/vector:0.51.1-debian"
  "repo.swanlab.cn/self-hosted/postgres:16.1"
  "repo.swanlab.cn/self-hosted/redis-stack:7.4.0-v8"
  "repo.swanlab.cn/self-hosted/clickhouse-server:24.3"
  "repo.swanlab.cn/self-hosted/minio/minio:RELEASE.2025-09-07T16-13-09Z"
  "repo.swanlab.cn/self-hosted/minio/mc:RELEASE.2025-08-13T08-35-41Z"
  "repo.swanlab.cn/self-hosted/swanlab-server:v3.4.0"
  "repo.swanlab.cn/self-hosted/swanlab-auth:v3.4.0"
  "repo.swanlab.cn/self-hosted/swanlab-house:v3.4.0"
  "repo.swanlab.cn/self-hosted/swanlab-cloud:v3.4.0"
  "repo.swanlab.cn/self-hosted/swanlab-next:v3.4.0"
)

V2=0
SAVE=0
LIST=0
for arg in "$@"; do
  case "$arg" in
    --v2) V2=1 ;;
    --save) SAVE=1 ;;
    --list) LIST=1 ;;
    *)
      echo "未知参数: $arg（仅支持 --v2 / --save / --list）" >&2
      exit 1
      ;;
  esac
done

if [ "$V2" -eq 1 ]; then
  images=("${images_v2[@]}")
else
  images=("${images_legacy[@]}")
fi

# --list：输出镜像清单
if [ "$LIST" -eq 1 ]; then
  echo "将拉取以下 ${#images[@]} 个镜像:"
  printf '%s\n' "${images[@]}"
  exit 0
fi

# 下载镜像
for image in "${images[@]}"; do
  docker pull "$image" || exit 1
done

# 保存镜像到文件（仅 --save 时）
if [ "$SAVE" -eq 1 ]; then
  echo "正在打包所有镜像到 swanlab_images.tar..."
  docker save -o ./swanlab_images.tar "${images[@]}"
  echo "所有镜像已打包至 swanlab_images.tar"
else
  echo "镜像拉取完成（如需离线打包，请追加 --save 参数）"
fi

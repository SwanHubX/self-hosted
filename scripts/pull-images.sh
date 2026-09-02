#!/bin/bash

# 拉取 self-hosted 全量镜像；默认仅拉取，加 --save 时才打包为 tar（离线部署用）
# 用法: ./pull-images.sh [--save]
#   (默认)  只 docker pull 全部镜像
#   --save  额外执行 docker save 打包到 ./swanlab_images.tar

# 定义要下载的镜像列表
images=(
  "repo.swanlab.cn/self-hosted/traefik:v3.1"
  "repo.swanlab.cn/self-hosted/postgres:16.1"
  "repo.swanlab.cn/self-hosted/redis-stack:7.2.0-v15"
  "repo.swanlab.cn/self-hosted/clickhouse-server:24.3"
  "repo.swanlab.cn/self-hosted/logrotate:1.0"
  "repo.swanlab.cn/self-hosted/fluent-bit:3.1"
  "repo.swanlab.cn/self-hosted/minio/minio:RELEASE.2025-02-28T09-55-16Z"
  "repo.swanlab.cn/self-hosted/minio/mc:RELEASE.2025-04-08T15-39-49Z"
  "repo.swanlab.cn/self-hosted/swanlab-server:v3.3.0"
  "repo.swanlab.cn/self-hosted/swanlab-house:v3.3.0"
  "repo.swanlab.cn/self-hosted/swanlab-cloud:v3.3.0"
  "repo.swanlab.cn/self-hosted/swanlab-next:v3.3.0"
)

SAVE=0
for arg in "$@"; do
  case "$arg" in
    --save) SAVE=1 ;;
    *)
      echo "未知参数: $arg（仅支持 --save）" >&2
      exit 1
      ;;
  esac
done

# 下载镜像
for image in "${images[@]}"; do
  docker pull "$image" || exit 1
done

# 保存镜像到文件（仅 --save 时）
if [ "$SAVE" -eq 1 ]; then
  echo "正在打包所有镜像到 swanlab_images.tar..."
  docker save -o ./swanlab_images.tar "${images[@]}"
  echo "所有镜像都打包至 swanlab_images.tar，可直接上传该文件到目标服务器!"
else
  echo "镜像拉取完成（如需离线打包，请追加 --save 参数）"
fi

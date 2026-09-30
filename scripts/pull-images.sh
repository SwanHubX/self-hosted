#!/bin/bash

# 拉取 self-hosted 全量镜像；默认仅拉取，加 --save 时才打包为 tar（离线部署用）
# 用法: ./pull-images.sh [--next] [--save] [--list]
#   (默认)  只 docker pull 旧 docker 版镜像（fluent-bit 架构，存量维护）
#   --next  拉取 docker-next 架构镜像（vector 架构，对齐 charts/charts/self-hosted）
#   --save  额外执行 docker save 打包到 ./swanlab_images.tar
#   --list  只打印将拉取的镜像清单，不执行 pull（先确认地址再拉）
#
# 镜像地址硬编码在本文件与 docker-next/docker-compose.yaml 的 image 行——
# 换平台/换命名空间属低频一次性操作，直接改文件（可用 --list 先核对清单）；
# .env 不承载镜像仓库配置（复杂化设计，已否决）。
#
# 版本更新约定：只改应用镜像 tag（带 v 前缀，与 docker-next/.env 的
# SWANLAB_VERSION 保持一致，如 v3.4.0），基础设施镜像固定不动。

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

# docker-next 架构镜像（对齐 chart values.yaml）
images_next=(
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

NEXT=0
SAVE=0
LIST=0
for arg in "$@"; do
  case "$arg" in
    --next) NEXT=1 ;;
    --save) SAVE=1 ;;
    --list) LIST=1 ;;
    *)
      echo "未知参数: $arg（仅支持 --next / --save / --list）" >&2
      exit 1
      ;;
  esac
done

if [ "$NEXT" -eq 1 ]; then
  images=("${images_next[@]}")
else
  images=("${images_legacy[@]}")
fi

# --list：只打印清单（换源后先核对地址再实际拉取）
if [ "$LIST" -eq 1 ]; then
  echo "将拉取以下 ${#images[@]} 个镜像（换源请直接编辑本文件清单）:"
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
  echo "所有镜像都打包至 swanlab_images.tar，可直接上传该文件到目标服务器!"
else
  echo "镜像拉取完成（如需离线打包，请追加 --save 参数）"
fi

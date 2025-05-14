#!/bin/bash

# 创建保存镜像的目录
mkdir -p ./swanlab_images

# 定义要下载的镜像列表
images=(
  "ccr.ccs.tencentyun.com/self-hosted/traefik:v3.0"
  "ccr.ccs.tencentyun.com/self-hosted/postgres:16.1"
  "ccr.ccs.tencentyun.com/self-hosted/redis-stack-server:7.2.0-v15"
  "ccr.ccs.tencentyun.com/self-hosted/clickhouse:24.3"
  "ccr.ccs.tencentyun.com/self-hosted/logrotate:v1"
  "ccr.ccs.tencentyun.com/self-hosted/fluent-bit:3.0"
  "ccr.ccs.tencentyun.com/self-hosted/minio:RELEASE.2025-02-28T09-55-16Z"
  "ccr.ccs.tencentyun.com/self-hosted/minio-mc:RELEASE.2025-04-08T15-39-49Z"
  "ccr.ccs.tencentyun.com/self-hosted/swanlab-server:v1.1.1"
  "ccr.ccs.tencentyun.com/self-hosted/swanlab-house:v1.1"
  "ccr.ccs.tencentyun.com/self-hosted/swanlab-cloud:v1.1"
  "ccr.ccs.tencentyun.com/self-hosted/swanlab-next:v1.1"
)

# 下载镜像
for image in "${images[@]}"; do
  echo "Pulling $image..."
  docker pull "$image"
done

# 保存镜像到文件
echo "正在打包所有镜像到 swanlab_images.tar.gz..."
docker save "${images[@]}" | gzip > ./swanlab_images/swanlab_images.tar.gz

echo "所有镜像已打包至 swanlab_images/swanlab_images.tar.gz,可直接传输该文件!"
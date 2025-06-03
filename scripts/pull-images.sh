#!/bin/bash

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
  "ccr.ccs.tencentyun.com/self-hosted/swanlab-server:v1.2"
  "ccr.ccs.tencentyun.com/self-hosted/swanlab-house:v1.2"
  "ccr.ccs.tencentyun.com/self-hosted/swanlab-cloud:v1.2"
  "ccr.ccs.tencentyun.com/self-hosted/swanlab-next:v1.2"
)

# 下载镜像
for image in "${images[@]}"; do
  docker pull "$image"
done

# 保存镜像到文件
echo "正在打包所有镜像到 swanlab_images.tar..."
docker save -o ./swanlab_images.tar "${images[@]}"

echo "所有镜像都打包至 swanlab_images.tar，可直接上传该文件到目标服务器!"
#!/bin/bash

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

# 下载镜像
for image in "${images[@]}"; do
  docker pull "$image"
done

# 保存镜像到文件
echo "正在打包所有镜像到 swanlab_images.tar..."
docker save -o ./swanlab_images.tar "${images[@]}"

echo "所有镜像都打包至 swanlab_images.tar，可直接上传该文件到目标服务器!"

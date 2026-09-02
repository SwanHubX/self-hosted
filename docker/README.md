## 通过 Docker 部署

[English](./README_EN.md)

> 首先需要确保你的服务器上安装有 [docker](https://docs.docker.com/engine/install/)。如果未安装，可以参考[文档](https://yeasy.gitbook.io/docker_practice/install)，或者使用我们提供的安装脚本 [scripts/install-docker.sh](../scripts/install-docker.sh)。
> 若你的服务器上未安装Docker Compose插件，可以参考[官方地址](https://github.com/docker/compose/)进行下载安装，或者使用我们提供的安装脚本 [scripts/install-docker-compose.sh](../scripts/install-docker-compose.sh)。

### 在线部署

服务器可以联网时，直接执行 `./install.sh` 脚本即可开始部署。部署成功后会看到下面的 **SwanLab** 标志。

```bash
$ ./install.sh

...
   _____                    _           _
  / ____|                  | |         | |
 | (_____      ____ _ _ __ | |     __ _| |__
  \___ \ \ /\ / / _` | '_ \| |    / _` | '_ \
  ____) \ V  V / (_| | | | | |___| (_| | |_) |
 |_____/ \_/\_/ \__,_|_| |_|______\__,_|_.__/

 Self-Hosted Docker v2.4 - @SwanLab

🎉 Wow, the installation is complete. Everything is perfect.
🥰 Congratulations, self-hosted SwanLab can be accessed using {IP}:8000
```

> `install.sh` 使用国内镜像源，如果是需要使用 [DockerHub](https://hub.docker.com/explore) 源，则可以使用 `install-dockerhub.sh` 脚本部署
> 若使用 Windows 系统进行部署，在安装完成 Docker Desktop 后使用 `install-nowsl.sh` 脚本进行安装。

### 离线部署

1. 在联网机器上下载镜像，运行脚本 [scripts/pull-images.sh](../scripts/pull-images.sh)，该脚本运行结束后会在当前下生成`swanlab_images.tar`文件，该文件包含所有镜像的压缩包。**请确保下载的机器上含有Docker运行环境。**
2. 将 `swanlab_images.tar` 文件上传到目标机器上。（可配合`sftp`工具）
3. 在目标服务器上运行 `docker load -i swanlab_images.tar` 加载镜像，等待加载成功后可以通过 `docker images` 命令查看镜像列表，将会显示所有镜像。
4. 然后跟上述在线部署一样执行 `./install.sh` 即可部署安装。

#### 内网部署（可选）

如果内网环境使用私有 Harbor 仓库托管镜像，而非 `docker load` 直接导入：

1. 在联网机器上，按 [scripts/pull-images.sh](../scripts/pull-images.sh) 中的镜像清单拉取并推送到内网仓库。镜像的 `self-hosted/...` 后缀路径必须原样保留（包括两级路径 `minio/minio`、`minio/mc`）：

   ```bash
   HARBOR="harbor.example.com/swanlab"   # 替换为你的仓库地址
   docker login "${HARBOR%%/*}"          # 私有仓库需先登录
   for image in $(grep -oE '"repo\.swanlab\.cn/[^"]+"' scripts/pull-images.sh | tr -d '"'); do
     target="${HARBOR}/${image#*/}"      # repo.swanlab.cn/self-hosted/xxx -> ${HARBOR}/self-hosted/xxx
     docker pull "$image" && docker tag "$image" "$target" && docker push "$target"
   done
   ```

2. 将部署机 `swanlab/docker-compose.yaml` 中的镜像前缀 `repo.swanlab.cn` 替换为 `harbor.example.com/swanlab`。
3. **升级顺序**：每次版本发布后，先在联网机器按上述步骤预推送新版本镜像，再执行 `./upgrade.sh`。`upgrade.sh` 的注册表迁移逻辑不会改写自定义 Harbor 域名的镜像引用，请保持 compose 中的前缀与 Harbor 路径一致。

### 端口说明

如果你部署在服务器上，并希望远程访问与实验记录，那么确保开放以下两个端口：

| 端口号 | 是否可配置 | 用途说明                                                      |
| ------ | ---------- | ------------------------------------------------------------- |
| 8000   | 是         | 网关服务端口，可用于接收外部请求，建议在公网环境中设置为 `80` |

### 可配置项

脚本执行过程中会提示两个可配置项：

1. 数据保存路径，默认为 `./data`，建议选择一个固定的路径用于长期保存，例如 `/data`。
2. 服务暴露端口，默认为 `8000`，如果是在公网服务器上可以设置为 `80`。

如果不需要交互式配置，脚本还提供了三个命令行选项：

- `-d`：用于指定数据保存路径
- `-p`：服务暴露的端口
- `-s`：用于跳过交互式配置。如果不希望交互式配置，则比如添加 `-s`

例如指定保存路径为 `/data`，同时暴露的端口为 `80`：

```bash
$ ./install.sh -d /data -p 80 -s
```

### 执行结果

脚本执行成功后，将会创建一个 `swanlab/` 目录，并在目录下生成两个文件：

- `docker-compose.yaml`：用于 Docker Compose 的配置文件
- `.env`：对应的密钥文件，保存数据库对应的初始化密码

在 `swanlab` 目录下执行 `docker compose ps -a` 可以查看所有容器的运行状态：

```bash
$ docker compose ps -a                                                                                                                                                                (base)
NAME                 IMAGE                                                                   COMMAND                  SERVICE          CREATED          STATUS                    PORTS
swanlab-clickhouse   repo.swanlab.cn/self-hosted/clickhouse-server:24.3                      "/entrypoint.sh"         clickhouse       22 minutes ago   Up 22 minutes (healthy)   8123/tcp, 9000/tcp, 9009/tcp
swanlab-cloud        repo.swanlab.cn/self-hosted/swanlab-cloud:v1                     "/docker-entrypoint.…"   swanlab-cloud    22 minutes ago   Up 21 minutes             80/tcp
swanlab-fluentbit    repo.swanlab.cn/self-hosted/fluent-bit:3.1                       "/fluent-bit/bin/flu…"   fluent-bit       22 minutes ago   Up 22 minutes             2020/tcp
swanlab-house        repo.swanlab.cn/self-hosted/swanlab-house:v1                     "./app"                  swanlab-house    22 minutes ago   Up 21 minutes (healthy)   3000/tcp
swanlab-logrotate    repo.swanlab.cn/self-hosted/logrotate:1.0                         "/sbin/tini -- /usr/…"   logrotate        22 minutes ago   Up 22 minutes
swanlab-minio        repo.swanlab.cn/self-hosted/minio/minio:RELEASE.2025-02-28T09-55-16Z   "/usr/bin/docker-ent…"   minio            22 minutes ago   Up 22 minutes (healthy)   9000/tcp
swanlab-next         repo.swanlab.cn/self-hosted/swanlab-next:v1                      "docker-entrypoint.s…"   swanlab-next     22 minutes ago   Up 21 minutes             3000/tcp
swanlab-postgres     repo.swanlab.cn/self-hosted/postgres:16.1                        "docker-entrypoint.s…"   postgres         22 minutes ago   Up 22 minutes (healthy)   5432/tcp
swanlab-redis        repo.swanlab.cn/self-hosted/redis-stack:7.2.0-v15         "/entrypoint.sh"         redis            22 minutes ago   Up 22 minutes (healthy)   6379/tcp
swanlab-server       repo.swanlab.cn/self-hosted/swanlab-server:v1                    "docker-entrypoint.s…"   swanlab-server   22 minutes ago   Up 21 minutes (healthy)   3000/tcp
swanlab-traefik      repo.swanlab.cn/self-hosted/traefik:v3.1                         "/entrypoint.sh trae…"   traefik          22 minutes ago   Up 22 minutes (healthy)   0.0.0.0:8000->80/tcp, [::]:8000->80/tcp
```

通过执行 `docker compose logs <container_name>` 可以查看每个容器的日志。

### 升级

执行 `./upgrade.sh` 可以进行无缝升级。可使用`./upgrade.sh file_path`来进行升级，`file_path`为`docker-compose.yaml`文件路径。，默认为`swanlab/docker-compose.yaml`

> 升级过程会自动将旧镜像仓库布局（腾讯云 CCR / 早期 ACR 命名）迁移至 `repo.swanlab.cn`，首次迁移升级会重新拉取全部镜像，旧镜像可通过 `docker image prune` 清理。离线 / 内网 Harbor 用户请先预推送镜像（见[离线部署](#离线部署)），使用自定义 Harbor 域名的 compose 不会被自动改写。

## 通过 Docker 部署

[English](./README_EN.md)

> 首先需要确保你的服务器上安装有 [docker](https://docs.docker.com/engine/install/)。如果未安装，可以参考[文档](https://yeasy.gitbook.io/docker_practice/install)，或者使用我们提供的安装脚本 [scripts/install-docker.sh](../scripts/install-docker.sh)。

一切准备就绪后，直接执行 `./install.sh` 脚本即可开始部署。部署成功后会看到下面的 **SwanLab** 标志。

```bash
$ ./install.sh

...
   _____                    _           _     
  / ____|                  | |         | |    
 | (_____      ____ _ _ __ | |     __ _| |__  
  \___ \ \ /\ / / _` | '_ \| |    / _` | '_ \ 
  ____) \ V  V / (_| | | | | |___| (_| | |_) |
 |_____/ \_/\_/ \__,_|_| |_|______\__,_|_.__/ 
                                              
 Self-Hosted Docker v1.0 - @SwanLab

🎉 Wow, the installation is complete. Everything is perfect.
🥰 Congratulations, self-hosted SwanLab can be accessed using {IP}:8000
```

> `install.sh` 使用国内镜像源，如果是需要使用 [DockerHub](https://hub.docker.com/explore) 源，则可以使用 `install-dockerhub.sh` 脚本部署

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
swanlab-clickhouse   ccr.ccs.tencentyun.com/self-hosted/clickhouse:24.3                      "/entrypoint.sh"         clickhouse       22 minutes ago   Up 22 minutes (healthy)   8123/tcp, 9000/tcp, 9009/tcp
swanlab-cloud        ccr.ccs.tencentyun.com/self-hosted/swanlab-cloud:v1                     "/docker-entrypoint.…"   swanlab-cloud    22 minutes ago   Up 21 minutes             80/tcp
swanlab-fluentbit    ccr.ccs.tencentyun.com/self-hosted/fluent-bit:3.0                       "/fluent-bit/bin/flu…"   fluent-bit       22 minutes ago   Up 22 minutes             2020/tcp
swanlab-house        ccr.ccs.tencentyun.com/self-hosted/swanlab-house:v1                     "./app"                  swanlab-house    22 minutes ago   Up 21 minutes (healthy)   3000/tcp
swanlab-logrotate    ccr.ccs.tencentyun.com/self-hosted/logrotate:v1                         "/sbin/tini -- /usr/…"   logrotate        22 minutes ago   Up 22 minutes             
swanlab-minio        ccr.ccs.tencentyun.com/self-hosted/minio:RELEASE.2025-02-28T09-55-16Z   "/usr/bin/docker-ent…"   minio            22 minutes ago   Up 22 minutes (healthy)   9000/tcp
swanlab-next         ccr.ccs.tencentyun.com/self-hosted/swanlab-next:v1                      "docker-entrypoint.s…"   swanlab-next     22 minutes ago   Up 21 minutes             3000/tcp
swanlab-postgres     ccr.ccs.tencentyun.com/self-hosted/postgres:16.1                        "docker-entrypoint.s…"   postgres         22 minutes ago   Up 22 minutes (healthy)   5432/tcp
swanlab-redis        ccr.ccs.tencentyun.com/self-hosted/redis-stack-server:7.2.0-v15         "/entrypoint.sh"         redis            22 minutes ago   Up 22 minutes (healthy)   6379/tcp
swanlab-server       ccr.ccs.tencentyun.com/self-hosted/swanlab-server:v1                    "docker-entrypoint.s…"   swanlab-server   22 minutes ago   Up 21 minutes (healthy)   3000/tcp
swanlab-traefik      ccr.ccs.tencentyun.com/self-hosted/traefik:v3.0                         "/entrypoint.sh trae…"   traefik          22 minutes ago   Up 22 minutes (healthy)   0.0.0.0:8000->80/tcp, [::]:8000->80/tcp
```

通过执行 `docker compose logs <container_name>` 可以查看每个容器的日志。


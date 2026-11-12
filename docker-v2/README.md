# SwanLab Self-Hosted 部署指南（docker-v2）

`docker-v2` 是新版的 Docker Compose 私有化部署方案（`v3.6.0`）。相比[旧版 docker 单实例方案](../docker/README.md) ，支持**业务服务多副本**、**Vector 高性能指标缓冲管道**以及**数据库/对象存储按需外接配置**。

## 目录

- [1. 环境要求](#1-环境要求)
- [2. 快速部署](#2-快速部署)
- [3. 离线与内网部署](#3-离线与内网部署)
- [4. 配置与外接服务](#4-配置与外接服务)
- [5. 日常运维与扩缩容](#5-日常运维与扩缩容)
- [6. 升级与回滚](#6-升级与回滚)
- [7. 旧版迁移](#7-旧版迁移)
- [8. 架构与常见问题](#8-架构与常见问题)

---

## 1. 环境要求

| 项目               | 要求                 | 说明                                                                                                           |
| :----------------- | :------------------- | :------------------------------------------------------------------------------------------------------------- |
| **Docker Engine**  | `>= 20.10`           | 可通过 [`../scripts/install-docker.sh`](../scripts/install-docker.sh) 安装                                     |
| **Docker Compose** | **`>= v2.24`**       | 必需；可通过系统包管理器或 [`../scripts/install-docker-compose.sh`](../scripts/install-docker-compose.sh) 升级 |
| **配置要求**       | `≥ 8 核 16GB`        | 高负载场景下，较低的配置可能导致部分功能无法正常运行                                                           |
| **磁盘可用空间**   | **建议 `>= 90 GiB`** | 数据分区；2 个 Vector 实例要求预留 80 GiB 缓冲                                                                 |
| **网络端口**       | 默认 `8000`          | Web 网关入口，可通过 `-p` 自定义                                                                               |

---

## 2. 快速部署

> **⚠️ 注意**：`docker-v2/` 是模板目录，请勿直接在此执行 `docker compose up -d`。请通过 `install.sh` 生成运行目录（默认 `./swanlab`）。

### 2.1 执行安装

```bash
git clone https://github.com/SwanHubX/self-hosted.git

cd self-hosted/docker-v2

# 交互式安装（推荐：按提示配置目录、端口及是否外接数据库服务）
./install.sh
```

**参数说明：**

| 参数            | 默认值      | 说明                                                       |
| :-------------- | :---------- | :--------------------------------------------------------- |
| `[运行目录]`    | `./swanlab` | 第一个位置参数，存放生成的 `.env` 与 `docker-compose.yaml` |
| `-d <路径>`     | `./data`    | 数据持久化目录（相对运行目录或绝对路径）                   |
| `-p <端口>`     | `8000`      | 网关暴露端口                                               |
| `-s`            | 关闭        | 跳过交互，数据服务全部本机部署                             |
| `-o, --offline` | 关闭        | 离线模式：跳过 `pull`，仅校验本地镜像                      |

### 2.2 验证与访问

- **浏览器访问**：`http://<服务器IP>:<端口>`（默认 `http://localhost:8000`）
- **健康巡检**：
  ```bash
  ./check.sh ./swanlab
  ```

### 2.3 服务拓扑结构与目录说明

```text
 :8000 ──► gateway (Traefik 3.6)
                ├── /api        ──► swanlab-server (×2) ──► PostgreSQL / Redis / MinIO
                ├── /api/auth   ──► swanlab-auth   (×2)
                ├── /           ──► swanlab-next   (×2) ──► swanlab-cloud (×1)
                └── /api/house  ──► swanlab-house  (×2)
                                         │ HTTP 指标
                                         ▼
                                gateway:8080/vector (内部负载均衡 + /ping 探活)
                                   ├──► vector-1 (data/vector-1/)
                                   └──► vector-2 (data/vector-2/)
                                         │
                                         ▼
                                    ClickHouse
```

**运行目录结构（`swanlab/`）：**

```text
swanlab/
├── .env                          # 环境配置与密钥（权限 600）
├── docker-compose.yaml           # 主编排文件（升级自动覆盖，请勿直接修改）
├── docker-compose.override.yaml  # [可选] 自定义覆盖配置（升级与回滚自动保留）
├── config/                       # Traefik 与 Vector 配置
├── backups/                      # 升级、迁移与配置变更快照
└── data/                         # postgres / redis / clickhouse / minio / vector-1 / vector-2
```

---

## 3. 离线环境部署

1. **在联网环境下拉取并打包镜像**：

```bash
cd self-hosted/scripts
./pull-images.sh --v2 --save   # 生成 swanlab_images.tar
```

2. **传输到目标机器**：上传 `self-hosted` 仓库与 `swanlab_images.tar` 到目标机器
3. **加载镜像并安装**： 确保目标机器已安装 Docker，并加载离线镜像:

```bash
docker load -i swanlab_images.tar
cd self-hosted/docker-v2
./install.sh
```

---

## 4. 环境变量配置

### 4.1 常用环境变量

一般位于运行目录下的 `.env` 文件中，修改后在运行目录下执行 `docker compose up -d` 生效：

| 变量名               | 默认值   | 说明                                                            |
| :------------------- | :------- | :-------------------------------------------------------------- |
| `SWANLAB_VERSION`    | `3.6.0`  | 业务镜像版本号                                                  |
| `EXPOSE_PORT`        | `8000`   | 网关暴露端口                                                    |
| `DATA_PATH`          | `./data` | 数据目录路径                                                    |
| `PUBLIC_HOST`        | 空       | 对外访问域名（如 `https://swanlab.example.com`）                |
| `SERVER_REPLICAS` 等 | <number> | SwanLab 业务服务副本数                                          |
| `DOCKER_SOCKET_PATH` | 自动探测 | Docker Socket 路径（自动适配标准 Docker / Rootless / OrbStack） |

### 4.2 外接数据库服务（PostgreSQL / Redis / ClickHouse / S3）

SwanLab 依赖的基础设施服务支持本机容器或外接实例的任意组合：

- **安装时配置**：运行 `./install.sh` 按交互提示逐项配置。
- **安装后切换**：: 在 `.env` 环境变量中没治好

```bash
./configure.sh ./swanlab --status   # 查看当前部署形态
./configure.sh ./swanlab            # 交互式切换（自动备份 .env 并按需重建受影响容器）
```

> 📌 **注意**：`configure.sh` 仅切换连接配置，**不自动迁移数据**。切往外接前请预先准备外部库表与 S3 存储桶

---

## 5. 日常运维与扩缩容

- **状态巡检**：`./check.sh ./swanlab`（退出码 `0`=正常，`1`=有故障，`2`=目录不存在）
- **查看日志**：`cd ./swanlab && docker compose logs -f <service>`
- **业务副本扩缩容**：修改 `.env` 中的 `*_REPLICAS` 后执行 `docker compose up -d`

---

## 6. 升级与回滚

升级会短暂中断服务，请在维护窗口执行，并提前通知使用中的用户。

```bash
# 1. 升级前只读体检
./upgrade.sh ./swanlab --check

# 2. 执行升级（快照配置、排空 Vector 缓冲、执行数据库迁移）
./upgrade.sh ./swanlab
./upgrade.sh ./swanlab -o              # 离线模式
./upgrade.sh ./swanlab --version 3.6.0 # 指定目标版本

# 3. 异常回滚（恢复配置与镜像版本，不改动数据库）
./upgrade.sh ./swanlab --rollback ./swanlab/backups/pre-upgrade-<时间戳>/
```

> 回滚只恢复配置与镜像版本，不改动数据库。数据库结构保持前向兼容，回滚后的旧版本仍可正常运行。

---

## 7. 旧版 Docker 部署实例迁移

将旧版 `docker/`（`fluent-bit` 架构）平滑迁移至 `docker-v2`。

- **前提**：旧版容器实例运行状态健康；如需外接，请**先执行 `migrate.sh` 原地迁移，再执行 `configure.sh` 切换外接数据库配置**。
- **参数**：传入旧版实例安装生成的**运行目录**（一般是 `swanlab`，目录下包含 `.env`、`fluent-bit.conf`、`data/`），而非仓库中的 `docker/` 模板目录。

```bash
./migrate.sh <path_to_swanlab>                            # 原地迁移（数据库相关文件原地保留）
./migrate.sh <path_to_swanlab>  --to <new_swanlab_path>   # 跨目录迁移（自动拷贝数据，旧目录保留）
```

确认稳定运行后，可清理旧版遗留数据卷：

```bash
docker volume rm swanlab-house fluent-bit
```
# SwanLab Self-Hosted（docker-v2）

Docker Compose 版私有化部署方案（v3.4.0）。

```text
                        ┌────────────────────────────────────────────┐
 :8000 ──► gateway(traefik 3.6)  ── labels 路由，docker provider 感知副本
                        │  /api        /api/auth  /api/house   /
                        ▼      ▼           ▼          ▼         ▼
                  swanlab-server  swanlab-auth  swanlab-house  swanlab-next ──► swanlab-cloud
                    ×2 副本         ×2 副本       ×2 副本        ×2 副本        ×1 副本
                        │                            │ HTTP log source
                        ▼                            ▼
                 postgres / redis              vector（固定单实例）
                 clickhouse / minio              │  disk buffer（DATA_PATH/vector）
                 （独立 profile，可外接）          ▼
                                              clickhouse
```

与旧版 [`docker/`](../docker/README.md)（维护模式）的差异：vector 指标管道替代 fluent-bit 链路、标准 traefik 网关替代定制版、业务服务多副本（单机故障自动摘除）、数据层四件套可逐项外接。

## 环境要求

| 项 | 要求 | 说明 |
|---|---|---|
| Docker Compose | **≥ v2.24** | `depends_on.required` 长语法依赖此版本，所有脚本启动前校验 |
| 磁盘剩余 | **≥ 40Gi**（数据目录所在分区） | vector 磁盘缓冲（3 个 sink 各 10GiB）且与数据服务同盘，预留 40GiB 运行余量 |
| 端口 | 默认 `8000` 可改 | gateway web 入口 |

## 快速开始

```bash
cd docker-v2
./install.sh                 # 交互式安装到 ./swanlab
./install.sh -s              # 免交互：本机四件套 + 默认副本数（冒烟/测试）
./install.sh /opt/swanlab -d /data -p 80
./install.sh /opt/swanlab -o # 离线/内网：跳过 pull，校验本地镜像齐备
```

离线镜像打包：`scripts/pull-images.sh --v2 --save` → 传输 → 目标机 `docker load` → `install.sh -o`。

> ⚠️ **本目录是模板目录，不可执行 `docker compose up -d`**：`.env.example` 的凭据字段为空，请通过 `install.sh` / `migrate.sh` 生成运行目录（默认 `swanlab/`）后操作。

> ⚠️ **禁止 `--scale vector`**：vector 磁盘缓冲依赖单实例独占数据目录（`DATA_PATH/vector`），多副本共享挂载目录会导致数据异常。`check.sh` 会对此进行检查。

## 部署形态与外接

数据层四件套（postgres / redis / clickhouse / minio）由 `.env` 的 `COMPOSE_PROFILES` 控制本机部署或外接，逐项独立：

```text
COMPOSE_PROFILES=postgres,redis,clickhouse,minio   # 全本机（默认）
COMPOSE_PROFILES=redis,clickhouse,minio            # 外接 pg（需填 DATABASE_URL）
SS_STORAGE_TYPE=local|remote                       # S3 本机 MinIO / 外部对象存储
```

**安装时**选择外接：`install.sh` 交互中逐项确认。
**安装后**切换外接：

```bash
./configure.sh ./swanlab           # 交互式逐项切换（变更前自动备份 .env）
./configure.sh ./swanlab --status  # 只读查看当前形态
```

切换只改连接指向，不迁移数据（外接→本机 = 空库/空桶起步，本机→外接需预先准备实例与桶）。

**存量 docker 版用户**：迁移与外接是两步操作——先 `migrate.sh`（固定全 local，数据完整），再 `configure.sh` 切外接。见下文「存量迁移」。

## 配置说明（运行目录 `swanlab/.env`）

| 变量 | 默认 | 说明 |
|---|---|---|
| `SWANLAB_VERSION` | `3.4.0` | 业务镜像 tag（自动加 `v` 前缀）；compose 不设回退默认，丢失会在防呆校验拦截 |
| `EXPOSE_PORT` | `8000` | gateway 暴露端口 |
| `DATA_PATH` | `./data` | 数据目录（相对运行目录或绝对路径） |
| `DOCKER_SOCKET_PATH` | 自动探测 | rootless / OrbStack 与默认不同，install 自动写入 |
| `PUBLIC_HOST` | 空 | 对外域名（影响 next/auth 的链接生成；空 = 不启用） |
| `SERVER_REPLICAS` 等 | `2/2/2/2/1` | server/auth/house/next/cloud 副本数，改后 `up -d` 生效 |

修改后 `docker compose up -d` 生效；外接变量语义见 `.env.example` 注释。

## 日常运维

```bash
./check.sh ./swanlab    # 只读巡检：环境/目录/防呆/渲染/混栈/vector 单实例/容器健康/磁盘
```

- 输出 `[PASS]/[WARN]/[FAIL]` 汇总，退出码 `0`=无 FAIL、`1`=有 FAIL、`2`=目录不存在——可接入 CI / 监控。
- 日志与容器：`docker compose ps`、`docker compose logs -f <service>`。
- 扩缩容：编辑 `.env` 副本数后 `up -d`（gateway 自动感知新副本并负载均衡）。**vector 除外**——固定单实例，原因见上。

## 升级与回滚

```bash
./upgrade.sh ./swanlab --check    # 只读体检：版本/磁盘/校验/渲染/容器状态
./upgrade.sh ./swanlab            # 快照 → pg_dump → 铺新模板 → pull → up -d
./upgrade.sh ./swanlab --version 3.5.0
./upgrade.sh ./swanlab -o         # 离线
./upgrade.sh ./swanlab --rollback ./swanlab/backups/pre-upgrade-<ts>/
```

- 数据库 schema 由一次性服务 `server-migrate`（`prisma migrate deploy` + `node migrate.js`）在 server 副本启动前串行执行；迁移失败则中断启动过程。
- 每次升级前自动 `pg_dump` 快照到 `backups/pre-upgrade-<ts>/`；`--rollback` 恢复配置（数据库快照按需手动导入，命令见其输出）。

## 存量迁移（旧版 docker → docker-v2）

旧版（fluent-bit 链路）用户平滑迁移入口。旧版为全内置形态。迁移完成后可通过 `configure.sh` 配置外接实例。

```bash
./migrate.sh /opt/swanlab                       # 默认档：排空后原地升级（推荐）
./migrate.sh /opt/swanlab --to /data2/swanlab   # 排空后 rsync 数据到新目录，旧目录原样保留
./migrate.sh /opt/swanlab -o -y                 # 离线 + 免确认
```

数据完整性：

- pg/redis/CH/minio 数据目录原地保留，凭据沿用旧值；
- schema 由 `server-migrate` 一次性服务在 server 副本启动前串行升级；
- 配置快照仅备份文本（compose / `.env` / metadata）：迁移不修改数据卷，支持回滚；
- 排空判定：断开摄入后轮询 ClickHouse 行数稳定；
- 回滚：恢复旧 compose/`.env` 后 `up -d` 完成回退（收尾输出提供对应命令）；
- 稳定运行后可清理旧卷：`docker volume rm swanlab-house fluent-bit`。

## 运行目录结构

```text
swanlab/
├── .env                  # 全部配置（权限 600）
├── docker-compose.yaml   # 自本模板拷贝
├── config/               # traefik（静态+动态）/ vector 配置
├── backups/              # pre-migrate-<ts>/ 与 pre-upgrade-<ts>/、pre-configure-<ts>/ 快照
└── data/                 # postgres/ redis/ clickhouse/ minio/ vector/
```

## 旧 Docker Compose（< v2.24）环境

本方案不提供旧 compose 兼容路径，请升级 compose 插件（如 `apt install docker-compose-plugin`，或从 GitHub 下载对应版本二进制）。

原因：`depends_on` 的 `required` 语法参与 compose 解析与校验，旧版本无法解析此语法。

## FAQ

- **OrbStack / rootless Docker 提示 socket 不存在？** `install.sh` 会自动探测并写入 `DOCKER_SOCKET_PATH`（如 `~/.orbstack/run/docker.sock`）；修改环境后 `check.sh` 会校验。
- **磁盘 40Gi 阈值的依据？** vector 3 个 sink 各 10GiB 磁盘缓冲，与数据服务同盘，预留 40GiB 运行余量。
- **双副本内存吃紧？** `.env` 各 `*_REPLICAS` 降为 1，`up -d` 生效。
- **如何切换镜像源 / 命名空间？** 镜像地址定义在 `docker-compose.yaml` 的 image 行。换平台或命名空间可编辑 compose 里的 image 行，离线打包机同步修改 `scripts/pull-images.sh` 清单（可先 `./pull-images.sh --v2 --list` 核对）。

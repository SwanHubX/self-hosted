# SwanLab Self-Hosted（docker-v2）

Docker Compose 版私有化部署方案（v3.4.0）。

```text
 :8000 ──► gateway(traefik 3.6)  ── labels 路由，docker provider 感知副本
                        │  /api        /api/auth  /api/house   /
                        ▼      ▼           ▼          ▼         ▼
                  swanlab-server  swanlab-auth  swanlab-house  swanlab-next ──► swanlab-cloud
                    ×2 副本         ×2 副本       ×2 副本        ×2 副本        ×1 副本
                        │                            │ HTTP 指标
                        ▼                            ▼
                 postgres / redis              gateway:8080/vector
                 clickhouse / minio              │  内部负载均衡 + /ping 探活
                 （独立 profile，可外接）         ▼
                                        vector-1          vector-2
                                        data/vector/      data/vector-2/
                                               │ 独立 disk buffer
                                               ▼
                                              clickhouse
```

与旧版 [`docker/`](../docker/README.md) 的差异：Vector 双实例指标管道、Traefik 内部负载均衡、业务服务多副本，以及可逐项外接的数据服务。

## 环境要求

| 项 | 要求 | 说明 |
|---|---|---|
| Docker Compose | **≥ v2.24** | `depends_on.required` 长语法依赖此版本，所有脚本启动前校验 |
| 磁盘剩余 | **建议 ≥ 70GiB**（数据目录所在分区） | 两实例共六个 10GiB 缓冲，加至少 10GiB 运行余量；ClickHouse 等数据增长需另行规划 |
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

> ⚠️ **禁止对 `vector-1` / `vector-2` 使用 `--scale`**：每个进程独占自己的 WAL 目录，共享目录会产生排他锁冲突。实例 1 使用 `DATA_PATH/vector`，实例 2 使用 `DATA_PATH/vector-2`。旧 `vector/` 目录继续有效，请勿清空。

House 经 `gateway:8080/vector` 发送指标，网关移除 `/vector` 前缀后转发到 Vector 根路径。路由仅对 internal 入口开放，无用户鉴权中间件。Docker healthcheck 和 Traefik 主动探活均使用 `:8686/ping`；主动探活间隔 5 秒、超时 2 秒。`/ping` 表示 HTTP 服务存活，不能证明下游写入或缓冲容量正常，管理 API 保持关闭。

冷启动要求网关与两个 Vector 实例都健康。运行中一个实例故障后，流量在检测窗口后转到另一实例；在途请求仍可能失败。两个 WAL 互不复制，故障实例的积压需要该实例恢复后重放。House 的异步发送与有限重试保持原行为，本方案不提供任意故障下的端到端零丢失保证。

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
./check.sh ./swanlab    # 只读巡检：环境/目录/防呆/渲染/项目一致性/vector 双实例/容器健康/磁盘
```

- 输出 `[PASS]/[WARN]/[FAIL]` 汇总，退出码 `0`=无 FAIL、`1`=有 FAIL、`2`=目录不存在——可接入 CI / 监控。
- 日志与容器：`docker compose ps`、`docker compose logs -f <service>`。
- 扩缩容：编辑 `.env` 业务副本数后 `up -d`，网关自动发现副本。Vector 固定双实例，各自独占目录。

## 升级与回滚

```bash
./upgrade.sh ./swanlab --check    # 只读体检：版本/磁盘/校验/渲染/容器状态
./upgrade.sh ./swanlab --ingestion-paused
./upgrade.sh ./swanlab --version 3.5.0 --ingestion-paused
./upgrade.sh ./swanlab -o --ingestion-paused         # 离线
./upgrade.sh ./swanlab --rollback ./swanlab/backups/pre-upgrade-<ts>/ --ingestion-paused
```

- 数据库 schema 由一次性服务 `server-migrate`（`prisma migrate deploy` + `node migrate.js`）在 server 副本启动前串行执行；迁移失败则中断启动过程。
- 每次升级前自动 `pg_dump` 快照到 `backups/pre-upgrade-<ts>/`；`--rollback` 恢复配置（数据库快照按需手动导入，命令见其输出）。
- 升级或回滚前必须在维护窗口暂停外部指标上报，并完成已接收请求的对账，再提供 `--ingestion-paused`。`--yes` 只跳过交互确认，不能替代暂停声明。只读 `--check` 无需声明。
- 升级按当前配置暂停 House、停止旧 Vector writer，再更换模板。先启动网关与两个 Vector，等待健康并连续两次确认旧缓冲已排空，再恢复业务服务；检查失败则保持 House 暂停。实例 1 原地继承 `vector/`，不重命名 WAL；旧停止容器保留，升级不会自动删除 orphan 容器或数据。
- 回滚先检查当前两个实例的 HTTP 服务、ClickHouse 可达性和缓冲用量。每隔 35 秒采样，连续两次零积压后才停止 Vector 并恢复配置；默认最多等待约 180 秒。实例不可用、指标无法判断或积压不消退时中止，保留当前配置与全部 WAL，House 保持暂停。恢复下游后重试；需要恢复原部署时按当前配置启动 House。

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
└── data/                 # postgres/ redis/ clickhouse/ minio/ vector/ vector-2/
```

## 旧 Docker Compose（< v2.24）环境

本方案不提供旧 compose 兼容路径，请升级 compose 插件（如 `apt install docker-compose-plugin`，或从 GitHub 下载对应版本二进制）。

原因：`depends_on` 的 `required` 语法参与 compose 解析与校验，旧版本无法解析此语法。

## FAQ

- **OrbStack / rootless Docker 提示 socket 不存在？** `install.sh` 会自动探测并写入 `DOCKER_SOCKET_PATH`（如 `~/.orbstack/run/docker.sock`）；修改环境后 `check.sh` 会校验。
- **磁盘 70GiB 建议的依据？** 两个 Vector 的六个 sink 最多占用 60GiB 缓冲，另预留至少 10GiB 运行空间；数据库体积需额外考虑。脚本低于建议值时提示，巡检低于 10GiB 时失败。
- **双副本内存吃紧？** `.env` 各 `*_REPLICAS` 降为 1，`up -d` 生效。
- **如何切换镜像源 / 命名空间？** 镜像地址定义在 `docker-compose.yaml` 的 image 行。换平台或命名空间可编辑 compose 里的 image 行，离线打包机同步修改 `scripts/pull-images.sh` 清单（可先 `./pull-images.sh --v2 --list` 核对）。

## 验证双实例

在具备本地测试部署的 Linux / WSL 环境执行 `bash docker-v2/tests/vector-dual-instance.sh`。脚本使用已有 ClickHouse 的表结构，以唯一实验标识写入 scalar、media、log 验证数据；不会创建或迁移数据库结构。

验证使用独立 Compose 项目、网络、数据目录，不发布宿主端口。覆盖路径转发、流量分摊、停止摘除、无响应进程摘除、WAL 崩溃恢复、旧 writer 切换和回滚前缓冲检查。通过后停止测试容器；失败时保留测试容器和缓冲指标供排查。数据及日志保留在 `.work/vector-dual/`，不自动删除。吞吐提升需要按实际负载另外压测。

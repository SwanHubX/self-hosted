<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="readme_files/swanlab-logo-single-dark.svg">
  <source media="(prefers-color-scheme: light)" srcset="readme_files/swanlab-logo-single.svg">
  <img alt="SwanLab" src="readme_files/swanlab-logo-single.svg" width="70" height="70">
</picture>

<h1>SwanLab Self-Hosted</h1>

SwanLab 私有化部署方案，支持 Docker Compose、Kubernetes 及纯离线环境部署

<a href="https://swanlab.cn">🔥 SwanLab Online</a> · <a href="https://docs.swanlab.cn/self_host/kubernetes/deploy.html">📃 部署文档</a> · <a href="https://github.com/SwanHubX/self-hosted/issues">反馈问题</a> · <a href="https://hub.docker.com/search?q=swanlab">Docker Hub</a>

中文 / [English](./README_EN.md)

</div>

## 📖 目录

- [🚄 快速部署](#-快速部署)
- [🚀 版本升级](#-版本升级)
- [🔌 SDK 版本兼容性](#-sdk-版本兼容性)
- [🌟 版本更新日志](#-版本更新日志)
- [📚 更多资源](#-更多资源)

<br>

## 🚄 快速部署

### Docker Compose 单实例部署

适用于单机中小规模团队快速部署。详细配置说明请参考 [docker/README.md](./docker/README.md) 或 [Docker 部署文档](https://docs.swanlab.cn/self_host/docker/deploy.html)。

```bash
git clone https://github.com/swanhubx/self-hosted.git
cd self-hosted/docker
```

- **中国大陆镜像源（默认）：**
  ```bash
  ./install.sh
  ```
- **Docker Hub 镜像源（海外）：**
  ```bash
  ./install-dockerhub.sh
  ```

### Kubernetes 部署

适用于生产级高可用集群部署，请参考 [Kubernetes 部署文档](https://docs.swanlab.cn/self_host/kubernetes/deploy.html)。

<br>

## 🚀 版本升级

拉取最新仓库代码后，进入 `docker` 目录执行升级脚本即可无缝更新并重启服务：

```bash
git pull
cd docker
./upgrade.sh
```

> 💡 **镜像源迁移提示（`< v3.3.0` 升级必读）**：自 `v3.3.0` 起，基础设施与应用镜像统一托管至 `repo.swanlab.cn`。首次从旧版本升级时，脚本会自动改写 `docker-compose.yaml` 中的镜像地址并重新拉取镜像；升级完成后可执行 `docker image prune` 清理旧镜像。

<br>

## 🔌 SDK 版本兼容性

私有化部署服务端版本与 Python SDK（[`swanlab`](https://github.com/SwanHubX/SwanLab)）的兼容矩阵如下：

| 私有化版本 | 兼容的 Python SDK 版本         |
| ---------- | ------------------------------ |
| v3.6.0     | v0.7.6 ~ v0.10.5               |
| v3.5.0     | v0.7.6 ~ v0.10.4               |
| v3.4.0     | v0.7.6 ~ v0.10.4               |
| v3.3.0     | v0.7.6 ~ v0.10.4               |
| v3.2.0     | v0.7.6 ~ v0.9.x                |
| v3.1.1     | v0.7.6 ~ v0.9.x                |
| v3.1.0     | v0.7.6 ~ v0.9.x                |
| v3.0.0     | v0.7.6 ~ v0.9.x                |
| v2.8.1     | v0.7.6 ~ v0.8.4                |
| v2.8.0     | v0.7.6 ~ v0.8.4                |
| v2.7.4     | v0.7.4 ~ v0.7.20               |
| v2.7.3     | v0.7.4 ~ v0.7.20               |
| v2.7.1     | v0.7.4 ~ v0.7.20               |
| v2.7.0     | v0.7.4 ~ v0.7.20               |
| v2.6.3     | v0.7.4 ~ v0.7.20               |
| v2.6.2     | v0.7.4 ~ v0.7.20               |
| v2.5.0     | v0.6.0 ~ v0.7.3                |
| v2.4       | v0.6.0 ~ v0.7.3                |
| v2.3       | v0.6.0 ~ v0.7.3                |
| v2.2       | v0.6.0 ~ v0.7.3 (不含分组功能) |
| v2.1       | v0.6.0 ~ v0.7.3 (不含分组功能) |
| v2.0       | v0.6.0 ~ v0.7.3 (不含分组功能) |
| v1.3       | v0.6.0 ~ v0.7.3 (不含分组功能) |
| v1.2       | v0.6.0 ~ v0.6.4                |
| v1.1       | v0.6.0 ~ v0.6.4                |

<br>

## 🌟 版本更新日志

**v3.6.0 (2026.11.11)**

- 📊 **参数分布直方图**：新增 `swanlab.Histogram`，支持记录并可视化模型权重、梯度等张量的数值分布
- ⚙️ **分区配置与图表排序**：支持自定义看板分区设置及图表排列顺序
- 🗂️ **树状指标目录**：支持按层级树状结构浏览嵌套指标
- 🐞 **性能优化**：引入 WebAssembly (WASM) 优化大规模图表交互性能

**v3.5.0 (2026.10.13)**

- 📊 **实验聚焦高亮**：悬停图例或实验列表项时，自动高亮对应的图表曲线
- 🦜 **实验置顶筛选**：优化侧边栏实验置顶体验，支持更灵活的筛选条件
- 📉 **分组聚合配置**：新增实验分组聚合设置
- 🐞 **问题修复**：修复折线图包含 `±1e308` 极值数据点时的渲染异常

**v3.4.0 (2026.09.17)**

- 📊 **快速创建图表**：在看板视图中支持快捷新建与配置图表
- 🔗 **视图独立链接**：每个看板视图支持生成独立 URL，便于团队内直接分享
- 👥 **跨协作者实验对比**：「添加对比实验」支持选择协作者项目中的实验

**v3.3.0 (2026.09.01)**

> ⚠️ **注意**：本版本起统一使用 `repo.swanlab.cn` 管理基础设施与应用镜像。首次升级会自动更新 `docker-compose.yaml` 中的镜像引用并重新拉取镜像，旧镜像可通过 `docker image prune` 清理。

- 📊 **指标表达式**：支持对多个指标进行数学运算与组合，并直接可视化计算结果
- ⚙️ **自定义图表行为**：新增 [`swanlab.define_metric()`](https://docs.swanlab.cn/api/py-define_metric.html) API，支持在记录指标前定义自定义 X 轴与图表分组
- 🐞 **权限修复**：修复仅具备项目写入权限的用户在初始化已存在项目时报错 `403` 的问题（改为先查询项目，仅在不存在时创建）

<details><summary>完整更新日志</summary>

**v3.2.0 (2026.08.24)**

- 🗑 **回收站**：被删除的项目和实验将移入回收站，支持恢复或彻底清除
- 🔬 **跨项目实验对比**：支持引入其他项目中的实验进行同图对比
- 🐞 **问题修复**：修复系统图表无法隐藏空图表的问题
- 🐞 **问题修复**：修复对比视图中修改实验颜色后，单实验视图颜色未同步更新的问题

**v3.1.1 (2026.08.04)**

- 📉 支持跨项目导入对比实验
- 📈 置顶实验数量上限提升至 20，单张折线图可同时展示的实验/分组上限提升至 25

**v3.1.0 (2026.07.29)**

- 📊 支持 `NaN` 数据点展示，新增分组聚合上限提示
- 🐞 修复多视图模式下空图表无法隐藏的问题

**v3.0.0 (2026.07.21)**

- 📊 全新多视图交互看板上线（需搭配 `swanlab >= 0.9.0` SDK 使用）

**v2.8.1 (2026.06.15)**

- 新特性：支持 HTML 图表
- 优化：搜索实验时同步过滤图表对比视图
- 优化：提升对 SDK v0.8.0 的兼容性
- 部署：支持 [Prometheus 监控方案](https://docs.swanlab.cn/self_host/kubernetes/monitor-logging.html)

**v2.8.0 (2026.05.29)**

- 修复部分已知问题

**v2.7.4 (2026.04.27)**

- 新增项目收藏功能，修复部分已知问题

**v2.7.3 (2026.04.08)**

- 支持实验收藏、基线实验（Baseline）与文件保存功能

**v2.7.1 (2026.03.06)**

- 修复部分已知问题

**v2.7.0 (2026.01.29)**

- 优化大规模实验及高并发指标场景下的前端渲染性能

**v2.6.3 (2026.01.19)**

- 新增心跳探测机制，优化图表渲染性能

**v2.6.2 (2025.12.19)**

- 修复部分已知问题，同步云端功能更新，支持 `swanlab` SDK v0.7.4

**v2.5.1 (2025.12.10)**

- 支持将内置 MinIO 替换为任意兼容 S3 协议的外部对象存储服务

**v2.5.0 (2025.12.05)**

- 商业版新增企业级管理看板

**v2.4 (2025.11.24)**

- 收敛对象存储端口，不再需要对外暴露 MinIO `9000` 端口
- 折线图数据点新增时间戳信息

**v2.3 (2025.11.17)**

- 支持实验分组功能

**v2.2 (2025.11.06)**

- 支持折线图自定义 X 轴

**v2.1 (2025.09.30)**

- 上线全新图表视图 UI，同步公有云版最新特性

**v2.0 (2025.09.01)**

- 重构权限管理系统

**v1.3 (2025.07.08)**

- 同步公有云版最新功能

**v1.2 (2025.05.30)**

- Feature: 支持折线图创建、编辑与多数据源配置（单图展示多指标）
- Feature: 支持为实验添加 Tag 标签
- Feature: 支持折线图对数坐标轴（Log Scale）、分组拖拽排序及 `swanlab.OpenApi` 开放接口
- Feature: 新增「默认空间」与「默认可见性」配置
- Optimize: 大幅优化高频指标上报吞吐性能，修复极端高并发下的数据丢失问题
- BugFix: 修复实验状态无法自动结束的问题

**v1.1 (2025.04.27)**

- 镜像更新至 v1.1 版本，新用户可直接运行 `install.sh` 部署，v1.0 用户可运行 `docker/upgrade.sh` 原地升级。

</details>

<br>

## 📚 更多资源

- [纯离线环境部署指南](https://docs.swanlab.cn/self_host/docker/offline-deployment.html)
- [阿里云计算巢部署](https://docs.swanlab.cn/self_host/alibabacloud-computenest.html)
- [腾讯云云应用部署](https://docs.swanlab.cn/self_host/tencentcloud-app.html)
- [常见问题 (FAQ)](https://docs.swanlab.cn/self_host/kubernetes/faq.html)
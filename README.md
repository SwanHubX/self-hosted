<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="readme_files/swanlab-logo-single-dark.svg">
  <source media="(prefers-color-scheme: light)" srcset="readme_files/swanlab-logo-single.svg">
  <img alt="SwanLab" src="readme_files/swanlab-logo-single.svg" width="70" height="70">
</picture>

<h1>Self-Hosted SwanLab</h1>

SwanLab 私有化部署服务，支持Docker、云应用、纯离线环境部署方式

<a href="https://swanlab.cn">🔥SwanLab 在线版</a> · <a href="https://docs.swanlab.cn/guide_cloud/self_host/docker-deploy.html">📃 文档</a> · <a href="https://github.com/SwanHubX/self-hosted/issues">报告问题</a> · <a href="https://hub.docker.com/search?q=swanlab">DockerHub</a>

中文 / [English](./README_EN.md)

</div>

## 📖 目录

- [🌟 最近更新](#-最近更新)
- [🚄 快速部署](#-快速部署)
- [🔌 SDK版本兼容性](#-sdk版本兼容性)
- [🚀 升级版本](#-升级版本)
- [📚 资源](#-资源)

<br>

## 🌟 最近更新

> 🤔**如何从旧版本升级**：同步项目仓库后，执行 `cd docker && ./upgrade.sh` 可升级至 `v2.7.1` 版本

**v2.7.1 (2026.03.06)**
- 修复部分已知问题

**v2.7.0 (2026.01.29)**
- 优化大规模实验以及大批量指标场景下的渲染性能

**v2.6.3 (2026.01.19)**
- 添加心跳探测，优化图表的渲染性能

**v2.6.2 (2025.12.19)**
- 修复部分已知问题，同步云服务更新，支持 swanlab sdk v0.7.4

**v2.5.1 (2025.12.10)**
- 允许将 minio 替换为其他兼容 S3 协议的对象存储服务

**v2.5.0 (2025.12.5)**
- 为商业版开发了更全面的管理看板

**v2.4 (2025.11.24)**
- 不再需要开放 minio 的 9000 端口
- 折线图的数据点携带时间戳信息

**v2.3 (2025.11.17)**
- 支持实验分组

**v2.2 (2025.11.6)**
- 支持折线图 x 轴自定义

**v2.1 (2025.9.30)**
- 上线图表视图全新UI
- 同步到最新的公有云版功能

**v2.0 (2025.9.1)**
- 更新权限系统

**v1.3 (2025.7.8)**
- 同步到最新的公有云版功能

**v1.2 (2025.5.30)**
- Feature: 上线折线图创建和编辑功能，配置图表功能增加数据源选择功能，支持单张图表显示不同的指标
- Feature: 支持在实验添加Tag标签
- Feature: 支持折线图Log Scale；支持分组拖拽；增加swanlab.OpenApi开放接口
- Feature: 新增「默认空间」和「默认可见性」配置，用于指定项目默认创建在对应的组织下
- Optimize: 优化大量指标上传导致部分数据丢失的问题
- Optimize: 大幅优化指标上传的性能问题
- BugFix: 修复实验无法自动关闭的问题

**v1.1 (2025.4.27)**
swanlab相关镜像已更新至v1.1版本，初次使用的用户直接运行`install.sh` 即可享用v1.1版本，原v1版本用户可直接运行`docker/upgrade.sh`对`docker-compose.yaml`进行升级重启。

<br>

## 🚄 快速部署

### 1. 手动部署

克隆仓库：

```bash
git clone https://github.com/swanhubx/self-hosted.git
cd self-hosted/docker
```

**方式一：** 使用 [DockerHub](https://hub.docker.com/search?q=swanlab) 镜像源部署：

```bash
./install-dockerhub.sh
```

**方式二：** 中国地区快速部署：

```bash
./install.sh
```

### 2. 一键脚本部署

**方式一：** 使用 [DockerHub](https://hub.docker.com/search?q=swanlab) 镜像源部署：

```bash
curl -sO https://raw.githubusercontent.com/swanhubx/self-hosted/main/docker/install-dockerhub.sh && bash install.sh
```

**方式二：** 中国地区快速部署：

```bash
curl -sO https://raw.githubusercontent.com/swanhubx/self-hosted/main/docker/install.sh && bash install.sh
```

详细内容参考：[docker/README.md](./docker/README.md)

教程文档：[使用Docker进行部署](https://docs.swanlab.cn/guide_cloud/self_host/docker-deploy.html)


<br>

## 🚀 升级版本

克隆仓库同步最新的代码后，进入 `docker` 目录执行 `./upgrade.sh` 实现升级重启到最新版本。

```bash
cd docker
bash ./upgrade.sh
```

<br>

## 🔌 SDK版本兼容性

私有化部署版本与SDK（即[swanlab](https://github.com/SwanHubX/SwanLab) python库）的兼容性如下表：

| 私有化版本   | 支持的 SDK 版本 |
|-----------|------------------|
| v2.7.1  | v0.7.4 ~ latest    |
| v2.7.0  | v0.7.4 ~ latest    |
| v2.6.3  | v0.7.4 ~ latest    |
| v2.6.2  | v0.7.4 ~ latest    |
| v2.5.0  | v0.6.0 ~ v0.7.3    |
| v2.4    | v0.6.0 ~ v0.7.3    |
| v2.3    | v0.6.0 ~ v0.7.3    |
| v2.2    | v0.6.0 ~ v0.7.3 (除分组功能)    |
| v2.1    | v0.6.0 ~ v0.7.3 (除分组功能)    |
| v2.0    | v0.6.0 ~ v0.7.3 (除分组功能)    |
| v1.3    | v0.6.0 ~ v0.7.3 (除分组功能)    |
| v1.2    | v0.6.0 ~ v0.6.4    |
| v1.1    | v0.6.0 ~ v0.6.4    |


[dockerhub-shield]: https://img.shields.io/docker/v/swanlab/swanlab-next?color=369eff&label=docker&labelColor=black&logoColor=white&style=flat-square
[dockerhub-link]: https://hub.docker.com/r/swanlab/swanlab-next/tags

<br>

## 📚 资源
- [纯离线环境部署](https://docs.swanlab.cn/guide_cloud/self_host/offline-deployment.html)
- [腾讯云云应用部署](https://docs.swanlab.cn/guide_cloud/self_host/tencentcloud-app.html)
- [阿里云计算巢部署](https://docs.swanlab.cn/guide_cloud/self_host/alibabacloud-computenest.html)
- [常见问题](https://docs.swanlab.cn/guide_cloud/self_host/faq.html)
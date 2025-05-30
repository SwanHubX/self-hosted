<h1 align="center" style="border-bottom: none">
    <a href="https://swanlab.cn" target="_blank">
      <img alt="SwanLab" src="./assets/swanlab.svg" width="150" height="150">
    </a>
    <br>Self-Hosted SwanLab
</h1>

<div align="center">

[![][dockerhub-shield]][dockerhub-link]

</div>

[English](./README_EN.md)

## 版本更新

### v1.2 (2025.5.30)
- Feature: 上线折线图创建和编辑功能，配置图表功能增加数据源选择功能，支持单张图表显示不同的指标
- Feature: 支持在实验添加Tag标签
- Feature: 支持折线图Log Scale；支持分组拖拽；增加swanlab.OpenApi开放接口
- Feature: 新增「默认空间」和「默认可见性」配置，用于指定项目默认创建在对应的组织下
- Optimize: 优化大量指标上传导致部分数据丢失的问题
- Optimize: 大幅优化指标上传的性能问题
- BugFix: 修复实验无法自动关闭的问题

> 🤔**如何从旧版本升级**：同步项目仓库后，执行 `cd docker && ./upgrade.sh` 可升级至 `v1.2` 版本

### v1.1 (2025.4.27)
swanlab相关镜像已更新至v1.1版本，初次使用的用户直接运行`install.sh` 即可享用v1.1版本，原v1版本用户可直接运行`docker/upgrade.sh`对`docker-compose.yaml`进行升级重启。



## 快速部署

### 1. 手动部署

克隆仓库：

```bash
git clone https://github.com/swanhubx/self-hosted.git
cd self-hosted/docker
```

使用 [DockerHub](https://hub.docker.com/search?q=swanlab) 镜像源部署：

```bash
./install-dockerhub.sh
```

中国地区快速部署：

```bash
./install.sh
```

### 2. 一键脚本部署

使用 [DockerHub](https://hub.docker.com/search?q=swanlab) 镜像源部署：

```bash
curl -sO https://raw.githubusercontent.com/swanhubx/self-hosted/main/docker/install-dockerhub.sh && bash install.sh
```

中国地区快速部署：

```bash
curl -sO https://raw.githubusercontent.com/swanhubx/self-hosted/main/docker/install.sh && bash install.sh
```

详细内容参考：[docker/README.md](./docker/README.md)

## 更新版本

克隆仓库同步最新的代码后，进入 `docker` 目录执行 `./upgrade.sh` 实现升级重启到最新版本。

## 开始使用

请参考：[教程文档](https://docs.swanlab.cn/guide_cloud/self_host/docker-deploy.html)



[dockerhub-shield]: https://img.shields.io/docker/v/swanlab/swanlab-next?color=369eff&label=docker&labelColor=black&logoColor=white&style=flat-square
[dockerhub-link]: https://hub.docker.com/r/swanlab/swanlab-next/tags
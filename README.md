<h1 align="center" style="border-bottom: none">
    <a href="https://swanlab.cn" target="_blank">
      <img alt="SwanLab" src="./assets/swanlab.svg" width="150" height="150">
    </a>
    <br>Self-Hosted SwanLab
</h1>

[English](./README_EN.md)


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

## 开始使用

请参考：[教程文档](https://docs.swanlab.cn/guide_cloud/self_host/docker-deploy.html)
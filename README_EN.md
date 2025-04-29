<h1 align="center" style="border-bottom: none">
    <a href="https://swanlab.cn" target="_blank">
      <img alt="SwanLab" src="./assets/swanlab.svg" width="150" height="150">
    </a>
    <br>Self-Hosted SwanLab
</h1>

<div align="center">

[![][dockerhub-shield]][dockerhub-link]

</div>

[中文](./README.md)



## Quick Deployment

### 1. Manual Deployment

Clone the repository:

```bash
git clone https://github.com/swanhubx/self-hosted.git
cd self-hosted/docker
```

Deploy from [DockerHub](https://hub.docker.com/search?q=swanlab):

```bash
./install-dockerhub.sh
```

For faster deployment in China:

```bash
./install.sh
```

### 2. One-Click Script Deployment

Deploy from [DockerHub](https://hub.docker.com/search?q=swanlab):

```bash
curl -sO https://raw.githubusercontent.com/swanhubx/self-hosted/main/docker/install-dockerhub.sh && bash install.sh
```

For faster deployment in China:

```bash
curl -sO https://raw.githubusercontent.com/swanhubx/self-hosted/main/docker/install.sh && bash install.sh
```

For more details, refer to: [docker/README.md](./docker/README.md)

## Start Using

Refer to：[Document](https://docs.swanlab.cn/guide_cloud/self_host/docker-deploy.html)


[dockerhub-shield]: https://img.shields.io/docker/v/swanlab/swanlab-next?color=369eff&label=docker&labelColor=black&logoColor=white&style=flat-square
[dockerhub-link]: https://hub.docker.com/r/swanlab/swanlab-next/tags
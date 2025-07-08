<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="readme_files/swanlab-logo-single-dark.svg">
  <source media="(prefers-color-scheme: light)" srcset="readme_files/swanlab-logo-single.svg">
  <img alt="SwanLab" src="readme_files/swanlab-logo-single.svg" width="70" height="70">
</picture>

<h1>Self-Hosted SwanLab</h1>

Self-hosted SwanLab service supports Docker, cloud app, and fully offline deployment

<a href="https://swanlab.cn">🔥 Online SwanLab</a> · <a href="https://docs.swanlab.cn/guide_cloud/self_host/docker-deploy.html">📃 Documentation</a> · <a href="https://github.com/SwanHubX/self-hosted/issues">Report Issues</a>

[中文](./README.md) / English

</div>

## 📖 Table of Contents

- [🌟 Recent Updates](#-recent-updates)
- [🚄 Quick Deployment](#-quick-deployment)
- [🔌 SDK Version Compatibility](#-sdk-version-compatibility)
- [🚀 Upgrade Version](#-upgrade-version)
- [📚 Resources](#-resources)

<br>

## 🌟 Recent Updates

**v1.3 (2025.7.8)**
- Feature: Sync to the latest public cloud version

> 🤔 **How to upgrade from an old version**：After syncing the project repository, run `cd docker && ./upgrade.sh` to upgrade to version `v1.3`

**v1.2 (2025.5.30)**
- Feature: Line chart creation and editing features launched; configure charts with data source selection, supporting multiple metrics in the same chart
- Feature: Add Tag feature for experiments
- Feature: Support Log Scale for line graphs; support drag-and-drop grouping; add swanlab.OpenApi open interfaces
- Feature: Add 「Default Space」 and 「Default Visibility」 configuration, used to specify that projects are created under the corresponding organization by default
- Optimize: Fix data loss when uploading large amounts of metrics
- Optimize: Greatly improve the performance when uploading metrics
- BugFix: Fix the issue where some experiments cannot be automatically closed

> 🤔 **How to upgrade from an old version**：After syncing the project repository, run `cd docker && ./upgrade.sh` to upgrade to version `v1.2`

**v1.1 (2025.4.27)**
SwanLab images have been updated to v1.1. Users who are deploying for the first time can directly run `install.sh` to access v1.1, and users of the original v1 version can directly run `docker/upgrade.sh` to update and restart the `docker-compose.yaml`.

<br>

## 🚄 Quick Deployment

### 1. Manual Deployment

Clone the repository:

```bash
git clone https://github.com/swanhubx/self-hosted.git
cd self-hosted/docker
```

**Method 1:** Deploy using [DockerHub](https://hub.docker.com/search?q=swanlab) image source:

```bash
./install-dockerhub.sh
```

**Method 2:** Quick deployment for users in China:

```bash
./install.sh
```

### 2. One-click Script Deployment

**Method 1:** Deploy using [DockerHub](https://hub.docker.com/search?q=swanlab) image source:

```bash
curl -sO https://raw.githubusercontent.com/swanhubx/self-hosted/main/docker/install-dockerhub.sh && bash install.sh
```

**Method 2:** Quick deployment for users in China:

```bash
curl -sO https://raw.githubusercontent.com/swanhubx/self-hosted/main/docker/install.sh && bash install.sh
```

See also: [docker/README.md](./docker/README.md) for more details

Tutorial documentation: [Deploy with Docker](https://docs.swanlab.cn/guide_cloud/self_host/docker-deploy.html)

<br>

## 🚀 Upgrade Version

After cloning the repository and syncing the latest code, run `./upgrade.sh` under the `docker` directory to upgrade and restart to the latest version.

```bash
cd docker
bash ./upgrade.sh
```

<br>

## 🔌 SDK Version Compatibility

The compatibility of the self-hosted version with the SDK (i.e., [swanlab](https://github.com/SwanHubX/SwanLab) Python library) is shown in the following table:

| Self-hosted Version | Supported SDK Version |
|------------------|-----------------------|
| v1.3            | v0.6.0 ~ latest        |
| v1.2            | v0.6.0 ~ v0.6.4        |
| v1.1            | v0.6.0 ~ v0.6.4        |

[dockerhub-shield]: https://img.shields.io/docker/v/swanlab/swanlab-next?color=369eff&label=docker&labelColor=black&logoColor=white&style=flat-square
[dockerhub-link]: https://hub.docker.com/r/swanlab/swanlab-next/tags

<br>

## 📚 Resources
- [Offline deployment for pure offline environments](https://docs.swanlab.cn/guide_cloud/self_host/offline-deployment.html)
- [Deployment on Tencent Cloud App](https://docs.swanlab.cn/guide_cloud/self_host/tencentcloud-app.html)
- [FAQ](https://docs.swanlab.cn/guide_cloud/self_host/faq.html)
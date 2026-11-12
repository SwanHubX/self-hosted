<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="readme_files/swanlab-logo-single-dark.svg">
  <source media="(prefers-color-scheme: light)" srcset="readme_files/swanlab-logo-single.svg">
  <img alt="SwanLab" src="readme_files/swanlab-logo-single.svg" width="70" height="70">
</picture>

<h1>SwanLab Self-Hosted</h1>

Deploy SwanLab on your own infrastructure with Docker Compose, Kubernetes, or in air-gapped environments

<a href="https://swanlab.cn">🔥 SwanLab Online</a> · <a href="https://docs.swanlab.cn/en/self_host/kubernetes/deploy.html">📃 Documentation</a> · <a href="https://github.com/SwanHubX/self-hosted/issues">Report an Issue</a> · <a href="https://hub.docker.com/search?q=swanlab">Docker Hub</a>

[中文](./README.md) / English

</div>

## 📖 Table of Contents

- [🚄 Quick Start](#-quick-start)
- [🚀 Upgrading](#-upgrading)
- [🔌 SDK Compatibility](#-sdk-compatibility)
- [🌟 Release Notes](#-release-notes)
- [📚 Resources](#-resources)

<br>

## 🚄 Quick Start

### Docker Compose Single-Instance Deployment

Recommended for single-node or small-to-medium team deployments. See [docker/README_EN.md](./docker/README_EN.md) and the [Docker Deployment Guide](https://docs.swanlab.cn/en/self_host/docker/deploy.html) for configuration details.

```bash
git clone https://github.com/swanhubx/self-hosted.git
cd self-hosted/docker
```

- **Global (Docker Hub registry):**
  ```bash
  ./install-dockerhub.sh
  ```
- **China Mainland (Mirror registry):**
  ```bash
  ./install.sh
  ```

### Kubernetes

For production-grade, high-availability cluster deployments, refer to the [Kubernetes Deployment Guide](https://docs.swanlab.cn/en/self_host/kubernetes/deploy.html).

<br>

## 🚀 Upgrading

Pull the latest changes from the repository and run the upgrade script in the `docker` directory to perform an in-place upgrade:

```bash
git pull
cd docker
./upgrade.sh
```

> 💡 **Registry Migration Note (upgrading from `< v3.3.0`):** Starting with `v3.3.0`, all infrastructure and application images are hosted under `repo.swanlab.cn`. During your first upgrade from an earlier release, `upgrade.sh` will automatically update the image references in `docker-compose.yaml` and pull the new images. You can clean up legacy images afterward with `docker image prune`.

<br>

## 🔌 SDK Compatibility

The table below lists the compatible [`swanlab`](https://github.com/SwanHubX/SwanLab) Python SDK versions for each self-hosted release:

| Self-Hosted Version | Compatible Python SDK Versions       |
| ------------------- | ------------------------------------ |
| v3.6.0              | v0.7.6 ~ v0.10.5                     |
| v3.5.0              | v0.7.6 ~ v0.10.4                     |
| v3.4.0              | v0.7.6 ~ v0.10.4                     |
| v3.3.0              | v0.7.6 ~ v0.10.4                     |
| v3.2.0              | v0.7.6 ~ v0.9.x                      |
| v3.1.1              | v0.7.6 ~ v0.9.x                      |
| v3.1.0              | v0.7.6 ~ v0.9.x                      |
| v3.0.0              | v0.7.6 ~ v0.9.x                      |
| v2.8.1              | v0.7.6 ~ v0.8.4                      |
| v2.8.0              | v0.7.6 ~ v0.8.4                      |
| v2.7.4              | v0.7.4 ~ v0.7.20                     |
| v2.7.3              | v0.7.4 ~ v0.7.20                     |
| v2.7.1              | v0.7.4 ~ v0.7.20                     |
| v2.7.0              | v0.7.4 ~ v0.7.20                     |
| v2.6.3              | v0.7.4 ~ v0.7.20                     |
| v2.6.2              | v0.7.4 ~ v0.7.20                     |
| v2.5.0              | v0.6.0 ~ v0.7.3                      |
| v2.4                | v0.6.0 ~ v0.7.3                      |
| v2.3                | v0.6.0 ~ v0.7.3                      |
| v2.2                | v0.6.0 ~ v0.7.3 (excluding grouping) |
| v2.1                | v0.6.0 ~ v0.7.3 (excluding grouping) |
| v2.0                | v0.6.0 ~ v0.7.3 (excluding grouping) |
| v1.3                | v0.6.0 ~ v0.7.3 (excluding grouping) |
| v1.2                | v0.6.0 ~ v0.6.4                      |
| v1.1                | v0.6.0 ~ v0.6.4                      |

<br>

## 🌟 Release Notes

**v3.6.0 (2026.11.11)**

- 📊 **Histogram Visualization**: Added `swanlab.Histogram` to log and visualize parameter distributions such as model weights and gradients.
- ⚙️ **Section Settings & Chart Sorting**: Added support for customizing dashboard sections and ordering charts.
- 🗂️ **Hierarchical Metric Tree**: Introduced a tree-view directory for navigating nested metrics.
- 🐞 **Performance**: Improved chart interaction responsiveness powered by WebAssembly (WASM).

**v3.5.0 (2026.10.13)**

- 📊 **Run Focus Mode**: Hover over a legend item or run to automatically highlight its corresponding series.
- 🦜 **Enhanced Run Pinning**: Added more flexible filtering options for pinned runs in the sidebar.
- 📉 **Run Group Aggregation**: Added aggregation controls for grouped runs.
- 🐞 **Bug Fix**: Fixed line chart rendering glitches caused by extreme floating-point values (`±1e308`).

**v3.4.0 (2026.09.17)**

- 📊 **Quick Chart Creation**: Create and configure charts directly within dashboard views.
- 🔗 **Shareable View Links**: Each dashboard view now generates a dedicated URL for easy sharing.
- 👥 **Cross-Collaborator Comparison**: Compare runs directly from collaborator projects.

**v3.3.0 (2026.09.01)**

> ⚠️ **Note**: Starting with this release, all infrastructure and application images are served from `repo.swanlab.cn`. The first upgrade automatically rewrites image references in `docker-compose.yaml` and pulls the updated images. Legacy images can be removed with `docker image prune`.

- 📊 **Metric Expressions**: Compute and visualize derived metrics by combining multiple existing metrics.
- ⚙️ **Custom Chart Definitions**: Added the [`swanlab.define_metric()`](https://docs.swanlab.cn/en/api/py-define_metric.html) API to configure custom X-axes and chart grouping prior to logging metrics.
- 🐞 **Permission Fix**: Fixed a `403 Forbidden` error during initialization for users with write-only permissions when targeting an existing project (the SDK now queries the project first and only creates it if absent).

<details><summary>Previous Releases</summary>

**v3.2.0 (2026.08.24)**

- 🗑 **Trash / Recycle Bin**: Deleted projects and runs are now moved to the Trash, where they can be restored or permanently purged.
- 🔬 **Cross-Project Comparison**: Compare runs across different projects in the same view.
- 🐞 **Bug Fix**: Fixed an issue where empty system charts could not be hidden.
- 🐞 **Bug Fix**: Fixed an issue where run color changes in the comparison view did not sync to the single-run view.

**v3.1.1 (2026.08.04)**

- 📉 Added support for importing runs across projects for comparison.
- 📈 Increased the maximum number of pinned runs to 20, and the maximum number of displayed runs/groups per line chart to 25.

**v3.1.0 (2026.07.29)**

- 📊 Added support for rendering `NaN` data points and displaying group aggregation limit notices.
- 🐞 Fixed an issue where empty charts could not be hidden in multi-view mode.

**v3.0.0 (2026.07.21)**

- 📊 Launched the new multi-view interactive dashboard (requires `swanlab >= 0.9.0` SDK).

**v2.8.1 (2026.06.15)**

- Feature: Added support for HTML charts.
- Improvement: Searching runs now dynamically filters the chart comparison view.
- Improvement: Enhanced compatibility with SDK v0.8.0.
- Operations: Added support for [Prometheus monitoring](https://docs.swanlab.cn/en/self_host/kubernetes/monitor-logging.html).

**v2.8.0 (2026.05.29)**

- Minor bug fixes and stability improvements.

**v2.7.4 (2026.04.27)**

- Added project favorites (star) and fixed known issues.

**v2.7.3 (2026.04.08)**

- Added support for starring runs, setting baseline runs, and saving artifacts/files.

**v2.7.1 (2026.03.06)**

- Minor bug fixes and stability improvements.

**v2.7.0 (2026.01.29)**

- Improved frontend rendering performance for large-scale experiments and high-cardinality metrics.

**v2.6.3 (2026.01.19)**

- Added heartbeat detection and optimized chart rendering performance.

**v2.6.2 (2025.12.19)**

- Bug fixes, feature parity updates with SwanLab Cloud, and support for `swanlab` SDK v0.7.4.

**v2.5.1 (2025.12.10)**

- Added support for replacing the bundled MinIO service with any S3-compatible external object storage.

**v2.5.0 (2025.12.05)**

- Introduced a comprehensive administration dashboard for the Enterprise Edition.

**v2.4 (2025.11.24)**

- Removed the requirement to expose MinIO port `9000` externally.
- Added timestamp metadata to line chart data points.

**v2.3 (2025.11.17)**

- Added support for run grouping.

**v2.2 (2025.11.06)**

- Added support for custom X-axes in line charts.

**v2.1 (2025.09.30)**

- Launched redesigned chart view UI and synced features with SwanLab Cloud.

**v2.0 (2025.09.01)**

- Revamped the role-based access control (RBAC) and permission system.

**v1.3 (2025.07.08)**

- Synced latest features from SwanLab Cloud.

**v1.2 (2025.05.30)**

- Feature: Added line chart creation, editing, and multi-metric data source selection.
- Feature: Added experiment run tags.
- Feature: Added logarithmic scale (Log Scale) for line charts, drag-and-drop group reordering, and `swanlab.OpenApi` programmatic interfaces.
- Feature: Added "Default Space" and "Default Visibility" settings for newly created projects.
- Improvement: Significantly improved metric ingestion throughput and resolved data loss under high concurrency.
- Bug Fix: Fixed an issue where certain runs did not transition to a completed state automatically.

**v1.1 (2025.04.27)**

- Updated container images to v1.1. New installations can run `install.sh` directly; existing v1.0 deployments can upgrade in place via `docker/upgrade.sh`.

</details>

<br>

## 📚 Resources

- [Air-Gapped (Offline) Deployment Guide](https://docs.swanlab.cn/en/self_host/docker/offline-deployment.html)
- [Alibaba Cloud Compute Nest Deployment](https://docs.swanlab.cn/en/self_host/alibabacloud-computenest.html)
- [Tencent Cloud Marketplace Deployment](https://docs.swanlab.cn/en/self_host/tencentcloud-app.html)
- [Frequently Asked Questions (FAQ)](https://docs.swanlab.cn/en/self_host/kubernetes/faq.html)
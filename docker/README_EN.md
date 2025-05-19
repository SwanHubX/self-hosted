## Deployment via Docker

[中文](./README.md)
> First, make sure you have [docker](https://docs.docker.com/engine/install/) installed on your server. If not installed, you can refer to the [documentation](https://docs.docker.com/engine/install/), or use our installation script [scripts/install-docker.sh](../scripts/install-docker.sh).
> If your server does not have Docker Compose plugin, you can refer to the [documentation](https://github.com/docker/compose/) for downloading and installing. Alternatively, you can use our provided installation script [scripts/install-docker-compose.sh](../scripts/install-docker-compose.sh).

### Online Deployment
When the server can be connected to the network, simply execute the `./install-dockerhub.sh` script to start deployment. After successful deployment, you will see the **SwanLab** logo below.

```bash
$ ./install.sh

...
   _____                    _           _
  / ____|                  | |         | |
 | (_____      ____ _ _ __ | |     __ _| |__
  \___ \ \ /\ / / _` | '_ \| |    / _` | '_ \
  ____) \ V  V / (_| | | | | |___| (_| | |_) |
 |_____/ \_/\_/ \__,_|_| |_|______\__,_|_.__/

 Self-Hosted Docker v1.0 - @SwanLab

🎉 Wow, the installation is complete. Everything is perfect.
🥰 Congratulations, self-hosted SwanLab can be accessed using {IP}:8000
```

### Offline Deployment

1. **Download Images on a Networked Machine:** On a machine with internet access and a Docker environment, download the necessary images by running the script located at `scripts/pull-images.sh`. After the script completes, it will generate a file named `swanlab_images.tar` in the current directory. This file contains the compressed archive of all the required images. **Please ensure that the machine used for downloading has Docker properly installed and running.**
2.  **Transfer the Archive to the Target Machine:** Upload the `swanlab_images.tar` file to your target machine. (You can use tools like `sftp` for this purpose).
3.  **Load Images on the Target Machine:** On the target server, run the command `docker load -i swanlab_images.tar` to load the images from the archive. After the loading process is complete, you can verify the image list using the `docker images` command. It should display all the images contained in the archive.
4.  **Install SwanLab:** Proceed with the installation by executing `./install.sh`, following the same steps as the online deployment method.

### Configurable Items

The script will prompt for two configurable items during execution:

1. Data storage path, default is `./data`. It's recommended to choose a fixed path for long-term storage, such as `/data`.
2. Service exposure port, default is `8000`. If deployed on a public server, it can be set to `80`.

If interactive configuration is not needed, the script also provides three command line options:

- `-d`: Specify the data storage path
- `-p`: Service exposure port
- `-s`: Skip interactive configuration. If you don't want interactive configuration, you must add `-s`

For example, to specify the storage path as `/data` and expose port `80`:

```bash
$ ./install.sh -d /data -p 80 -s
```

### Execution Results

After successful script execution, a `swanlab/` directory will be created, and two files will be generated in the current directory:

- `docker-compose.yaml`: Configuration file for Docker Compose
- `.env`: Corresponding key file, storing the initialization password for the database

Execute `docker compose ps -a` in the current directory to check the running status of all containers:

```bash
$ docker compose ps -a                                                                                                                                                                (base)
NAME                 IMAGE                                                                   COMMAND                  SERVICE          CREATED          STATUS                    PORTS
swanlab-clickhouse   ccr.ccs.tencentyun.com/self-hosted/clickhouse:24.3                      "/entrypoint.sh"         clickhouse       22 minutes ago   Up 22 minutes (healthy)   8123/tcp, 9000/tcp, 9009/tcp
swanlab-cloud        ccr.ccs.tencentyun.com/self-hosted/swanlab-cloud:v1                     "/docker-entrypoint.…"   swanlab-cloud    22 minutes ago   Up 21 minutes             80/tcp
swanlab-fluentbit    ccr.ccs.tencentyun.com/self-hosted/fluent-bit:3.0                       "/fluent-bit/bin/flu…"   fluent-bit       22 minutes ago   Up 22 minutes             2020/tcp
swanlab-house        ccr.ccs.tencentyun.com/self-hosted/swanlab-house:v1                     "./app"                  swanlab-house    22 minutes ago   Up 21 minutes (healthy)   3000/tcp
swanlab-logrotate    ccr.ccs.tencentyun.com/self-hosted/logrotate:v1                         "/sbin/tini -- /usr/…"   logrotate        22 minutes ago   Up 22 minutes
swanlab-minio        ccr.ccs.tencentyun.com/self-hosted/minio:RELEASE.2025-02-28T09-55-16Z   "/usr/bin/docker-ent…"   minio            22 minutes ago   Up 22 minutes (healthy)   9000/tcp
swanlab-next         ccr.ccs.tencentyun.com/self-hosted/swanlab-next:v1                      "docker-entrypoint.s…"   swanlab-next     22 minutes ago   Up 21 minutes             3000/tcp
swanlab-postgres     ccr.ccs.tencentyun.com/self-hosted/postgres:16.1                        "docker-entrypoint.s…"   postgres         22 minutes ago   Up 22 minutes (healthy)   5432/tcp
swanlab-redis        ccr.ccs.tencentyun.com/self-hosted/redis-stack-server:7.2.0-v15         "/entrypoint.sh"         redis            22 minutes ago   Up 22 minutes (healthy)   6379/tcp
swanlab-server       ccr.ccs.tencentyun.com/self-hosted/swanlab-server:v1                    "docker-entrypoint.s…"   swanlab-server   22 minutes ago   Up 21 minutes (healthy)   3000/tcp
swanlab-traefik      ccr.ccs.tencentyun.com/self-hosted/traefik:v3.0                         "/entrypoint.sh trae…"   traefik          22 minutes ago   Up 22 minutes (healthy)   0.0.0.0:8000->80/tcp, [::]:8000->80/tcp
```

You can view the logs of each container by executing `docker compose logs <container_name>`.

### Upgrade

Execute `./upgrade.sh` to upgrade seamlessly.
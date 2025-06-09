#!/bin/bash

# some fancy scripts
red=$(tput setaf 1)
green=$(tput setaf 2)
yellow=$(tput setaf 3)
bold=$(tput bold)
reset=$(tput sgr0)

# -----------------------------------------------
# The following are all the parameters that can be set.
# the path to store data
# shell flag: -d, such as: -d /path/to/data
DATA_PATH="./data"
# the port to expose, and port 8000 is the default network port for web servers using HTTP.
# shell flag: -p, such as: -p 8080
EXPOSE_PORT=8000
# skip input, default is 0
# shell flag: -s, if -s is added, no manual input is required
SKIP_INPUT=0

while getopts ":d:p:" opt; do
  case ${opt} in
    d )
      DATA_PATH="$OPTARG"
      ;;
    p )
      EXPOSE_PORT="$OPTARG"
      ;;
    s )
      SKIP_INPUT=1
      ;;
    \? )
      echo "🧐 Invalid option: -$OPTARG" >&2
      exit 1
      ;;
    : )
      echo "🧐 Option -$OPTARG need a parameter." >&2
      exit 1
      ;;
  esac
done

# -----------------------------------------------

# check if docker is installed
if ! command -v docker &>/dev/null; then
    echo "😰 ${red}Docker is not installed.${reset}"
    echo "😁 ${bold}Please use the install script (${green}install-docker.sh${reset})${bold} located in the scripts directory.${reset}"
    echo
    exit 1
fi

echo "🤩 ${bold}Docker is installed, so let's get started.${reset}"

# check if docker compose is installed
if ! docker compose version &>/dev/null;  then
    echo "😰 ${yellow}Docker Compose may not install ${reset}"

    if [[ "$(uname -s)" == "Linux" ]]; then
        echo "😁 ${bold}You can use the install script (${green}install-docker-compose.sh${reset})${bold} located in the scripts directory.${reset}"
    else
        echo "🧐 ${red}macOS/Windows detected: Docker Compose is included in Docker Desktop. Please install Docker Desktop${reset}"
        exit 1
    fi
fi


# check if docker daemon is running
echo "🧐 Checking if Docker is running..."
docker_not_running=1

if docker info >/dev/null 2>&1; then
    docker_not_running=0
fi

if [[ $docker_not_running -eq 1 ]]; then
    echo "😰 ${red}Docker daemon is not running.${reset}"
    if [[ "$(uname -s)" == "Linux" ]]; then
        # Linux systems provide options for automatic startup
        read -p "😁 ${bold}Would you like to start Docker now? (y/n): " START_DOCKER
        if [[ "$START_DOCKER" =~ ^[Yy]$ ]]; then
            if ! systemctl start docker; then
                echo "❌ ${red}Failed to start Docker. You may need to run with sudo.${reset}"
                exit 1
            fi
            echo "🚀 Starting Docker service..."
            # waiting Docker startup
            max_attempts=5
            attempt=1
            while [ $attempt -le $max_attempts ]; do
                if systemctl is-active --quiet docker; then
                    echo "✅ ${green}Docker started successfully!${reset}"
                    break
                fi
                sleep 1
                ((attempt++))
            done

            # final check
            if ! systemctl is-active --quiet docker; then
                echo "❌ ${red}Docker failed to start after $max_attempts second attempts${reset}"
                exit 1
            fi
        else
            echo "👋 ${yellow}Operation canceled. Docker must be running to continue.${reset}"
            exit 1
        fi
    else
        # macOS/Windows systems don't provide automatic startup options
        echo "💡 ${yellow}Please start Docker Desktop manually and ensure it's running:"
        echo "1. Open Docker Desktop application"
        echo "2. Wait until the whale icon shows \"Docker Desktop is running\""
        echo "3. Rerun this installation script${reset}"
        exit 1
    fi
fi

mkdir -p swanlab && cd swanlab

# Select whether to use this configuration
if [ ! -f .env ] && [ "$SKIP_INPUT" -eq 0 ]; then
  # ---- DATA_PATH
  echo
  read -p "1. Use the default path  (${bold}$DATA_PATH${reset})? (y/n): " USE_DEFAULT

  # Process the user's choice
  if [[ -n "$USE_DEFAULT" && ! "$USE_DEFAULT" =~ ^[Yy]$ ]]; then
    read -p "   Enter a custom path: " DATA_PATH
  fi
  # Trim the end of `/`
  DATA_PATH=$(echo "$DATA_PATH" | sed 's:/*$::')
  echo "   The selected path is: ${green}$DATA_PATH${reset}"

  # ---- EXPOSE_PORT
  read -p "2. Use the default port  (${bold}$EXPOSE_PORT${reset})? (y/n): " USE_DEFAULT1

  # Process the user's choice
  if [[ -n "$USE_DEFAULT1" && ! "$USE_DEFAULT1" =~ ^[Yy]$ ]]; then
    read -p "   Enter a custom port:  " EXPOSE_PORT
  fi
  echo "   The exposed port is: ${green}$EXPOSE_PORT${reset}
  "
fi

# random 12-digit password include numbers, uppercase and lowercase letters
random_password() {
    openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | cut -c1-10
}

POSTGRES_PASSWORD=$(random_password)
CLICKHOUSE_PASSWORD=$(random_password)
MINIO_ROOT_PASSWORD=$(random_password)

if [ ! -f ".env" ]; then
  echo "🤐 Create .env file in current directory to save keys"
  echo "POSTGRES_PASSWORD=$POSTGRES_PASSWORD" > .env
  echo "CLICKHOUSE_PASSWORD=$CLICKHOUSE_PASSWORD" >> .env
  echo "MINIO_ROOT_PASSWORD=$MINIO_ROOT_PASSWORD" >> .env
  echo "DATA_PATH=$DATA_PATH" >> .env
  echo "EXPOSE_PORT=$EXPOSE_PORT" >> .env
fi

export $(grep -v '^#' .env | xargs)

echo "🥳 Everything's ready for execution."

# create docker-compose.yaml
[ -f "docker-compose.yaml" ] && rm docker-compose.yaml
cat > docker-compose.yaml <<EOF
networks:
  swanlab-net:
    name: swanlab-net

volumes:
  swanlab-house:
    name: swanlab-house
  fluent-bit:
    name: fluent-bit

x-common: &common
  networks:
    - swanlab-net
  restart: unless-stopped
  logging:
    options:
      max-size: 50m
      max-file: "3"

services:
  # Gateway
  traefik:
    <<: *common
    image: ccr.ccs.tencentyun.com/self-hosted/traefik:v3.0
    container_name: swanlab-traefik
    ports:
      - "${EXPOSE_PORT}:80"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "0.0.0.0:8080/ping"]
      interval: 10s
      timeout: 5s
      retries: 3
  # Databases
  postgres:
    <<: *common
    image: ccr.ccs.tencentyun.com/self-hosted/postgres:16.1
    container_name: swanlab-postgres
    environment:
      TZ: UTC
      POSTGRES_USER: swanlab
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: app
    volumes:
      - ${DATA_PATH}/postgres/data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready"]
      interval: 10s
      timeout: 5s
      retries: 5
  redis:
    <<: *common
    image: ccr.ccs.tencentyun.com/self-hosted/redis-stack-server:7.2.0-v15
    container_name: swanlab-redis
    volumes:
      - ${DATA_PATH}/redis:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 3
  clickhouse:
    <<: *common
    image: ccr.ccs.tencentyun.com/self-hosted/clickhouse:24.3
    container_name: swanlab-clickhouse
    volumes:
      - ${DATA_PATH}/clickhouse:/var/lib/clickhouse/
    environment:
      TZ: UTC
      CLICKHOUSE_USER: swanlab
      CLICKHOUSE_PASSWORD: ${CLICKHOUSE_PASSWORD}
      CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT: 1
    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "0.0.0.0:8123/ping"]
      interval: 10s
      timeout: 5s
      retries: 3
  logrotate:
    <<: *common
    image: ccr.ccs.tencentyun.com/self-hosted/logrotate:v1
    container_name: swanlab-logrotate
    volumes:
      - swanlab-house:/data
    environment:
      LOGS_DIRECTORIES: "/data"
      LOGROTATE_COPIES: 25
      LOGROTATE_SIZE: "25M"
      LOGROTATE_CRONSCHEDULE: "*/20 * * * * *"
      LOGROTATE_INTERVAL: daily
    labels:
      - "traefik.enable=false"
  fluent-bit:
    <<: *common
    image: ccr.ccs.tencentyun.com/self-hosted/fluent-bit:3.0
    container_name: swanlab-fluentbit
    command: ["fluent-bit/bin/fluent-bit", "-c", "/conf/fluent-bit.conf"]
    volumes:
      - fluent-bit:/data
      - swanlab-house:/metrics
    environment:
      LOG_PATH: /metrics/*.log
      CLICKHOUSE_HOST: clickhouse
      CLICKHOUSE_PORT: 8123
      CLICKHOUSE_USER: swanlab
      CLICKHOUSE_PASS: ${CLICKHOUSE_PASSWORD}
  minio:
    <<: *common
    image: ccr.ccs.tencentyun.com/self-hosted/minio:RELEASE.2025-02-28T09-55-16Z
    container_name: swanlab-minio
    ports:
      - "9000:9000"
    volumes:
      - ${DATA_PATH}/minio:/data
    environment:
      MINIO_ROOT_USER: swanlab
      MINIO_ROOT_PASSWORD: ${MINIO_ROOT_PASSWORD}
    labels:
      - "traefik.http.services.minio.loadbalancer.server.port=9000"
      - "traefik.http.routers.minio1.rule=PathPrefix(\`/swanlab-public\`)"
      - "traefik.http.routers.minio1.middlewares=minio-host@file"
      - "traefik.http.routers.minio2.rule=PathPrefix(\`/swanlab-private\`)"
      - "traefik.http.routers.minio2.middlewares=minio-host@file"
    command: server /data --console-address ":9001"
    healthcheck:
      test: ["CMD", "mc", "ready", "local"]
      interval: 10s
      timeout: 5s
      retries: 3
  create-buckets:
    image: ccr.ccs.tencentyun.com/self-hosted/minio-mc:RELEASE.2025-04-08T15-39-49Z
    container_name: swanlab-minio-mc
    networks:
      - swanlab-net
    depends_on:
      minio:
        condition: service_healthy
    entrypoint: >
      /bin/sh -c "
        mc alias set myminio http://minio:9000 swanlab ${MINIO_ROOT_PASSWORD}
        # private bucket
        mc mb --ignore-existing myminio/swanlab-private
        mc anonymous set private myminio/swanlab-private
        # public bucket
        mc mb --ignore-existing myminio/swanlab-public
        mc anonymous set public myminio/swanlab-public
      "
  # swanlab services
  swanlab-server:
    <<: *common
    image: ccr.ccs.tencentyun.com/self-hosted/swanlab-server:v1.2.1
    container_name: swanlab-server
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    environment:
      - DATABASE_URL=postgresql://swanlab:${POSTGRES_PASSWORD}@postgres:5432/app?schema=public
      - DATABASE_URL_REPLICA=postgresql://swanlab:${POSTGRES_PASSWORD}@postgres:5432/app?schema=public
      - REDIS_URL=redis://default@redis:6379
      - SERVER_PREFIX=/api
      - ACCESS_KEY=swanlab
      - SECRET_KEY=${MINIO_ROOT_PASSWORD}
      - VERSION=1.2.0
    labels:
      - "traefik.http.routers.swanlab-server.rule=PathPrefix(\`/api\`)"
      - "traefik.http.routers.swanlab-server.middlewares=preprocess@file"
    command: bash -c "npx prisma migrate deploy && node migrate.js && pm2-runtime app.js"
    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "0.0.0.0:3000/api/"]
      interval: 10s
      timeout: 5s
      retries: 3
  swanlab-house:
    <<: *common
    image: ccr.ccs.tencentyun.com/self-hosted/swanlab-house:v1.2
    container_name: swanlab-house
    depends_on:
      clickhouse:
        condition: service_healthy
      redis:
        condition: service_healthy
    environment:
      - SH_API_PREFIX=/api/house
      - SH_LOG_PATH=/data/metrics.log
      - SH_DATABASE_URL=tcp://swanlab:${CLICKHOUSE_PASSWORD}@clickhouse:9000/app
      - SH_SERVER_URL=http://swanlab-server:3000/api
      - SH_MINIO_SECRET_ID=swanlab
      - SH_MINIO_SECRET_KEY=${MINIO_ROOT_PASSWORD}
      - SH_DISTRIBUTED_ENABLE=true
      - SH_REDIS_URL=redis://default@redis:6379
    labels:
      - "traefik.http.routers.swanlab-house.rule=PathPrefix(\`/api/house\`) || PathPrefix(\`/api/internal\`)"
      - "traefik.http.routers.swanlab-house.middlewares=preprocess@file"
    volumes:
      - swanlab-house:/data
    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "0.0.0.0:3000/api/house/health"]
      interval: 10s
      timeout: 5s
      retries: 3
  swanlab-cloud:
    <<: *common
    image: ccr.ccs.tencentyun.com/self-hosted/swanlab-cloud:v1.2
    container_name: swanlab-cloud
    depends_on:
      swanlab-server:
        condition: service_healthy
  swanlab-next:
    <<: *common
    image: ccr.ccs.tencentyun.com/self-hosted/swanlab-next:v1.2
    container_name: swanlab-next
    depends_on:
      swanlab-server:
        condition: service_healthy
    environment:
      - NEXT_CLOUD_URL=http://swanlab-cloud:80
    labels:
      - "traefik.http.routers.swanlab-next.rule=PathPrefix(\`/\`)"
EOF

# start docker services
docker compose up -d

echo -e "${green}${bold}"
echo "   _____                    _           _     ";
echo "  / ____|                  | |         | |    ";
echo " | (_____      ____ _ _ __ | |     __ _| |__  ";
echo "  \___ \ \ /\ / / _\` | '_ \| |    / _\` | '_ \ ";
echo "  ____) \ V  V / (_| | | | | |___| (_| | |_) |";
echo " |_____/ \_/\_/ \__,_|_| |_|______\__,_|_.__/ ";
echo "                                              ";
echo " Self-Hosted Docker v1.2 - @SwanLab"
echo -e "${reset}"
echo "🎉 Wow, the installation is complete. Everything is perfect."
echo "🥰 Congratulations, self-hosted SwanLab can be accessed using ${green}{IP}:${EXPOSE_PORT}${reset}"
echo ""
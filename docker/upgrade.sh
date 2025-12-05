#!/bin/bash

# update docker-compose.yaml swanlab.* image version

COMPOSE_FILE="${1:-swanlab/docker-compose.yaml}"
# update swanlab-server replica database config
add_replica_env() {
    sed -i.bak -E '
    /^[[:space:]]*swanlab-server:/,/^$/ {
        /environment:/,/^[[:space:]]*- / {
            /^[[:space:]]*- DATABASE_URL=/ {
                p
                s/DATABASE_URL=/DATABASE_URL_REPLICA=/
            }
        }
    }
    ' "$COMPOSE_FILE"
}

# 为指定 service 添加 traefik 端口 label
add_traefik_port_label() {
  local service=$1
  local port=$2
  add_new_var "$service" "labels" "- \"traefik.http.services.${service}.loadbalancer.server.port=${port}\""
}

# 向某一个服务下新增一个子块加一条值，例如向clickhouse添加
# labels:
#    - "traefik.enable=false"
add_new_key_with_value() {
  local service=$1
  local service_name="$1"
  local label_key="$2"
  local new_val="$3"
  local file_path="$COMPOSE_FILE"

    # mktemp
    local tmp_file
    tmp_file=$(mktemp) || {
        echo "can not make temp file" >&2
        return 1
    }
    awk -v service="$service_name" \
        -v label="$label_key" \
        -v val="$new_val" '
    BEGIN { in_service = 0; indent = "" }
    $0 ~ "^  " service ":$" { in_service = 1; print; next }
    in_service && $0 ~ "^    image:" {
        print
        match($0, /^ */); indent = substr($0, 1, RLENGTH)
        print indent label ":"
        print indent "  " val
        next
    }
    /^  [a-zA-Z-]+:/ && !/^  'service':$/ { in_service = 0 }
    { print }
    ' "$file_path" > "$tmp_file"

    # replace  file
    if ! mv "$tmp_file" "$file_path"; then
        echo "replace fail, update docker-compose.yaml locate on ${tmp_file} " >&2
        return 2
    fi
}

# 为服务添加健康检查
add_health_check(){
  local service=$1
  local port=$2

  add_new_key_with_value "$service" "healthcheck" "start_period: 5s"
  add_new_var "$service" "healthcheck" "retries: 5"
  add_new_var "$service" "healthcheck" "timeout: 3s"
  add_new_var "$service" "healthcheck" "interval: 5s"
  add_new_var "$service" "healthcheck" "test: [\"CMD\", \"wget\", \"--spider\", \"-q\", \"0.0.0.0:${port}\"]"
}

# add new variable for containers config
add_new_var() {
    # Arguments:
    #   : service name
    #   : label key
    #   : new variable
    local service_name="$1"
    local label_key="$2"
    local new_val="$3"
    local file_path="$COMPOSE_FILE"
    # check arguments
    if [[ -z "$service_name" || -z "$new_val" ]]; then
        echo "error: must input service name and new environment variable" >&2
        return 1
    fi

    # mktemp
    local tmp_file
    tmp_file=$(mktemp) || {
        echo "can not make temp file" >&2
        return 2
    }
    # do awk operation
    awk -v service="$service_name" \
        -v label="$label_key" \
        -v val="$new_val" '
    BEGIN { in_service=0; inserted=0 }
    $0 ~ "^  " service ":$" { in_service=1 }
    /^  [a-zA-Z-]+:/ && !( $0 ~ "^  " service ":$") { in_service=0 }
    in_service && $0 ~ "^    " label ":" {
        print $0
        print "      " val
        inserted=1
        next
    }
    { print }
    ' "$file_path" > "$tmp_file"

    # replace  file
    if ! mv "$tmp_file" "$file_path"; then
        echo "replace fail, update docker-compose.yaml locate on ${tmp_file} " >&2
        return 3
    fi
}

# update swanlab-server command config
update_server_command() {
    sed -i.bak '
    /^[[:space:]]*command: bash -c "npx prisma migrate deploy && pm2-runtime app.js"/ {
        s/&& pm2-runtime app.js"/\&\& node migrate.js \&\& pm2-runtime app.js"/
    }
    ' "$COMPOSE_FILE"
}

# change version
update_version() {
    local version="$1"

    if [ -z "$version" ]; then
        echo "Error: Version number is required."
        return 1
    fi

    sed -i.bak -E "
        /^[[:space:]]+image: .*swanlab-.*:v[^:]+$/ {
            s/(:v)[^:]+$/\1${version}/
        }
    " "$COMPOSE_FILE"
}

# update specific service version
update_service_version() {
    local service="$1"
    local version="$2"

    if [ -z "$service" ] || [ -z "$version" ]; then
        echo "Error: Service name and version number are required."
        return 1
    fi

    sed -i.bak -E "
        /^[[:space:]]+image: .*${service}:[^:]+$/ {
            s/(:v?)[^:]+$/\1${version}/
        }
    " "$COMPOSE_FILE"
}

# update self-hosted version
update_self_hosted_version() {
    local full_version="$1"
    sed -i.bak -E "
        /^[[:space:]]*swanlab-server:/,/^$/ {
            /^[[:space:]]*environment:/,/^$/ {
                /^[[:space:]]*- VERSION=[0-9]+([.][0-9]+)*[.][0-9]+/ {
                    s/(VERSION=)[0-9]+([.][0-9]+)*[.][0-9]+/\\1${full_version}/
                }
            }
        }
    " "$COMPOSE_FILE"
}

# check docker-compose.yaml exists
if [ ! -f "$COMPOSE_FILE" ]; then
    echo "docker-compose.yaml not found, please run install.sh directly"
    exit 1
fi

# # confirm information
read -p "Updating the container version will restart docker compose. Do you agree? [y/N] " confirm

# # check y or Y
if [[ "$confirm" == [yY] || "$confirm" == [yY][eE][sS] ]]; then
    echo "begin update"
    # 更新设置页面版本号
    update_self_hosted_version "2.5.0"
    # update all containers version
    update_version "2.5.0"
    update_service_version "fluent-bit" "3.1"
    update_service_version "traefik" "3.1"

    # update DATABASE_URL_REPLICA
    if ! grep -q "DATABASE_URL_REPLICA" "$COMPOSE_FILE"; then
      add_replica_env
    fi

    # update traefik port label
    if ! grep -q "traefik.http.services.swanlab-server.loadbalancer.server.port=3000" "$COMPOSE_FILE"; then
      add_traefik_port_label "swanlab-server" 3000
      add_traefik_port_label "swanlab-house" 3000
      add_traefik_port_label "swanlab-next" 3000

      #  为指定 service 添加 traefik.enable=false
      add_new_key_with_value "postgres" "labels" "- \"traefik.enable=false\""
      add_new_key_with_value "redis" "labels" "- \"traefik.enable=false\""
      add_new_key_with_value "clickhouse" "labels" "- \"traefik.enable=false\""
      add_new_key_with_value "fluent-bit" "labels" "- \"traefik.enable=false\""
      add_new_key_with_value "create-buckets" "labels" "- \"traefik.enable=false\""
      add_new_key_with_value "swanlab-cloud" "labels" "- \"traefik.enable=false\""
    fi

    # update swanlab-server command
    if ! grep -q "node migrate.js" "$COMPOSE_FILE"; then
       update_server_command
    fi

    # delete backup
    rm -f "${COMPOSE_FILE}.bak"

    # add new variable for containers config, it only can be added once and can not be update existing
    # add swanlab-house environment variable
    if ! grep -q "SH_DISTRIBUTED_ENABLE" "$COMPOSE_FILE"; then
      add_new_var "swanlab-house" "environment" "- SH_DISTRIBUTED_ENABLE=true"
    fi
    if ! grep -q "SH_REDIS_URL" "$COMPOSE_FILE"; then
      add_new_var "swanlab-house" "environment" "- SH_REDIS_URL=redis://default@redis:6379"
    fi
    # add swanlab-server environment variable
    if ! grep -q "VERSION" "$COMPOSE_FILE"; then
      add_new_var "swanlab-server" "environment" "- VERSION=2.4.0"
    fi

    # add missing minio middleware if needed
    if ! grep -q 'traefik.http.routers.minio3.rule=PathPrefix(`/swanlab-private`)' "$COMPOSE_FILE"; then
      add_new_var "minio" "labels" "- \"traefik.http.routers.minio3.rule=PathPrefix(\`/swanlab-private\`)\""
    fi
    if ! grep -q "traefik.http.routers.minio2.middlewares=minio-host@file" "$COMPOSE_FILE"; then
      add_new_var "minio" "labels" "- \"traefik.http.routers.minio2.middlewares=minio-host@file\""
    fi
    if ! grep -q 'traefik.http.routers.minio2.rule=PathPrefix(`/swanlab-private/exports`)' "$COMPOSE_FILE"; then
      add_new_var "minio" "labels" "- \"traefik.http.routers.minio2.rule=PathPrefix(\`/swanlab-private/exports\`)\""
    fi
    # delete old minio labels if exists
    if grep -q 'traefik.http.routers.minio2.rule=PathPrefix(`/swanlab-private`)' "$COMPOSE_FILE"; then
      sed -i.bak '\|traefik\.http\.routers\.minio2\.rule=PathPrefix(`/swanlab-private`)|d' "$COMPOSE_FILE"
    fi
    # delete minio ports mapping
    # 删除以 'ports:' 开头，并且下一行包含 9000:9000 的两行
    sed -i.bak '/^[[:space:]]*ports:[[:space:]]*$/{
    N
    /"9000:9000"/d
    }' "$COMPOSE_FILE"
    # add healthcheck for swanlab-cloud
    if ! grep -A 10 'swanlab-cloud:' "$COMPOSE_FILE" | grep -q '^    healthcheck:'; then
      add_health_check "swanlab-cloud" 80
    fi
    # add healthcheck for swanlab-next
    if ! grep -A 10 'swanlab-next:' "$COMPOSE_FILE" | grep -q '^    healthcheck:'; then
      add_health_check "swanlab-next" 3000
    fi
    # restart docker-compose
    docker compose -f "$COMPOSE_FILE" up -d

    echo "⏳ Waiting for services to become healthy..."

    # Define services to check (based on docker-compose.yml)
    SERVICES=(
      swanlab-server
      swanlab-house
      swanlab-cloud
      swanlab-next
      swanlab-postgres
      swanlab-clickhouse
      swanlab-redis
      swanlab-minio
      swanlab-traefik
    )

    NOT_HEALTHY_SERVICES=()

    # Wait for each service to become healthy (timeout = 30s)
    for SERVICE in "${SERVICES[@]}"; do
      echo -n "🔍 Checking $SERVICE..."
      for i in {1..30}; do
        STATUS=$(docker inspect --format='{{.State.Health.Status}}' $SERVICE 2>/dev/null || echo "starting")
        if [ "$STATUS" == "healthy" ]; then
          echo " ✅ healthy"
          break
        fi
        sleep 1
      done
      if [ "$STATUS" != "healthy" ]; then
        echo " ❌ $SERVICE is not healthy after timeout."
        NOT_HEALTHY_SERVICES+=("$SERVICE")
      fi
    done

    if [ ${#NOT_HEALTHY_SERVICES[@]} -ne 0 ]; then
      echo -e "\n\033[0;31m❌ Oops! The following services failed to start properly:\033[0m"
      for SERVICE in "${NOT_HEALTHY_SERVICES[@]}"; do
        echo "   - $SERVICE"
      done
      echo -e "\n🔧 You can check logs using: docker logs <service-name>"
      echo "💡 Or inspect health details: docker inspect <service-name>"
      exit 1
    else
        echo "finish update"
    fi
else
    echo "update canceled"
    exit 1
fi
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

add_traefik_disable_label() {
    local service="$1"
    sed -i.bak -E "/^[[:space:]]*${service}:/,/^[[:space:]]*[a-zA-Z0-9_-]+:/ {
      /labels:/ {
        a\
          \ \ \ \ - \"traefik.enable=false\"
        b
      }
      /^(  )+[a-zA-Z_]+:/ {
        i\
          \ \ \ \ labels:\n        - \"traefik.enable=false\"
        b
      }
    }" "$COMPOSE_FILE"
}

add_traefik_port_label() {
    local service="$1"
    local port="$2"
    sed -i.bak -E "/^[[:space:]]*${service}:/,/^[[:space:]]*[a-zA-Z0-9_-]+:/ {
      /labels:/ {
        a\
          \ \ \ \ - \"traefik.http.services.${service}.loadbalancer.server.port=${port}\"
        b
      }
      /^(  )+[a-zA-Z_]+:/ {
        i\
          \ \ \ \ labels:\n        - \"traefik.http.services.${service}.loadbalancer.server.port=${port}\"
        b
      }
    }" "$COMPOSE_FILE"
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
        print "      - " val
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
        /^[[:space:]]+image: .*${service}:v[^:]+$/ {
            s/(:v)[^:]+$/\1${version}/
        }
    " "$COMPOSE_FILE"
}

# check docker-compose.yaml exists
if [ ! -f "$COMPOSE_FILE" ]; then
    echo "docker-compose.yaml not found, please run install.sh directly"
    exit 1
fi

# confirm information
read -p "Updating the container version will restart docker compose. Do you agree? [y/N] " confirm


# check y or Y
if [[ "$confirm" == [yY] || "$confirm" == [yY][eE][sS] ]]; then
    echo "begin update"
    # update all containers version
    update_version "1.3"

    # update swanlab-server to specific version
    update_service_version "swanlab-next" "1.2"

    # update DATABASE_URL_REPLICA
    if ! grep -q "DATABASE_URL_REPLICA" "$COMPOSE_FILE"; then
      add_replica_env
    fi

    # update traefik port label
    if ! grep -q "traefik.http.services.swanlab-server.loadbalancer.server.port=3000" "$COMPOSE_FILE"; then
      add_traefik_port_label "swanlab-server" 3000
      add_traefik_port_label "swanlab-house" 3000
      add_traefik_port_label "swanlab-next" 3000

      add_traefik_disable_label "postgres"
      add_traefik_disable_label "redis"
      add_traefik_disable_label "clickhouse"
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
      add_new_var "swanlab-house" "environment" "SH_DISTRIBUTED_ENABLE=true"
    fi
    if ! grep -q "SH_REDIS_URL" "$COMPOSE_FILE"; then
      add_new_var "swanlab-house" "environment" "SH_REDIS_URL=redis://default@redis:6379"
    fi
    # add swanlab-server environment variable
    if ! grep -q "VERSION" "$COMPOSE_FILE"; then
      add_new_var "swanlab-server" "environment" "VERSION=1.3.0"
    fi

    # add missing minio middleware if needed
    if ! grep -q "traefik.http.routers.minio2.middlewares=minio-host@file" "$COMPOSE_FILE"; then
      add_new_var "minio" "labels" "\"traefik.http.routers.minio2.middlewares=minio-host@file\""
    fi
    # restart docker-compose
    docker compose -f swanlab/docker-compose.yaml up -d
    echo "finish update"
else
    echo "update canceled"
    exit 1
fi

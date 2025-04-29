#!/bin/bash

# update docker-compose.yaml swanlab.* image version

# add swanlab-server replica database config
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
    ' swanlab/docker-compose.yaml
}

# check docker-compose.yaml exists
if [ ! -f "swanlab/docker-compose.yaml" ]; then
    echo "docker-compose.yaml not found, please run install.sh directly"
    exit 1
fi

# confirm information
read -p "Updating the container version will restart docker compose. Do you agree? [y/N] " confirm

# check y or Y
if [[ "$confirm" == [yY] || "$confirm" == [yY][eE][sS] ]]; then
    echo "begin update"
    sed -i.bak -E '
    /^[[:space:]]+image: .*swanlab.*:v1$/ {
        s/(:v1)$/\1.1/
    }
    ' swanlab/docker-compose.yaml
    add_replica_env
    # delete backup
    rm -f swanlab/docker-compose.yaml.bak

    # restart docker-compose
    docker compose -f swanlab/docker-compose.yaml pull && docker compose -f swanlab/docker-compose.yaml up -d
    echo "finish update"
else
    echo "update canceled"
    exit 1
fi


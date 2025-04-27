#!/bin/sh

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
    ' docker-compose.yaml
}
# confirm information
read -p "Updating the container version will restart docker-compose. Do you agree? [y/N] " confirm

# check y or Y
if [[ "$confirm" == [yY] || "$confirm" == [yY][eE][sS] ]]; then
    echo "begin update"
    sed -i.bak -E '
    /^[[:space:]]+image: .*swanlab.*:v1$/ {
        s/(:v1)$/\1.1/
    }
    ' docker-compose.yaml
    add_replica_env
    # delete backup
    rm -f docker-compose.yaml.bak

    # restart docker-compose
    docker-compose pull && docker-compose up -d
    echo "finish update"
else
    echo "update canceled"
    exit 1
fi


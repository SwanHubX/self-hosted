#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SCRIPT_NAME="${SWANLAB_INSTALL_SCRIPT:-install.sh}"
INSTALL_SCRIPT="${REPO_ROOT}/docker/${INSTALL_SCRIPT_NAME}"
WORK_DIR="${SWANLAB_TEST_WORK_DIR:-/tmp/swanlab-install-action-work}"
INSTALL_DIR="${WORK_DIR}/swanlab"
DATA_DIR="${SWANLAB_TEST_DATA_DIR:-/tmp/swanlab-install-action-data}"
PORT="${SWANLAB_TEST_PORT:-18000}"
EXPECTED_SOCKET="${SWANLAB_EXPECTED_SOCKET:-/var/run/docker.sock}"

wait_for_docker() {
  for _ in {1..60}; do
    if docker info >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done

  echo "Docker daemon did not become ready" >&2
  if [ -f /tmp/dockerd.log ]; then
    tail -n 200 /tmp/dockerd.log >&2 || true
  fi
  return 1
}

cleanup() {
  if [ -f "${INSTALL_DIR}/docker-compose.yaml" ]; then
    docker compose -f "${INSTALL_DIR}/docker-compose.yaml" down -v || true
  fi
  if [ -d "${DATA_DIR}" ] && docker info >/dev/null 2>&1; then
    docker run --rm -v "${DATA_DIR}:/data" alpine:3.20 sh -c \
      "find /data -mindepth 1 -maxdepth 1 -exec rm -rf {} +" || true
  fi
  sudo rm -rf "${WORK_DIR}" "${DATA_DIR}" 2>/dev/null || rm -rf "${WORK_DIR}" "${DATA_DIR}" 2>/dev/null || true
}

trap cleanup EXIT

bash -n "${INSTALL_SCRIPT}"

if ! docker info >/dev/null 2>&1 && [ -z "${DOCKER_HOST:-}" ] && [ "$(id -u)" -eq 0 ]; then
  nohup dockerd --host=unix:///var/run/docker.sock >/tmp/dockerd.log 2>&1 &
fi

wait_for_docker
docker compose version

cleanup
mkdir -p "${WORK_DIR}"
(cd "${WORK_DIR}" && bash "${INSTALL_SCRIPT}" -d "${DATA_DIR}" -p "${PORT}" -s)

grep -n "${EXPECTED_SOCKET}:/var/run/docker.sock" "${INSTALL_DIR}/docker-compose.yaml"
docker compose -f "${INSTALL_DIR}/docker-compose.yaml" ps

#!/usr/bin/env bash
# migrate_registry() 单元测试：
# 从 docker/upgrade.sh 中提取真实的 migrate_registry 函数（不复制逻辑），
# 用四种布局的 compose 样本验证迁移行为：
#   1. 腾讯云 CCR 布局        -> 迁移到 repo.swanlab.cn 新布局
#   2. 早期 ACR 布局（老命名） -> 迁移到 repo.swanlab.cn 新布局
#   3. 最新 ACR 布局          -> 无变化（幂等 / 新用户）
#   4. 自定义 Harbor 域名布局 -> 无变化（不误伤内网用户）
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPGRADE_SH="${REPO_ROOT}/docker/upgrade.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# 提取 upgrade.sh 中的 migrate_registry 函数定义
sed -n '/^migrate_registry()/,/^}/p' "${UPGRADE_SH}" > "${TMP_DIR}/migrate.sh"
if ! grep -q '^migrate_registry()' "${TMP_DIR}/migrate.sh"; then
    echo "::error::failed to extract migrate_registry() from ${UPGRADE_SH}" >&2
    exit 1
fi
# shellcheck source=/dev/null
source "${TMP_DIR}/migrate.sh"

run_migrate() {
    COMPOSE_FILE="$1" migrate_registry
}

# 迁移后期望出现的 12 条镜像引用（新 ACR 布局）
EXPECTED_IMAGES=(
    "repo.swanlab.cn/self-hosted/traefik:v3.1"
    "repo.swanlab.cn/self-hosted/postgres:16.1"
    "repo.swanlab.cn/self-hosted/redis-stack:7.2.0-v15"
    "repo.swanlab.cn/self-hosted/clickhouse-server:24.3"
    "repo.swanlab.cn/self-hosted/logrotate:1.0"
    "repo.swanlab.cn/self-hosted/fluent-bit:3.1"
    "repo.swanlab.cn/self-hosted/minio/minio:RELEASE.2025-02-28T09-55-16Z"
    "repo.swanlab.cn/self-hosted/minio/mc:RELEASE.2025-04-08T15-39-49Z"
    "repo.swanlab.cn/self-hosted/swanlab-server:v3.3.0"
    "repo.swanlab.cn/self-hosted/swanlab-house:v3.3.0"
    "repo.swanlab.cn/self-hosted/swanlab-cloud:v3.3.0"
    "repo.swanlab.cn/self-hosted/swanlab-next:v3.3.0"
)

assert_no_legacy() {
    local file="$1"
    if grep -qE 'ccr\.ccs\.tencentyun\.com' "${file}"; then
        echo "::error::${file} still contains ccr.ccs.tencentyun.com references" >&2
        exit 1
    fi
    if grep -qE 'repo\.swanlab\.cn/self-hosted/((redis-stack-server|clickhouse|minio|minio-mc):|logrotate:v1)' "${file}"; then
        echo "::error::${file} still contains legacy repo names" >&2
        exit 1
    fi
}

assert_expected_images() {
    local file="$1"
    for image in "${EXPECTED_IMAGES[@]}"; do
        if ! grep -qF "image: ${image}" "${file}"; then
            echo "::error::${file} missing expected image: ${image}" >&2
            exit 1
        fi
    done
}

make_compose() {
    local prefix="$1" redis="$2" clickhouse="$3" logrotate="$4" minio="$5" mc="$6"
    cat <<EOF
services:
  traefik:
    image: ${prefix}traefik:v3.1
  postgres:
    image: ${prefix}postgres:16.1
  redis:
    image: ${prefix}${redis}:7.2.0-v15
  clickhouse:
    image: ${prefix}${clickhouse}:24.3
  logrotate:
    image: ${prefix}${logrotate}
  fluent-bit:
    image: ${prefix}fluent-bit:3.1
  minio:
    image: ${prefix}${minio}:RELEASE.2025-02-28T09-55-16Z
  create-buckets:
    image: ${prefix}${mc}:RELEASE.2025-04-08T15-39-49Z
  swanlab-server:
    image: ${prefix}swanlab-server:v3.3.0
  swanlab-house:
    image: ${prefix}swanlab-house:v3.3.0
  swanlab-cloud:
    image: ${prefix}swanlab-cloud:v3.3.0
  swanlab-next:
    image: ${prefix}swanlab-next:v3.3.0
EOF
}

echo "== Case 1: Tencent CCR layout migrates to repo.swanlab.cn =="
CCR="${TMP_DIR}/ccr.yaml"
make_compose "ccr.ccs.tencentyun.com/self-hosted/" \
    "redis-stack-server" "clickhouse" "logrotate:v1" "minio" "minio-mc" > "${CCR}"
run_migrate "${CCR}"
assert_no_legacy "${CCR}"
assert_expected_images "${CCR}"
# 幂等：重复执行不再变化
cp "${CCR}" "${CCR}.before"
run_migrate "${CCR}"
if ! cmp -s "${CCR}" "${CCR}.before"; then
    echo "::error::migrate_registry is not idempotent on CCR layout" >&2
    exit 1
fi
echo "   ✅ pass"

echo "== Case 2: early ACR layout (legacy repo names) migrates to current layout =="
EARLY="${TMP_DIR}/early-acr.yaml"
make_compose "repo.swanlab.cn/self-hosted/" \
    "redis-stack-server" "clickhouse" "logrotate:v1" "minio" "minio-mc" > "${EARLY}"
run_migrate "${EARLY}"
assert_no_legacy "${EARLY}"
assert_expected_images "${EARLY}"
echo "   ✅ pass"

echo "== Case 3: current ACR layout is left untouched (new installs / idempotency) =="
CURRENT="${TMP_DIR}/current.yaml"
make_compose "repo.swanlab.cn/self-hosted/" \
    "redis-stack" "clickhouse-server" "logrotate:1.0" "minio/minio" "minio/mc" > "${CURRENT}"
cp "${CURRENT}" "${CURRENT}.before"
run_migrate "${CURRENT}"
if ! cmp -s "${CURRENT}" "${CURRENT}.before"; then
    echo "::error::migrate_registry unexpectedly modified an already-current layout" >&2
    diff -u "${CURRENT}.before" "${CURRENT}" >&2 || true
    exit 1
fi
echo "   ✅ pass"

echo "== Case 4: custom Harbor domain is left untouched (air-gapped users) =="
HARBOR="${TMP_DIR}/harbor.yaml"
make_compose "harbor.example.com/swanlab/self-hosted/" \
    "redis-stack-server" "clickhouse" "logrotate:v1" "minio" "minio-mc" > "${HARBOR}"
cp "${HARBOR}" "${HARBOR}.before"
run_migrate "${HARBOR}"
if ! cmp -s "${HARBOR}" "${HARBOR}.before"; then
    echo "::error::migrate_registry unexpectedly rewrote a custom Harbor layout" >&2
    diff -u "${HARBOR}.before" "${HARBOR}" >&2 || true
    exit 1
fi
echo "   ✅ pass"

echo "All migrate_registry tests passed."

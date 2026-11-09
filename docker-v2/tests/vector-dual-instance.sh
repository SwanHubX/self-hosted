#!/bin/bash
# Real Docker integration: retain test data; never change the existing deployment or database schema.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
TEMPLATE="${ROOT}/docker-v2"
source "${TEMPLATE}/lib.sh"
export TERM=dumb
ENV_FILE="${VECTOR_TEST_ENV_FILE:-${TEMPLATE}/swanlab/.env}"
[ -f "$ENV_FILE" ] || die "设置 VECTOR_TEST_ENV_FILE 指向已有本地测试部署的 .env"
ENV_FILE=$(cd "$(dirname "$ENV_FILE")" && pwd -P)/$(basename "$ENV_FILE")
RUN_ID="vector-dual-$(date -u +%Y%m%d%H%M%S)"
export VECTOR_TEST_ROOT="${ROOT}/.work/vector-dual/${RUN_ID}"
export COMPOSE_PROJECT_NAME=vector-dual-test
export COMPOSE_ENV_FILES="$ENV_FILE"
export COMPOSE_FILE="${TEMPLATE}/docker-compose.yaml:${TEMPLATE}/tests/vector-dual.compose.yaml"
CH_ID=$(docker ps -q --filter label=com.docker.compose.project=swanlab --filter label=com.docker.compose.service=clickhouse)
[ -n "$CH_ID" ] && [ "$(printf '%s\n' "$CH_ID" | wc -l)" -eq 1 ] || die "需要已有本地测试 ClickHouse"
export VECTOR_TEST_CLICKHOUSE_HOST
VECTOR_TEST_CLICKHOUSE_HOST=$(docker inspect --format '{{.Name}}' "$CH_ID")
VECTOR_TEST_CLICKHOUSE_HOST=${VECTOR_TEST_CLICKHOUSE_HOST#/}
mkdir -p "${VECTOR_TEST_ROOT}"

compose() { (cd "$TEMPLATE" && docker compose "$@"); }
legacy() {
  (cd "$TEMPLATE" && COMPOSE_FILE="${TEMPLATE}/tests/vector-legacy.compose.yaml" docker compose "$@")
}
query() {
  printf '%s\n' "$1" | docker exec -i "$CH_ID" bash -ec \
    'clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD"'
}
finish() {
  local result=$? id
  trap - EXIT
  for service in vector-1 vector-2; do
    id=$(compose ps -aq "$service" 2>/dev/null) || true
    [ -z "$id" ] || docker unpause "$id" >/dev/null 2>&1 || true
  done
  compose logs --no-color gateway vector-1 vector-2 >"${VECTOR_TEST_ROOT}/containers.log" 2>&1 || true
  if [ "$result" -eq 0 ]; then
    compose stop --timeout 10 gateway vector-1 vector-2 >/dev/null 2>&1 || true
    legacy stop --timeout 10 vector >/dev/null 2>&1 || true
  else
    printf 'Failed test containers retained for inspection: vector-dual-test\n'
  fi
  printf 'Test data and logs retained: %s\n' "$VECTOR_TEST_ROOT"
  exit "$result"
}
trap finish EXIT

wait_healthy() {
  local service="$1" id status attempt
  for attempt in $(seq 1 45); do
    id=$(compose ps -aq "$service")
    status=$(docker inspect --format '{{.State.Status}}:{{.State.Health.Status}}' "$id")
    [ "$status" = running:healthy ] && return 0
    case "$status" in exited:*|dead:*) die "${service} 启动失败" ;; esac
    sleep 2
  done
  die "${service} 健康等待超时"
}
ping_gateway() {
  compose exec -T gateway wget -q -T 5 -O - http://127.0.0.1:8080/vector/ping
}
post() {
  local phase="$1" index="$2" target="${3:-http://127.0.0.1:8080/vector/}" body
  body=$(printf '[{"type":"scalar","time":"2026-11-09T00:00:00.000Z","uid":1,"projectId":"vector-dual-test","experimentId":"%s","epoch":1,"key":"%s","step":%s,"value":1},{"type":"media","time":"2026-11-09T00:00:00.000Z","uid":1,"projectId":"vector-dual-test","experimentId":"%s","epoch":1,"key":"%s","step":%s,"indexing":0,"value":"validation","other":{}},{"type":"log","time":"2026-11-09T00:00:00.000Z","uid":1,"projectId":"vector-dual-test","experimentId":"%s","epoch":1,"level":"INFO","message":"%s-%s","tag":"validation"}]' \
    "$RUN_ID" "$phase" "$index" "$RUN_ID" "$phase" "$index" "$RUN_ID" "$phase" "$index")
  compose exec -T gateway wget -q -T 20 -O - --post-data "$body" \
    --header 'Content-Type: application/json' "$target" >/dev/null
}
post_many() {
  local index
  for index in $(seq 1 "$2"); do post "$1" "$index"; done
}
reconcile() {
  local expected="$1" attempt counts
  for attempt in $(seq 1 30); do
    counts=$(query "SELECT 'scalar', count(), uniqExact(tuple(key, step)) FROM app.scalar WHERE experimentId='${RUN_ID}' UNION ALL SELECT 'media', count(), uniqExact(tuple(key, step, indexing)) FROM app.media WHERE experimentId='${RUN_ID}' UNION ALL SELECT 'log', count(), uniqExact(message) FROM app.log WHERE experimentId='${RUN_ID}' FORMAT TSV")
    if printf '%s\n' "$counts" | awk -v expected="$expected" 'NF!=3 || $2!=expected || $3!=expected {bad=1} END {exit bad || NR!=3}'; then
      printf '[PASS] Reconciled three tables: %s events each, no duplicates\n' "$expected"
      return 0
    fi
    sleep 2
  done
  printf '%s\n' "$counts"
  for service in vector-1 vector-2; do
    vector_http_get "$TEMPLATE" "$service" 9090 /metrics >"${VECTOR_TEST_ROOT}/failed-${service}.metrics" || true
  done
  die "数据对账失败"
}
received() {
  vector_http_get "$TEMPLATE" "$1" 9090 /metrics | awk \
    '/^vector_component_received_events_total\{/ && /component_id="http_metrics"/ {n+=$2} END {print n+0}'
}

# Render the actual template; overrides change isolation and endpoints, preserving production labels and health checks.
compose config --quiet
compose up -d --no-deps gateway vector-1 vector-2
for service in gateway vector-1 vector-2; do wait_healthy "$service"; done
for attempt in $(seq 1 10); do
  [ "$(ping_gateway 2>/dev/null)" = pong ] && break
  sleep 2
done
[ "$(ping_gateway)" = pong ] || die "内部路由未就绪"
compose exec -T gateway wget -q -T 5 -O - --post-data='' \
  --header 'Content-Type: application/json' http://127.0.0.1:8080/vector >/dev/null
if compose exec -T gateway wget -q -T 5 -O - http://127.0.0.1:8080/vector-other/ping >/dev/null 2>&1; then
  die "路由错误地匹配了 /vector-other"
fi
if compose exec -T gateway wget -q -T 5 -O - http://127.0.0.1/vector/ping >/dev/null 2>&1; then
  die "Vector 路由被暴露到 web 入口"
fi
mount1=$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/var/lib/vector"}}{{.Source}}{{end}}{{end}}' "$(compose ps -q vector-1)")
mount2=$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/var/lib/vector"}}{{.Source}}{{end}}{{end}}' "$(compose ps -q vector-2)")
[ -n "$mount1" ] && [ -n "$mount2" ] && [ "$mount1" != "$mount2" ] || die "缓冲挂载不独立"
printf '[PASS] Cold start, independent mounts, internal routing and path stripping\n'

post_many baseline 12
reconcile 12
sleep 35
[ "$(received vector-1)" -gt 0 ] && [ "$(received vector-2)" -gt 0 ] || die "流量未分摊到两个实例"
printf '[PASS] Both Vector instances received events\n'

compose stop vector-2
sleep 8
post_many stopped 4
reconcile 16
compose start vector-2
wait_healthy vector-2
printf '[PASS] Stopped instance removed and recovered\n'

docker pause "$(compose ps -q vector-2)" >/dev/null
sleep 12
for attempt in 1 2 3 4; do [ "$(ping_gateway)" = pong ] || die "无响应实例未被摘除"; done
post_many paused 4
reconcile 20
docker unpause "$(compose ps -q vector-2)" >/dev/null
printf '[PASS] Active HTTP health check removed an unresponsive process\n'

# Simulate a sink outage on the test container, keeping the real ClickHouse deployment unchanged.
V2_ID=$(compose ps -q vector-2)
docker network disconnect "${VECTOR_TEST_DATA_NETWORK:-swanlab-net}" "$V2_ID"
post wal 1 http://vector-2:8686/ &
POST_PID=$!
sleep 8
if vector_http_get "$TEMPLATE" vector-2 9090 /metrics | vector_buffers_empty; then
  # A fresh metrics snapshot is needed before deciding that no WAL accumulated.
  sleep 35
  vector_http_get "$TEMPLATE" vector-2 9090 /metrics | vector_buffers_empty && die "未观察到 WAL 积压"
fi
if wait_vector_buffers_drained "$TEMPLATE" 0; then die "下游不可用时错误地允许回滚"; fi
compose kill -s SIGKILL vector-2
wait "$POST_PID" || true
docker network connect "${VECTOR_TEST_DATA_NETWORK:-swanlab-net}" "$V2_ID"
compose start vector-2
wait_healthy vector-2
reconcile 21
printf '[PASS] WAL survived a process crash; unavailable downstream blocks rollback\n'

# An old service and its replacement reuse the same directory with one writer at a time.
compose stop vector-1
legacy up -d --no-deps vector
sleep 12
legacy_id=$(legacy ps -q vector)
legacy_mount=$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/var/lib/vector"}}{{.Source}}{{end}}{{end}}' "$legacy_id")
[ "$legacy_mount" = "$mount1" ] || die "旧数据目录未被继承"
compose start vector-1
sleep 6
[ "$(docker inspect --format '{{.State.Status}}' "$(compose ps -aq vector-1)")" = exited ] \
  || die "共享 WAL 目录未触发 writer 排他锁"
printf '[PASS] A second writer on the same WAL directory failed to start\n'
docker network disconnect "${VECTOR_TEST_DATA_NETWORK:-swanlab-net}" "$legacy_id"
post legacy-wal 1 http://vector:8686/ &
LEGACY_POST_PID=$!
sleep 35
if COMPOSE_FILE="${TEMPLATE}/tests/vector-legacy.compose.yaml" \
    vector_http_get "$TEMPLATE" vector 9090 /metrics | vector_buffers_empty; then
  die "旧 writer 未产生待继承的 WAL"
fi
legacy kill -s SIGKILL vector
wait "$LEGACY_POST_PID" || true
COMPOSE_FILE="${TEMPLATE}/tests/vector-legacy.compose.yaml" stop_vector_services "$TEMPLATE"
[ "$(docker inspect --format '{{.State.Running}}' "$legacy_id")" = false ] || die "旧 writer 未停止"
compose start vector-1 vector-2
wait_healthy vector-1
wait_healthy vector-2
reconcile 22
wait_vector_buffers_drained "$TEMPLATE" 105
post_many inherited 2
reconcile 24
wait_vector_buffers_drained "$TEMPLATE" 105
printf '[PASS] Legacy writer stopped before replacement; rollback drain checks passed\n'

# A second cold start verifies persistent data and repeatable router discovery.
compose stop gateway vector-1 vector-2
compose start gateway vector-1 vector-2
for service in gateway vector-1 vector-2; do wait_healthy "$service"; done
sleep 8
post_many restarted 2
reconcile 26
printf '[PASS] Repeated cold start and final reconciliation\n'

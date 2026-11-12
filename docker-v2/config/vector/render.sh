#!/bin/bash
# Vector 0.57 起默认关闭配置内环境变量插值；启动前把 ${CLICKHOUSE_*} 渲染为具体值。
# 使用 bash 字面替换，密码中的 $、/、引号等不会被解释；& 和 \ 需先转义。
set -euo pipefail

SRC=${VECTOR_CONFIG_TEMPLATE:-/etc/vector/vector.yaml}
DST=${VECTOR_CONFIG_RENDERED:-/tmp/vector.yaml}

: "${CLICKHOUSE_HOST?CLICKHOUSE_HOST 未设置}"
: "${CLICKHOUSE_PORT?CLICKHOUSE_PORT 未设置}"
: "${CLICKHOUSE_USER?CLICKHOUSE_USER 未设置}"
: "${CLICKHOUSE_DB?CLICKHOUSE_DB 未设置}"
: "${CLICKHOUSE_PASSWORD?CLICKHOUSE_PASSWORD 未设置}"

escape() {
  local v=$1
  v=${v//\\/\\\\}
  v=${v//&/\\&}
  printf '%s' "$v"
}

E_HOST=$(escape "$CLICKHOUSE_HOST")
E_PORT=$(escape "$CLICKHOUSE_PORT")
E_USER=$(escape "$CLICKHOUSE_USER")
E_PASSWORD=$(escape "$CLICKHOUSE_PASSWORD")
E_DB=$(escape "$CLICKHOUSE_DB")

while IFS= read -r line || [ -n "$line" ]; do
  line=${line//'${CLICKHOUSE_HOST}'/$E_HOST}
  line=${line//'${CLICKHOUSE_PORT}'/$E_PORT}
  line=${line//'${CLICKHOUSE_USER}'/$E_USER}
  line=${line//'${CLICKHOUSE_DB}'/$E_DB}
  # 密码最后替换，避免密码中恰好包含其他占位符时被二次替换
  line=${line//'${CLICKHOUSE_PASSWORD}'/$E_PASSWORD}
  printf '%s\n' "$line"
done <"$SRC" >"$DST"

exec /usr/bin/vector --config "$DST" "$@"

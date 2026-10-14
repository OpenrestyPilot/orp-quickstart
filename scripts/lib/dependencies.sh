#!/usr/bin/env bash

quickstart_load_env() {
  local env_file=$1 line key value
  [[ -f "$env_file" ]] || { printf '没有找到配置文件：%s\n' "$env_file" >&2; return 1; }

  while IFS= read -r line || [[ -n "$line" ]]; do
    line=${line%$'\r'}
    line=${line#"${line%%[![:space:]]*}"}
    [[ -z "$line" || "$line" == \#* ]] && continue
    line=${line#export }
    [[ "$line" == *=* ]] || continue
    key=${line%%=*}
    value=${line#*=}
    key=${key%"${key##*[![:space:]]}"}
    value=${value#"${value%%[![:space:]]*}"}
    value=${value%"${value##*[![:space:]]}"}
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    if [[ ${#value} -ge 2 && ( "${value:0:1}" == '"' || "${value:0:1}" == "'" ) && "${value: -1}" == "${value:0:1}" ]]; then
      value=${value:1:${#value}-2}
    fi
    if ! printenv "$key" >/dev/null 2>&1; then
      export "$key=$value"
    fi
  done < "$env_file"
}

quickstart_fail() {
  printf '启动检查失败：%s\n' "$1" >&2
  exit 1
}

quickstart_parse_endpoint() {
  local endpoint=$1 default_port=$2 rest
  if [[ "$endpoint" == \[* ]]; then
    QUICKSTART_ENDPOINT_HOST=${endpoint#\[}
    QUICKSTART_ENDPOINT_HOST=${QUICKSTART_ENDPOINT_HOST%%\]*}
    rest=${endpoint#*\]}
    if [[ "$rest" == :* ]]; then QUICKSTART_ENDPOINT_PORT=${rest#:}; else QUICKSTART_ENDPOINT_PORT=$default_port; fi
  elif [[ "$endpoint" == *:* ]]; then
    QUICKSTART_ENDPOINT_HOST=${endpoint%:*}
    QUICKSTART_ENDPOINT_PORT=${endpoint##*:}
  else
    QUICKSTART_ENDPOINT_HOST=$endpoint
    QUICKSTART_ENDPOINT_PORT=$default_port
  fi

  [[ -n "$QUICKSTART_ENDPOINT_HOST" && "$QUICKSTART_ENDPOINT_PORT" =~ ^[0-9]{1,5}$ ]] || return 1
  (( 10#$QUICKSTART_ENDPOINT_PORT >= 1 && 10#$QUICKSTART_ENDPOINT_PORT <= 65535 )) || return 1
}

quickstart_check_endpoint() {
  local label=$1 address=$2 default_port=$3
  quickstart_parse_endpoint "$address" "$default_port" || quickstart_fail "$label 地址格式无效：$address"
  nc -z -w 3 "$QUICKSTART_ENDPOINT_HOST" "$QUICKSTART_ENDPOINT_PORT" >/dev/null 2>&1 \
    || quickstart_fail "$label 无法连接：$QUICKSTART_ENDPOINT_HOST:$QUICKSTART_ENDPOINT_PORT。请确认服务已启动且 .env 地址正确。"
  printf '%s 已连接：%s:%s\n' "$label" "$QUICKSTART_ENDPOINT_HOST" "$QUICKSTART_ENDPOINT_PORT"
}

quickstart_check_demo_backend_ports() {
  if command -v docker >/dev/null 2>&1 && docker ps --filter name=orp-demo-traffic-generator --filter status=running -q | grep -q .; then
    return 0
  fi
  python3 - <<'PY' || quickstart_fail '演示后端端口 19000–19002 已被占用。请关闭占用进程后重试。'
import socket
occupied = []
for port in (19000, 19001, 19002):
    sock = socket.socket()
    try:
        sock.bind(("0.0.0.0", port))
    except OSError:
        occupied.append(port)
    finally:
        sock.close()
if occupied:
    print(", ".join(map(str, occupied)))
    raise SystemExit(1)
PY
}

quickstart_check_dependencies() {
  [[ -n "${ORP_DB_URL:-}" ]] || quickstart_fail '.env 未配置 ORP_DB_URL。'
  [[ "$ORP_DB_URL" == jdbc:mysql://*/* ]] || quickstart_fail 'ORP_DB_URL 必须是 jdbc:mysql://host:port/database 格式。'
  [[ -n "${ORP_DB_USERNAME:-}" ]] || quickstart_fail '.env 未配置 ORP_DB_USERNAME。'
  [[ -n "${ORP_DB_PASSWORD:-}" ]] || quickstart_fail '.env 未配置 ORP_DB_PASSWORD。'
  [[ -n "${ORP_KAFKA_BOOTSTRAP_SERVERS:-}" ]] || quickstart_fail '.env 未配置 ORP_KAFKA_BOOTSTRAP_SERVERS。'
  [[ -n "${ORP_KAFKA_TOPIC:-}" ]] || quickstart_fail '.env 未配置 ORP_KAFKA_TOPIC。'
  [[ -n "${ORP_REDIS_ADDR:-}" ]] || quickstart_fail '.env 未配置 ORP_REDIS_ADDR。'
  command -v nc >/dev/null 2>&1 || quickstart_fail '缺少 nc 命令，无法检查 MySQL、Kafka 和 Redis 连接。'

  local db_authority broker
  db_authority=${ORP_DB_URL#jdbc:mysql://}
  db_authority=${db_authority%%/*}
  quickstart_check_endpoint 'MySQL' "$db_authority" 3306
  quickstart_check_endpoint 'Redis' "$ORP_REDIS_ADDR" 6379

  local -a brokers
  local broker_count=0
  IFS=',' read -r -a brokers <<< "$ORP_KAFKA_BOOTSTRAP_SERVERS"
  for broker in "${brokers[@]}"; do
    broker=${broker//[[:space:]]/}
    [[ -n "$broker" ]] || continue
    quickstart_check_endpoint 'Kafka' "$broker" 9092
    ((broker_count += 1))
  done
  (( broker_count > 0 )) || quickstart_fail 'ORP_KAFKA_BOOTSTRAP_SERVERS 未包含有效 broker 地址。'
}

quickstart_configure_filebeat_brokers() {
  local root=${1:?必须指定 Quickstart 项目目录}
  local broker first=true hosts='['
  local -a brokers
  if [[ -z "${FILEBEAT_KAFKA_HOSTS:-}" || "$FILEBEAT_KAFKA_HOSTS" == '["127.0.0.1:9092"]' ]]; then
    IFS=',' read -r -a brokers <<< "${ORP_KAFKA_BOOTSTRAP_SERVERS:-}"
    for broker in "${brokers[@]}"; do
      broker=${broker//[[:space:]]/}
      [[ -n "$broker" ]] || continue
      [[ "$broker" != *'"'* && "$broker" != *'\'* ]] || quickstart_fail 'Kafka broker 地址不能包含引号或反斜杠。'
      if [[ "$first" == true ]]; then first=false; else hosts+=','; fi
      hosts+="\"$broker\""
    done
    hosts+=']'
  else
    hosts=$FILEBEAT_KAFKA_HOSTS
  fi
  export FILEBEAT_KAFKA_HOSTS="$hosts"
  [[ -n "${FILEBEAT_KAFKA_TOPIC:-}" ]] || export FILEBEAT_KAFKA_TOPIC="${ORP_KAFKA_TOPIC:-}"
  python3 - "$root" "$FILEBEAT_KAFKA_HOSTS" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
try:
    brokers = json.loads(sys.argv[2])
except json.JSONDecodeError as exc:
    raise SystemExit(f"FILEBEAT_KAFKA_HOSTS 必须是 JSON 字符串列表：{exc}")
if not isinstance(brokers, list) or not brokers or any(not isinstance(item, str) or not item for item in brokers):
    raise SystemExit("FILEBEAT_KAFKA_HOSTS 必须是非空的 JSON broker 字符串列表")

template = (root / "deploy/filebeat/filebeat.yml").read_text(encoding="utf-8")
yaml_hosts = "  hosts:\n" + "".join(f"    - {json.dumps(item)}\n" for item in brokers)
template = template.replace("  hosts: ${FILEBEAT_KAFKA_HOSTS}\n", yaml_hosts)
if "hosts: ${FILEBEAT_KAFKA_HOSTS}" in template:
    raise SystemExit("Filebeat 配置模板缺少预期的 Kafka hosts 配置位置")
output = root / "runtime/filebeat/filebeat.yml"
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text(template, encoding="utf-8")
output.chmod(0o644)
PY
}

quickstart_load_demo_identity() {
  local env_file=$1
  unset QUICKSTART_RUNTIME_CENTER_ID FILEBEAT_EAST_1_NODE_ID FILEBEAT_EAST_2_NODE_ID FILEBEAT_EAST_3_NODE_ID
  quickstart_load_env "$env_file"
}

quickstart_sync_demo_bootstrap_configs() {
  local root=$1 source="$1/deploy/openresty/nginx.conf" directory
  local changed=false
  for directory in runtime/native-config runtime/native-config-east-2 runtime/native-config-east-3; do
    mkdir -p "$root/$directory/bootstrap"
    if ! cmp -s "$source" "$root/$directory/bootstrap/nginx.conf"; then
      cp "$source" "$root/$directory/bootstrap/nginx.conf"
      changed=true
    fi
  done
  export QUICKSTART_DEMO_BOOTSTRAP_UPDATED=$changed
}

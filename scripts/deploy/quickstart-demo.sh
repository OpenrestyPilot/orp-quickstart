#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
source "$root/scripts/lib/dependencies.sh"
quickstart_load_env "$root/.env"

backend_dir=${ORP_BACKEND_DIR:-"$root/openresty-plus/orp-backend"}
[[ -d "$backend_dir" ]] || backend_dir="$root/../openresty-plus/openresty-plus/orp-backend"
if [[ -d "$backend_dir" ]]; then backend_dir=$(cd "$backend_dir" && pwd); fi
base_url=${QUICKSTART_CONTROL_PLANE_URL:-http://127.0.0.1:8081}
admin_username=${OPENRESTY_ADMIN_USERNAME:-${ADMIN_USERNAME:-admin}}
admin_password=${OPENRESTY_ADMIN_PASSWORD:-${ADMIN_PASSWORD:-}}
center_code=${QUICKSTART_DEMO_CENTER_CODE:-quickstart-local}
center_name=${QUICKSTART_DEMO_CENTER_NAME:-Quickstart 本地演示中心}

[[ -n "$admin_password" ]] || quickstart_fail '缺少管理员密码，无法自动登记节点和准备演示数据。'
command -v python3 >/dev/null 2>&1 || quickstart_fail '自动登记需要 python3。'
export QUICKSTART_ADMIN_USERNAME="$admin_username"
export QUICKSTART_ADMIN_PASSWORD="$admin_password"
export QUICKSTART_NODE_AGENT_DIR="$root/secrets/node-agent"

python3 - "$base_url" "$center_code" "$center_name" <<'PY'
import json
import hashlib
import os
import ssl
import sys
import time
import urllib.error
import urllib.request

base, center_code, center_name = sys.argv[1:]
username = os.environ["QUICKSTART_ADMIN_USERNAME"]
password = os.environ["QUICKSTART_ADMIN_PASSWORD"]

def request(path, token=None, data=None, method=None):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    payload = None if data is None else json.dumps(data).encode()
    req = urllib.request.Request(base.rstrip("/") + path, payload, headers,
                                 method=method or ("POST" if data is not None else "GET"))
    with urllib.request.urlopen(req, timeout=5) as response:
        result = json.load(response)
    if result.get("code") not in (None, 0):
        raise RuntimeError(result.get("message", "接口请求失败"))
    return result.get("data")

last_error = None
for _ in range(60):
    try:
        token = request("/api/auth/login", data={"username": username, "password": password})["accessToken"]
        break
    except (OSError, urllib.error.URLError, KeyError, RuntimeError) as exc:
        last_error = exc
        time.sleep(2)
else:
    raise SystemExit(f"管理 API 未就绪或登录失败：{last_error}")

centers = request("/api/orp/centers?page=1&pageSize=200", token)["items"]
center = next((item for item in centers if item.get("code") == center_code), None)
if center is None:
    center = request("/api/orp/centers", token, {"code": center_code, "name": center_name, "enabled": True})
center_legacy_id = center.get("legacyId")
if not center_legacy_id:
    raise SystemExit("演示中心缺少 legacyId，无法关联底层 OpenResty 实例")
center_id = center["id"]
nodes = request("/api/orp/nodes?page=1&pageSize=200", token)["items"]
for name, service_port, control_port in (
    ("openresty-east-1", 18080, 18081),
    ("openresty-east-2", 18180, 18181),
    ("openresty-east-3", 18280, 18281),
):
    endpoint = f"http://127.0.0.1:{control_port}"
    existing = next((item for item in nodes if item.get("name") == name), None)
    if existing:
        if (str(existing.get("centerId")) not in (str(center_id), str(center_legacy_id))
                or existing.get("host") != "127.0.0.1"
                or int(existing.get("servicePort", 0)) != service_port):
            raise SystemExit(f"节点 {name} 已存在，但中心或控制端点与 quickstart 配置不匹配")
        if existing.get("controlEndpoint") != endpoint:
            payload = {
                key: value for key, value in existing.items()
                if key not in {"id", "createdAt", "updatedAt", "centerName", "healthStatus",
                               "healthRule", "lastCheckedAt", "lastLatencyMs", "controlApiUrl"}
            }
            payload["controlEndpoint"] = endpoint
            request(f"/api/orp/nodes/{existing['id']}", token, payload, method="PUT")
            print(f"已配置节点受控发布通道：{name} -> {endpoint}")
        else:
            print(f"节点已接入并配置受控发布通道：{name}（ID {existing['id']}）")
        continue
    created = request("/api/orp/nodes", token, {
        "centerId": center_id, "name": name, "host": "127.0.0.1",
        "servicePort": service_port, "controlEndpoint": endpoint,
    })
    print(f"节点已登记：{name}（ID {created['id']}）")

# Bind each distinct leaf certificate to its corresponding managed node. This
# makes mTLS identity enrollment repeatable without allowing node API payloads
# to choose Agent identity fields.
nodes = request("/api/orp/nodes?page=1&pageSize=200", token)["items"]
agent_root = os.environ.get("QUICKSTART_NODE_AGENT_DIR", "")
for name in ("openresty-east-1", "openresty-east-2", "openresty-east-3"):
    node = next((item for item in nodes if item.get("name") == name), None)
    if node is None:
        raise SystemExit(f"Agent 登记失败：节点 {name} 不存在")
    cert_file = os.path.join(agent_root, name, "pki", "node.crt")
    with open(cert_file, encoding="ascii") as source:
        der = ssl.PEM_cert_to_DER_cert(source.read())
    fingerprint = hashlib.sha256(der).hexdigest()
    request(f"/api/orp/nodes/{node['id']}/agent/certificate", token,
            {"nodeId": name, "certificateFingerprint": fingerprint}, method="PUT")
    print(f"已登记节点 Agent mTLS 身份：{name}")
PY

if [[ "${QUICKSTART_SEED_ALERTS:-true}" == true && -d "$backend_dir" ]]; then
  [[ -x "$(command -v go || true)" ]] || quickstart_fail '灌入告警演示数据需要 Go；请安装 Go，或设置 QUICKSTART_SEED_ALERTS=false 跳过数据准备。'
  printf '准备告警演示数据……\n'
  OPENRESTY_ENV_FILE="$root/.env" OPENRESTY_ADMIN_USERNAME="$admin_username" \
    OPENRESTY_ADMIN_PASSWORD="$admin_password" OPENRESTY_DATA_KEY="${OPENRESTY_DATA_KEY:-${DATA_KEY:-}}" \
    OPENRESTY_DB_URL="${OPENRESTY_DB_URL:-}" OPENRESTY_DB_USERNAME="${OPENRESTY_DB_USERNAME:-}" \
    OPENRESTY_DB_PASSWORD="${OPENRESTY_DB_PASSWORD:-}" OPENRESTY_REDIS_ADDR="${OPENRESTY_REDIS_ADDR:-}" \
    OPENRESTY_REDIS_PASSWORD="${OPENRESTY_REDIS_PASSWORD:-}" OPENRESTY_REDIS_DB="${OPENRESTY_REDIS_DB:-}" \
    OPENRESTY_KAFKA_BOOTSTRAP_SERVERS="${OPENRESTY_KAFKA_BOOTSTRAP_SERVERS:-}" \
    OPENRESTY_KAFKA_TOPIC="${OPENRESTY_KAFKA_TOPIC:-}" \
    "$backend_dir/scripts/seed-alert-demo.sh"
elif [[ "${QUICKSTART_SEED_ALERTS:-true}" == true ]]; then
  quickstart_fail '未找到本地 Go 后端源码，无法自动灌入告警演示数据；请设置 ORP_BACKEND_DIR 指向后端源码。'
fi

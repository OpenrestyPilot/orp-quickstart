#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
agent_source=${ORP_NODE_AGENT_DIR:-"$root/../orp-node-agent"}
agent_build_context="$root/deploy/openresty/orp-node-agent"
runtime="$root/secrets/node-agent"
downloaded_source="$root/runtime/orp-node-agent-source"
pki="$runtime/pki"
env_file="$root/.env"

for tool in openssl; do
  command -v "$tool" >/dev/null 2>&1 || { printf '缺少命令：%s\n' "$tool" >&2; exit 1; }
done
if [[ ! -d "$agent_source/cmd/orp-node-agent" ]]; then
  command -v git >/dev/null 2>&1 || { printf '缺少命令：git（需要获取 orp-node-agent 源码）。\n' >&2; exit 1; }
  if [[ ! -d "$downloaded_source/.git" ]]; then
    rm -rf "$downloaded_source"
    git clone --depth 1 --branch "${ORP_NODE_AGENT_REF:-main}" \
      https://github.com/ORP/orp-node-agent.git "$downloaded_source"
  fi
  agent_source="$downloaded_source"
fi

mkdir -p "$pki"
chmod 700 "$runtime" "$pki"
if [[ ! -s "$pki/ca.key" || ! -s "$pki/ca.crt" ]]; then
  openssl genrsa -out "$pki/ca.key" 3072
  openssl req -x509 -new -key "$pki/ca.key" -sha256 -days 3650 \
    -subj "/CN=ORP Quickstart Demo Agent CA" -out "$pki/ca.crt"
fi
if [[ ! -s "$pki/server.key" || ! -s "$pki/server.crt" ]]; then
  openssl req -new -newkey rsa:3072 -nodes -keyout "$pki/server.key" \
    -subj "/CN=orp-control-agent-local" -out "$pki/server.csr"
  printf 'subjectAltName=IP:127.0.0.1\nextendedKeyUsage=serverAuth\nkeyUsage=digitalSignature,keyEncipherment\n' > "$pki/server.ext"
  openssl x509 -req -in "$pki/server.csr" -CA "$pki/ca.crt" -CAkey "$pki/ca.key" \
    -CAcreateserial -out "$pki/server.crt" -days 825 -sha256 -extfile "$pki/server.ext"
  rm -f "$pki/server.csr" "$pki/server.ext"
fi
chmod 600 "$pki/ca.key" "$pki/server.key"
chmod 644 "$pki/ca.crt" "$pki/server.crt"

for node in openresty-east-1 openresty-east-2 openresty-east-3; do
  node_dir="$runtime/$node"
  mkdir -p "$node_dir/pki"
  if [[ ! -s "$node_dir/pki/node.key" || ! -s "$node_dir/pki/node.crt" ]]; then
    openssl req -new -newkey rsa:3072 -nodes -keyout "$node_dir/pki/node.key" \
      -subj "/CN=$node" -out "$node_dir/pki/node.csr"
    printf 'extendedKeyUsage=clientAuth\nkeyUsage=digitalSignature,keyEncipherment\n' > "$node_dir/pki/node.ext"
    openssl x509 -req -in "$node_dir/pki/node.csr" -CA "$pki/ca.crt" -CAkey "$pki/ca.key" \
      -CAcreateserial -out "$node_dir/pki/node.crt" -days 825 -sha256 -extfile "$node_dir/pki/node.ext"
    rm -f "$node_dir/pki/node.csr" "$node_dir/pki/node.ext"
  fi
  cp "$pki/ca.crt" "$node_dir/pki/server-ca.crt"
  chmod 700 "$node_dir" "$node_dir/pki"
  chmod 600 "$node_dir/pki/node.key"
  chmod 644 "$node_dir/pki/"*.crt
  cat > "$node_dir/config.json" <<JSON
{
  "nodeId": "$node",
  "controlPlaneUrl": "https://127.0.0.1:18443",
  "clientCertFile": "/run/orp-node-agent/pki/node.crt",
  "clientKeyFile": "/run/orp-node-agent/pki/node.key",
  "serverCAFile": "/run/orp-node-agent/pki/server-ca.crt",
  "pollIntervalSeconds": 10,
  "httpTimeoutSeconds": 5,
  "nginxBinary": "/usr/local/openresty/nginx/sbin/openresty",
  "nginxConfig": "/etc/openresty/generated/active/nginx.conf",
  "reloadHelper": "/usr/local/sbin/orp-openresty-reload",
  "stateDir": "/var/lib/orp-node-agent",
  "pidFile": "/var/run/nginx.pid"
}
JSON
  chmod 644 "$node_dir/config.json"
done

# Remove temporary signing requests/extensions left by an interrupted earlier
# preparation. Only the node leaf keys are mounted into their respective nodes.
find "$runtime" \( -name '*.csr' -o -name '*.ext' \) -type f -delete

# Make the Agent source available to Docker without nesting a Git repository.
rm -rf "$agent_build_context"
mkdir -p "$agent_build_context"
cp "$agent_source/go.mod" "$agent_build_context/"
cp -R "$agent_source/cmd" "$agent_source/internal" "$agent_build_context/"

tmp=$(mktemp)
awk -v cert="$pki/server.crt" \
    -v key="$pki/server.key" \
    -v ca="$pki/ca.crt" \
    -v cert_container="/run/orp-node-agent/server.crt" \
    -v key_container="/run/orp-node-agent/server.key" \
    -v ca_container="/run/orp-node-agent/ca.crt" '
  BEGIN { seen_addr=seen_cert=seen_key=seen_ca=0 }
  /^ORP_AGENT_HTTPS_ADDR=/ { print "ORP_AGENT_HTTPS_ADDR=127.0.0.1:18443"; seen_addr=1; next }
  /^ORP_AGENT_TLS_CERT_FILE=/ { print "ORP_AGENT_TLS_CERT_FILE=" cert; seen_cert=1; next }
  /^ORP_AGENT_TLS_KEY_FILE=/ { print "ORP_AGENT_TLS_KEY_FILE=" key; seen_key=1; next }
  /^ORP_AGENT_CLIENT_CA_FILE=/ { print "ORP_AGENT_CLIENT_CA_FILE=" ca; seen_ca=1; next }
  /^ORP_AGENT_TLS_CERT_FILE_CONTAINER=/ { print "ORP_AGENT_TLS_CERT_FILE_CONTAINER=" cert_container; seen_cert_container=1; next }
  /^ORP_AGENT_TLS_KEY_FILE_CONTAINER=/ { print "ORP_AGENT_TLS_KEY_FILE_CONTAINER=" key_container; seen_key_container=1; next }
  /^ORP_AGENT_CLIENT_CA_FILE_CONTAINER=/ { print "ORP_AGENT_CLIENT_CA_FILE_CONTAINER=" ca_container; seen_ca_container=1; next }
  { print }
  END {
    if (!seen_addr) print "ORP_AGENT_HTTPS_ADDR=127.0.0.1:18443"
    if (!seen_cert) print "ORP_AGENT_TLS_CERT_FILE=" cert
    if (!seen_key) print "ORP_AGENT_TLS_KEY_FILE=" key
    if (!seen_ca) print "ORP_AGENT_CLIENT_CA_FILE=" ca
    if (!seen_cert_container) print "ORP_AGENT_TLS_CERT_FILE_CONTAINER=" cert_container
    if (!seen_key_container) print "ORP_AGENT_TLS_KEY_FILE_CONTAINER=" key_container
    if (!seen_ca_container) print "ORP_AGENT_CLIENT_CA_FILE_CONTAINER=" ca_container
  }
' "$env_file" > "$tmp"
cat "$tmp" > "$env_file"
rm -f "$tmp"
chmod 600 "$env_file"
printf '已准备三个节点的独立 Agent mTLS 身份和控制面监听配置。\n'

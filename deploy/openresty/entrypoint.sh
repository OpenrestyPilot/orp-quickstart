#!/bin/sh
set -eu

control_socket=/run/openresty/control.sock
control_bridge_port=${CONTROL_API_BRIDGE_PORT:-81}
runtime_http_port=${RUNTIME_HTTP_PORT:-80}
rm -f "$control_socket"

# Host networking gives each local demo node its own non-conflicting bootstrap port.
if [ "$runtime_http_port" != "80" ] && [ -f /etc/openresty/conf.d/health.conf ]; then
  sed -i "s/listen 80;/listen ${runtime_http_port};/" /etc/openresty/conf.d/health.conf
fi

center_id=${RUNTIME_CENTER_ID:-}
control_plane=${RUNTIME_CONTROL_PLANE_URL:-}
node_registration_enabled=${NODE_REGISTRATION_ENABLED:-true}
node_name=${NODE_NAME:-}
node_host=${NODE_HOST:-127.0.0.1}
node_service_port=${NODE_SERVICE_PORT:-$runtime_http_port}
node_control_api_url=${NODE_CONTROL_API_URL:-http://127.0.0.1:$control_bridge_port}
# A stable path lets a validated release be switched atomically before the
# master receives a reload signal. The bootstrap release is used on first run.
release_root=/etc/openresty/generated
mkdir -p "$release_root/bootstrap" "$release_root/candidates"
if [ ! -f "$release_root/bootstrap/nginx.conf" ]; then
  cp /usr/local/openresty/nginx/conf/nginx.conf "$release_root/bootstrap/nginx.conf"
fi
if [ ! -e "$release_root/active/nginx.conf" ]; then
  rm -f "$release_root/active"
  ln -s "$release_root/bootstrap" "$release_root/active"
fi
set -- -c "$release_root/active/nginx.conf" "$@"

/usr/local/openresty/nginx/sbin/openresty "$@" &
nginx_pid=$!

# The node Agent is enabled only when Quickstart mounts its per-node identity.
# Private key material is copied from the read-only mount into a private tmpfs
# directory and is readable only by the dedicated unprivileged account.
agent_pid=
if [ -f /etc/orp-node-agent/config.json ]; then
  install -d -o orp-agent -g orp-agent -m 0700 /run/orp-node-agent/pki /var/lib/orp-node-agent
  cp /etc/orp-node-agent/config.json /run/orp-node-agent/config.json
  cp /etc/orp-node-agent/pki/* /run/orp-node-agent/pki/
  chown -R orp-agent:orp-agent /run/orp-node-agent /var/lib/orp-node-agent
  chmod 0600 /run/orp-node-agent/pki/*.key
  chmod 0644 /run/orp-node-agent/config.json /run/orp-node-agent/pki/*.crt
  supervise_agent() {
    child=
    stop_agent() {
      [ -n "$child" ] && kill -TERM "$child" 2>/dev/null || true
      [ -n "$child" ] && wait "$child" 2>/dev/null || true
      exit 0
    }
    trap stop_agent INT TERM
    while :; do
      su-exec orp-agent /usr/local/bin/orp-node-agent -config /run/orp-node-agent/config.json &
      child=$!
      wait "$child" || true
      kill -0 "$nginx_pid" 2>/dev/null || return 0
      echo "orp-node-agent exited; restarting it" >&2
      sleep 2
    done
  }
  supervise_agent &
  agent_pid=$!
  echo "Started orp-node-agent for ${node_name:-unnamed node}" >&2
fi

for _ in $(seq 1 50); do
  [ -S "$control_socket" ] && break
  sleep 0.1
done

if [ ! -S "$control_socket" ]; then
  echo "Control API Unix socket was not created" >&2
  kill "$nginx_pid" 2>/dev/null || true
  exit 1
fi

# The TCP endpoint is only attached to the private container network. Socat is
# deliberately kept outside the Nginx worker model: workers never need access
# to the root-owned Control API socket.
socat TCP-LISTEN:"$control_bridge_port",reuseaddr,fork UNIX-CONNECT:"$control_socket" &
socat_pid=$!

# Each node owns its registration lifecycle.  This replaces the separate
# Compose registration container and only registers the explicitly configured
# node identity once the local service and Control API bridge are available.
register_self() {
  [ "$node_registration_enabled" = "true" ] || return 0
  [ -n "$center_id" ] && [ -n "$control_plane" ] && [ -n "$node_name" ] || return 0
  nodes_url="${control_plane%/}/api/centers/${center_id}/nodes"
  payload=$(printf '{"name":"%s","host":"%s","servicePort":%s,"controlApiUrl":"%s"}' "$node_name" "$node_host" "$node_service_port" "$node_control_api_url")
  for _ in $(seq 1 30); do
    if curl -fsS "$nodes_url" | grep -Fq '"name":"'"$node_name"'"'; then
      return 0
    fi
    if curl -fsS -X POST "$nodes_url" -H 'Content-Type: application/json' --data "$payload" >/dev/null; then
      echo "Registered OpenResty node: $node_name" >&2
      return 0
    fi
    sleep 2
  done
  echo "OpenResty node registration failed after retries: $node_name" >&2
  return 1
}
register_self &
registration_pid=$!

terminate() {
  kill -TERM "$registration_pid" "$socat_pid" "$nginx_pid" ${agent_pid:+"$agent_pid"} 2>/dev/null || true
}
trap terminate INT TERM

wait "$nginx_pid"
status=$?
if [ -n "$agent_pid" ]; then kill "$agent_pid" 2>/dev/null || true; wait "$agent_pid" 2>/dev/null || true; fi
kill "$registration_pid" 2>/dev/null || true
kill "$socat_pid" 2>/dev/null || true
wait "$socat_pid" 2>/dev/null || true
wait "$registration_pid" 2>/dev/null || true
exit "$status"

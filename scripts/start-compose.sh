#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/scripts/lib/dependencies.sh"
env_file="$root/.env"
compose=(docker compose --env-file "$env_file" -f "$root/docker-compose.yaml" --project-directory "$root")

[[ -f "$env_file" ]] || quickstart_fail '没有找到 .env。请先运行 scripts/init-compose-env.sh 并填写配置。'
quickstart_load_env "$env_file"

with_demos=${QUICKSTART_START_DEMOS:-false}
with_traffic=${QUICKSTART_START_TRAFFIC_GENERATOR:-false}
while (($#)); do
  case "$1" in
    --with-demos) with_demos=true ;;
    --without-demos) with_demos=false ;;
    --with-traffic) with_traffic=true ;;
    --without-traffic) with_traffic=false ;;
    *) quickstart_fail "不支持的参数：$1（可用 --with-demos、--without-demos、--with-traffic、--without-traffic）" ;;
  esac
  shift
done

# The generator targets the three demo nodes, so enabling it also enables them.
[[ "$with_traffic" == true ]] && with_demos=true
[[ "$with_traffic" != true ]] || quickstart_check_demo_backend_ports

[[ -n "${ORP_ADMIN_USERNAME:-}" ]] || quickstart_fail '.env 未配置 ORP_ADMIN_USERNAME。'
[[ -n "${ORP_ADMIN_PASSWORD:-}" ]] || quickstart_fail '.env 未配置 ORP_ADMIN_PASSWORD。'
[[ "${ORP_DATA_KEY:-}" =~ ^[[:xdigit:]]{64}$ ]] || quickstart_fail 'ORP_DATA_KEY 必须是 64 位十六进制字符串。'
[[ -n "${ORP_IMAGE:-}" ]] || quickstart_fail '.env 未配置 ORP_IMAGE。'
quickstart_check_dependencies
quickstart_configure_filebeat_brokers "$root"

if [[ "$with_demos" == true ]]; then
  "$root/scripts/deploy/prepare-node-agent.sh"
  quickstart_load_env "$env_file"
  printf '构建包含 orp-node-agent 的演示节点镜像……\n'
  docker build --pull -t "${RUNTIME_IMAGE}:${IMAGE_TAG:-latest}" \
    -f "$root/deploy/openresty/Dockerfile.control-api" "$root/deploy/openresty"
  printf '启动管理平台……\n'
  "${compose[@]}" up -d orp
  "$root/scripts/deploy/quickstart-demo.sh"
  quickstart_load_demo_identity "$env_file"
  quickstart_sync_demo_bootstrap_configs "$root"
  printf '启动三个 OpenResty 演示节点和 Filebeat……\n'
  compose_profiles=(--profile demos)
  compose_services=(openresty-east-1 openresty-east-2 openresty-east-3 filebeat-east-1 filebeat-east-2 filebeat-east-3)
  compose_refresh=()
  [[ "$QUICKSTART_DEMO_BOOTSTRAP_UPDATED" != true ]] || compose_refresh+=(--force-recreate)
  if [[ "$with_traffic" == true ]]; then
    printf '启动演示请求生成器……\n'
    compose_profiles+=(--profile traffic)
    compose_services+=(demo-traffic-generator)
    if [[ "$QUICKSTART_DEMO_BOOTSTRAP_UPDATED" == true ]]; then
      "${compose[@]}" "${compose_profiles[@]}" up -d --force-recreate "${compose_services[@]}"
    else
      "${compose[@]}" "${compose_profiles[@]}" up -d "${compose_services[@]}"
    fi
  else
    if [[ "$QUICKSTART_DEMO_BOOTSTRAP_UPDATED" == true ]]; then
      "${compose[@]}" "${compose_profiles[@]}" up -d --force-recreate "${compose_services[@]}"
    else
      "${compose[@]}" "${compose_profiles[@]}" up -d "${compose_services[@]}"
    fi
    "${compose[@]}" --profile traffic stop demo-traffic-generator >/dev/null 2>&1 || true
  fi
else
  printf '启动管理平台（演示节点和 Filebeat 已关闭）……\n'
  "${compose[@]}" up -d orp
  "${compose[@]}" --profile traffic stop demo-traffic-generator >/dev/null 2>&1 || true
fi

if [[ "$with_demos" == true ]]; then
  # Filebeat may create a new Kafka topic only after its first log event. Refresh
  # the consumer after the producers have started so a fresh topic is assigned.
  sleep 3
  printf '刷新 Kafka 日志订阅并等待管理平台就绪……\n'
  "${compose[@]}" restart orp
  for _ in {1..60}; do
    if nc -z 127.0.0.1 8081 >/dev/null 2>&1; then break; fi
    sleep 1
  done
  nc -z 127.0.0.1 8081 >/dev/null 2>&1 || quickstart_fail '管理平台重启后未能监听 8081 端口。'
fi

printf '管理界面和 API：http://127.0.0.1:8081\n'

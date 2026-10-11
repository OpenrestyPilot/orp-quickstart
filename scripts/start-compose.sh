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

[[ -n "${ADMIN_USERNAME:-}" ]] || quickstart_fail '.env 未配置 ADMIN_USERNAME。'
[[ -n "${ADMIN_PASSWORD:-}" ]] || quickstart_fail '.env 未配置 ADMIN_PASSWORD。'
[[ "${DATA_KEY:-}" =~ ^[[:xdigit:]]{64}$ ]] || quickstart_fail 'DATA_KEY 必须是 64 位十六进制字符串。'
[[ -n "${OPENRESTY_PLUS_IMAGE:-}" ]] || quickstart_fail '.env 未配置 OPENRESTY_PLUS_IMAGE。'
quickstart_check_dependencies
quickstart_configure_filebeat_brokers

if [[ "$with_demos" == true ]]; then
  "$root/scripts/deploy/prepare-node-agent.sh"
  quickstart_load_env "$env_file"
  printf '构建包含 orp-node-agent 的演示节点镜像……\n'
  docker build --pull -t "${RUNTIME_IMAGE}:${IMAGE_TAG:-latest}" \
    -f "$root/deploy/openresty/Dockerfile.control-api" "$root/deploy/openresty"
  printf '启动管理平台……\n'
  "${compose[@]}" up -d openresty-plus
  "$root/scripts/deploy/quickstart-demo.sh"
  printf '启动三个 OpenResty 演示节点和 Filebeat……\n'
  if [[ "$with_traffic" == true ]]; then
    printf '启动演示请求生成器……\n'
    "${compose[@]}" --profile demos --profile traffic up -d
  else
    "${compose[@]}" --profile demos up -d
    "${compose[@]}" --profile traffic stop demo-traffic-generator >/dev/null 2>&1 || true
  fi
else
  printf '启动管理平台（演示节点和 Filebeat 已关闭）……\n'
  "${compose[@]}" up -d openresty-plus
  "${compose[@]}" --profile traffic stop demo-traffic-generator >/dev/null 2>&1 || true
fi

printf '管理界面和 API：http://127.0.0.1:8081\n'

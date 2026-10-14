#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
env_file="$root/.env"
template="$root/.env.compose.example"

if [[ -e "$env_file" ]]; then
  printf '%s 已存在；为避免覆盖密钥，脚本未修改它。\n' "$env_file"
  exit 1
fi

command -v openssl >/dev/null 2>&1 || { printf '缺少命令：openssl\n' >&2; exit 1; }
admin_password=$(openssl rand -hex 18)
data_key=$(openssl rand -hex 32)

awk -v admin="$admin_password" -v key="$data_key" '
  /^ORP_ADMIN_PASSWORD=/ { print "ORP_ADMIN_PASSWORD=" admin; next }
  /^ORP_DATA_KEY=/ { print "ORP_DATA_KEY=" key; next }
  { print }
' "$template" > "$env_file"
chmod 600 "$env_file"
printf '已创建 %s 并生成管理员密码和数据加密密钥。请填写外部中间件连接信息及镜像仓库地址，再启动 Compose。\n' "$env_file"

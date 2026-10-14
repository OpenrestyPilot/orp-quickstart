#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"

for tool in git go node pnpm docker openssl; do
  command -v "$tool" >/dev/null 2>&1 || { printf '缺少命令：%s\n' "$tool" >&2; exit 1; }
done

ref=${ORP_SOURCE_REF:-main}
source_dir="$root/openresty-pilot"
if [[ ! -e "$source_dir" ]]; then
  git clone --depth 1 --branch "$ref" https://github.com/OpenrestyPilot/openresty-pilot.git "$source_dir"
elif [[ ! -d "$source_dir/.git" ]]; then
  printf '%s 已存在且不是 Git 仓库，请先移走它。\n' "$source_dir" >&2
  exit 1
fi

if [[ ! -f "$root/.env" ]]; then
  admin_password=$(openssl rand -hex 18)
  data_key=$(openssl rand -hex 32)
  awk -v admin="$admin_password" -v key="$data_key" '
    /^ORP_ADMIN_PASSWORD=/ { print "ORP_ADMIN_PASSWORD=" admin; next }
    /^ORP_DATA_KEY=/ { print "ORP_DATA_KEY=" key; next }
    { print }
  ' "$root/.env.source.example" > "$root/.env"
  chmod 600 "$root/.env"
  printf '已创建本地 .env 并生成管理员密码和数据密钥。请填写外部 MySQL、Redis、Kafka 连接信息后再次运行此脚本。\n'
  exit 0
fi

exec "$root/scripts/dev-source.sh" "$@"

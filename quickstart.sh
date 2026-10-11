#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
env_file="$root/.env"
source "$root/scripts/lib/dependencies.sh"

fail() {
  printf '启动检查失败：%s\n' "$1" >&2
  exit 1
}

if [[ ! -f "$env_file" ]]; then
  fail '没有找到 .env。请先运行 cp .env.binary.example .env 并填写配置。'
fi

quickstart_load_env "$env_file"

# Accept both the binary/source variable names and the Compose names in .env.
# The control-plane process itself consumes the OPENRESTY_* names.
OPENRESTY_ADMIN_USERNAME=${OPENRESTY_ADMIN_USERNAME:-${ADMIN_USERNAME:-}}
OPENRESTY_ADMIN_PASSWORD=${OPENRESTY_ADMIN_PASSWORD:-${ADMIN_PASSWORD:-}}
export OPENRESTY_ADMIN_USERNAME OPENRESTY_ADMIN_PASSWORD

binary_path="${OPENRESTY_PLUS_BINARY_PATH:-bin/openresty-plus}"
[[ "$binary_path" = /* ]] || binary_path="$root/$binary_path"

action=${1:-start}
if [[ $# -gt 0 ]]; then shift; fi

check_start_config() {
  [[ -n "${OPENRESTY_ADMIN_USERNAME:-}" ]] || fail '.env 未配置 OPENRESTY_ADMIN_USERNAME。'
  [[ -n "${OPENRESTY_ADMIN_PASSWORD:-}" ]] || fail '.env 未配置 OPENRESTY_ADMIN_PASSWORD。'
  [[ "${OPENRESTY_DATA_KEY:-}" =~ ^[[:xdigit:]]{64}$ ]] || fail 'OPENRESTY_DATA_KEY 必须是 64 位十六进制字符串。'
  quickstart_check_dependencies
}

case "$action" in
  start|restart|run) check_start_config ;;
  status|stop|logs|version|help|--help|-h) ;;
  *) fail "不支持的命令：$action（可用 start、status、logs、restart、stop、version、help）" ;;
esac

if [[ ! -x "$binary_path" ]]; then
  binary_url=${OPENRESTY_PLUS_BINARY_URL:-}
  command -v curl >/dev/null 2>&1 || fail '下载二进制需要 curl。'
  command -v python3 >/dev/null 2>&1 || fail '自动下载最新 Release 需要 python3。'
  mkdir -p "$(dirname "$binary_path")"
  temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/orp-quickstart.XXXXXX")
  trap 'rm -rf "$temporary_dir"' EXIT

  if [[ -n "$binary_url" ]]; then
    printf '正在下载 OPENRESTY_PLUS_BINARY_URL 指定的程序……\n'
    curl --fail --location --silent --show-error --retry 3 "$binary_url" -o "$temporary_dir/openresty-plus" \
      || fail '二进制下载失败，请检查 OPENRESTY_PLUS_BINARY_URL 和访问权限。'
  else
    system_name=$(uname -s)
    machine_name=$(uname -m)
    case "$system_name" in
      Linux) release_os=linux ;;
      Darwin) release_os=darwin ;;
      *) fail "暂不支持自动下载当前操作系统的 Release：$system_name；请设置 OPENRESTY_PLUS_BINARY_URL。" ;;
    esac
    case "$machine_name" in
      x86_64|amd64) release_arch=amd64 ;;
      aarch64|arm64) release_arch=arm64 ;;
      *) fail "暂不支持自动下载当前 CPU 架构的 Release：$machine_name；请设置 OPENRESTY_PLUS_BINARY_URL。" ;;
    esac

    release_api=${OPENRESTY_PLUS_RELEASE_API_URL:-https://api.github.com/repos/OpenrestyPlus/openresty-plus/releases?per_page=10}
    printf '正在查询 OpenResty Plus 最新 Release（%s-%s）……\n' "$release_os" "$release_arch"
    if curl --fail --location --silent --show-error --retry 3 \
      -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' \
      "$release_api" -o "$temporary_dir/releases.json"; then
      python3 - "$temporary_dir/releases.json" "$release_os" "$release_arch" > "$temporary_dir/release-meta" <<'PY'
import json
import sys

path, os_name, arch = sys.argv[1:]
with open(path, encoding="utf-8") as source:
    releases = json.load(source)
if isinstance(releases, dict):
    releases = [releases]
suffix = f"-{os_name}-{arch}.zip"
for release in releases:
    assets = release.get("assets", [])
    package = next((item for item in assets if item["name"].startswith("openresty-plus-") and item["name"].endswith(suffix)), None)
    sums = next((item for item in assets if item["name"] == "SHA256SUMS.txt"), None)
    if package and sums:
        print("\t".join((release.get("tag_name", ""), package["name"], package["browser_download_url"], sums["browser_download_url"])))
        break
else:
    raise SystemExit(f"最近的 GitHub Releases 中没有匹配的 {os_name}-{arch} 压缩包和 SHA256SUMS.txt")
PY
    else
      printf 'GitHub API 暂不可用，改从 Release 页面查找最新版本……\n'
      release_page=${OPENRESTY_PLUS_RELEASES_URL:-https://github.com/OpenrestyPlus/openresty-plus/releases}
      curl --fail --location --silent --show-error --retry 3 "$release_page" -o "$temporary_dir/releases.html" \
        || fail '无法读取 GitHub Release 页面，请检查网络或 OPENRESTY_PLUS_RELEASES_URL。'
      python3 - "$temporary_dir/releases.html" "$release_os" "$release_arch" > "$temporary_dir/expanded-assets-url" <<'PY'
import re
import sys
from urllib.parse import urljoin
from html import unescape

page = open(sys.argv[1], encoding="utf-8").read()
match = re.search(r'<include-fragment[^>]+src="([^"]*/releases/expanded_assets/([^"]+))"', page)
if not match:
    raise SystemExit("Release 页面中没有找到最新版本的下载资产")
print("\t".join((urljoin("https://github.com", unescape(match.group(1))), unescape(match.group(2)))))
PY
      IFS=$'\t' read -r expanded_assets_url release_tag < "$temporary_dir/expanded-assets-url" \
        || fail '无法解析最新 Release 的下载资产页面。'
      curl --fail --location --silent --show-error --retry 3 "$expanded_assets_url" -o "$temporary_dir/assets.html" \
        || fail '无法读取最新 Release 的下载资产。'
      python3 - "$temporary_dir/assets.html" "$release_tag" "$release_os" "$release_arch" > "$temporary_dir/release-meta" <<'PY'
import html
import re
import sys
from urllib.parse import urljoin

asset_page, tag, os_name, arch = sys.argv[1:]
page = open(asset_page, encoding="utf-8").read()
hrefs = [html.unescape(value) for value in re.findall(r'<a[^>]+href="([^"]+)"', page)]
suffix = f"-{os_name}-{arch}.zip"
package_path = next((value for value in hrefs if value.split("/")[-1].startswith("openresty-plus-") and value.endswith(suffix)), None)
sums_path = next((value for value in hrefs if value.endswith("/SHA256SUMS.txt")), None)
if not package_path or not sums_path:
    raise SystemExit(f"最新 Release {tag} 没有匹配的 {os_name}-{arch} 程序包或校验文件")
print("\t".join((tag, package_path.split("/")[-1], urljoin("https://github.com", package_path), urljoin("https://github.com", sums_path))))
PY
    fi
    IFS=$'\t' read -r release_tag package_name package_url checksums_url < "$temporary_dir/release-meta" \
      || fail '无法解析 GitHub Release 下载信息。'
    printf '正在下载 OpenResty Plus %s……\n' "$release_tag"
    curl --fail --location --silent --show-error --retry 3 "$package_url" -o "$temporary_dir/package.zip" \
      || fail 'Release 二进制压缩包下载失败。'
    curl --fail --location --silent --show-error --retry 3 "$checksums_url" -o "$temporary_dir/SHA256SUMS.txt" \
      || fail 'Release 校验文件下载失败。'
    python3 - "$temporary_dir/package.zip" "$temporary_dir/SHA256SUMS.txt" "$package_name" "$temporary_dir/openresty-plus" <<'PY'
import hashlib
import pathlib
import sys
import zipfile

archive_path, sums_path, asset_name, output_path = map(pathlib.Path, sys.argv[1:])
expected = None
for line in sums_path.read_text(encoding="utf-8").splitlines():
    fields = line.split()
    if len(fields) >= 2 and fields[-1].lstrip("*") == asset_name.name:
        expected = fields[0].lower()
        break
if not expected:
    raise SystemExit(f"SHA256SUMS.txt 中没有 {asset_name.name} 的校验值")
actual = hashlib.sha256(archive_path.read_bytes()).hexdigest()
if actual != expected:
    raise SystemExit("Release 压缩包 SHA-256 校验失败")
with zipfile.ZipFile(archive_path) as bundle:
    executables = [name for name in bundle.namelist() if pathlib.PurePosixPath(name).name == asset_name.stem]
    if len(executables) != 1:
        raise SystemExit("Release 压缩包中没有找到唯一的 quickstart 可执行文件")
    output_path.write_bytes(bundle.read(executables[0]))
PY
  fi

  chmod 0755 "$temporary_dir/openresty-plus"
  mv "$temporary_dir/openresty-plus" "$binary_path"
  trap - EXIT
  rm -rf "$temporary_dir"
fi

cd "$root"
exec "$binary_path" "$action" "$@"

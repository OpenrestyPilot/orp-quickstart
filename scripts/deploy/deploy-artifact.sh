#!/usr/bin/env bash
set -euo pipefail

# Root-owned on production nodes. Invoked only through an SSH forced command.
TASK_ID="${1:?task id required}"
ARTIFACT_ID="${2:?artifact id required}"
EXPECTED_SHA256="${3:?sha256 required}"
ARTIFACT_ROOT="/var/lib/orp/artifacts"
RELEASE_ROOT="/etc/openresty/releases"
CURRENT_LINK="/etc/openresty/current"
CONTROL_SOCKET="${ORP_CONTROL_SOCKET:-/run/openresty/control.sock}"

case "$TASK_ID" in (*[!a-zA-Z0-9._:-]*|'') echo "invalid task id" >&2; exit 2;; esac
case "$ARTIFACT_ID" in (*[!a-zA-Z0-9._:-]*|'') echo "invalid artifact id" >&2; exit 2;; esac

archive="${ARTIFACT_ROOT}/${ARTIFACT_ID}.tar.zst"
test -f "$archive" || { echo "artifact not found" >&2; exit 3; }
actual="$(sha256sum "$archive" | awk '{print $1}')"
test "$actual" = "$EXPECTED_SHA256" || { echo "artifact checksum mismatch" >&2; exit 4; }

release="${RELEASE_ROOT}/${ARTIFACT_ID}"
install -d -m 0750 "$release"
tar --zstd --extract --file "$archive" --directory "$release" --no-same-owner --no-same-permissions

/usr/sbin/nginx -t -c /etc/openresty/nginx.conf -p /etc/openresty

next_link="${CURRENT_LINK}.next.${TASK_ID}"
ln -sfn "$release" "$next_link"
mv -Tf "$next_link" "$CURRENT_LINK"

# The Control API is the only permitted reload path.
curl --fail --silent --show-error --unix-socket "$CONTROL_SOCKET" -X PATCH http://localhost/1/control/config
printf '{"taskId":"%s","artifactId":"%s","status":"SUCCEEDED"}\n' "$TASK_ID" "$ARTIFACT_ID"

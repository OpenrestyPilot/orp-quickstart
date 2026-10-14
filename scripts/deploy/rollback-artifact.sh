#!/usr/bin/env bash
set -euo pipefail
TASK_ID="${1:?task id required}"
ARTIFACT_ID="${2:?artifact id required}"
exec "$(dirname "$0")/deploy-artifact.sh" "$TASK_ID" "$ARTIFACT_ID" "$(sha256sum "/var/lib/orp/artifacts/${ARTIFACT_ID}.tar.zst" | awk '{print $1}')"

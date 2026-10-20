#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
options=(--host "${QQM_HOST:-127.0.0.1}" --port "${QQM_PORT:-23336}" --data "${QQM_DATA:-./data}" --assets .)
if [[ -n "${QQM_PUBLIC_URL:-}" ]]; then
  options+=(--public-url "$QQM_PUBLIC_URL")
fi
exec ./qqm-server "${options[@]}" "$@"

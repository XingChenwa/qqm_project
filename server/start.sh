#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
if [[ -f "$PWD/lib/libqqm_agent_js.so" ]]; then
  export FLUTTER_QJS_NEXT_LIBRARY="$PWD/lib/libqqm_agent_js.so"
fi
options=(--host "${QQM_HOST:-127.0.0.1}" --port "${QQM_PORT:-23336}" --data "${QQM_DATA:-./data}" --assets .)
if [[ -n "${QQM_PUBLIC_URL:-}" ]]; then
  options+=(--public-url "$QQM_PUBLIC_URL")
fi
exec ./qqm-server "${options[@]}" "$@"

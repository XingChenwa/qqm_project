#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
exec ./qqm-server --host "${QQM_HOST:-127.0.0.1}" --port "${QQM_PORT:-23336}" --data "${QQM_DATA:-./data}" --assets . "$@"

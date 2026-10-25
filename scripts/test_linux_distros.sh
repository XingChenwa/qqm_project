#!/usr/bin/env bash
# Run the very same binary with no network access in several distributions.
set -euo pipefail
package=$(realpath "${1:?Pass the staged Linux package directory}")
for image in ubuntu:22.04 debian:12-slim rockylinux:9; do
  docker pull "$image"
  docker run --rm -i --network none --read-only --cap-drop ALL \
    --security-opt no-new-privileges --tmpfs /tmp:rw,noexec,nosuid,size=64m \
    -v "$package:/app:ro" --entrypoint /bin/bash "$image" -s <<'SMOKE'
set -euo pipefail
cd /app
export FLUTTER_QJS_NEXT_LIBRARY=/app/lib/libqqm_agent_js.so
# Print only public loader diagnostics, so future ABI failures are actionable.
if command -v ldd >/dev/null; then ldd "$FLUTTER_QJS_NEXT_LIBRARY"; fi
./qqm-server --help >/dev/null
./qqm-server --check-agent-engine
./qqm-server --data /tmp/auth --access-link http://127.0.0.1:23336 > /tmp/private-link
test -s /tmp/auth/setup-token.txt
test ! -e /tmp/auth/admin-auth.json
grep -q '#setup=' /tmp/private-link
./qqm-server --host 127.0.0.1 --port 23336 --assets /app --data /tmp/auth --no-auto-connect > /tmp/service.log 2>&1 &
service_pid=$!
trap 'kill -TERM "$service_pid" 2>/dev/null || true' EXIT
ready=false
for ((i=0;i<30;i++)); do
  if { exec 3<>/dev/tcp/127.0.0.1/23336; } 2>/dev/null; then ready=true; break; fi
  sleep 0.2
done
$ready
printf 'GET /health HTTP/1.1\r\nHost: 127.0.0.1:23336\r\nConnection: close\r\n\r\n' >&3
response=$(cat <&3)
exec 3<&- 3>&-
[[ "$response" == *'"ok":true'* ]]
kill -TERM "$service_pid"
wait "$service_pid"
trap - EXIT
printf 'PASS: compiled service, private setup link and HTTP health\n'
SMOKE
  printf 'PASS: %s\n' "$image"
done

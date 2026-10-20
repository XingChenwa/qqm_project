#!/usr/bin/env bash
# Only copied inside an isolated test container. No host systemd is touched.
set -euo pipefail
pidfile=/run/qqm-fixture.pid
case "$1" in
  is-active)
    [[ -f "$pidfile" ]] && kill -0 "$(< "$pidfile")" 2>/dev/null ;;
  start)
    if [[ -f /run/qqm-fixture.fail ]]; then rm /run/qqm-fixture.fail; exit 1; fi
    if [[ -f "$pidfile" ]] && kill -0 "$(< "$pidfile")" 2>/dev/null; then exit 0; fi
    host=127.0.0.1 port=23336 public=''
    while IFS='=' read -r key value; do
      case "$key" in QQM_HOST) host=$value ;; QQM_PORT) port=$value ;; QQM_PUBLIC_URL) public=$value ;; esac
    done < /etc/qqbotmanager.env
    runuser -u qqbotmanager -- env QQM_HOST="$host" QQM_PORT="$port" \
      QQM_PUBLIC_URL="$public" QQM_DATA=/var/lib/qqbotmanager \
      /opt/qqbotmanager/start.sh > /run/qqm-fixture.log 2>&1 9>&- &
    printf '%s\n' "$!" > "$pidfile" ;;
  stop)
    if [[ -f "$pidfile" ]]; then
      pid=$(< "$pidfile")
      kill -TERM "$pid" 2>/dev/null || true
      for ((i=0;i<40;i++)); do
        if ! kill -0 "$pid" 2>/dev/null; then break; fi
        sleep 0.1
      done
      rm "$pidfile"
    fi ;;
  enable|daemon-reload) ;;
  *) printf 'Unexpected fixture command\n' >&2; exit 1 ;;
esac

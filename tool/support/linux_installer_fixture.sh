#!/usr/bin/env bash
# Root filesystem is a disposable container. /input and /test are read-only;
# the host's /etc, /opt and /var/lib are never mounted into this container.
set -Eeuo pipefail
umask 077
phase=new-install
trap 'printf "Linux installer fixture failed at line %s (stage %s)\n" "$LINENO" "$phase" >&2' ERR
mkdir -p /run/systemd/system /etc/systemd/system /opt /var/lib /var/backups
install -m 755 /test/systemctl_fixture.sh /usr/local/bin/systemctl
trap 'systemctl stop qqbotmanager || true' EXIT

# Real new install, no password is collected in the terminal. /input is read
# only, so validation cannot accidentally modify the downloaded package.
bash /input/install.sh --local --access-url http://192.0.2.10:23336 > /tmp/install-private.log
test -x /opt/qqbotmanager/qqm-server
test -f /var/lib/qqbotmanager/setup-token.txt
test ! -f /var/lib/qqbotmanager/admin-auth.json
test "$(stat -c %a /var/lib/qqbotmanager)" = 700
test "$(stat -c %a /var/lib/qqbotmanager/setup-token.txt)" = 600
test "$(stat -c %U /opt/qqbotmanager/qqm-server)" = root
curl -fsS http://127.0.0.1:23336/health > /dev/null
jq -n --rawfile token /var/lib/qqbotmanager/setup-token.txt \
  '{token:($token|rtrimstr("\n")),password:"installer-fixture-password-2026",confirmation:"installer-fixture-password-2026",entrance:"installer-fixture-entrance"}' > /tmp/setup-private.json
curl -fsS -H 'X-QQM-Request: 1' -H 'Content-Type: application/json' \
  --data-binary @/tmp/setup-private.json http://127.0.0.1:23336/api/setup > /dev/null
test ! -f /var/lib/qqbotmanager/setup-token.txt
test "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:23336/)" = 404
before=$(sha256sum /var/lib/qqbotmanager/admin-auth.json)
printf 'keep chats and plugins\n' > /var/lib/qqbotmanager/keep-fixture-data
chown qqbotmanager:qqbotmanager /var/lib/qqbotmanager/keep-fixture-data

# Reinstall/upgrade: keep password + entrance + unrelated private data.
phase=upgrade
bash /input/install.sh --local > /tmp/upgrade-private.log
test "$before" = "$(sha256sum /var/lib/qqbotmanager/admin-auth.json)"
test "$(< /var/lib/qqbotmanager/keep-fixture-data)" = 'keep chats and plugins'
bash /opt/qqbotmanager/install.sh --print-link > /tmp/access-private.log
grep -q '/installer-fixture-entrance/' /tmp/access-private.log
! grep -q '#setup=' /tmp/access-private.log

# A failed upgrade must restore the old program and not reset private data.
phase=rollback
touch /opt/qqbotmanager/old-program-fixture
touch /run/qqm-fixture.fail
if bash /input/install.sh --local > /tmp/failed-private.log 2>&1; then
  printf 'Expected simulated service startup to fail\n' >&2; exit 1
fi
test -f /opt/qqbotmanager/old-program-fixture
test "$before" = "$(sha256sum /var/lib/qqbotmanager/admin-auth.json)"
for ((i=0;i<30;i++)); do
  if curl -fsS http://127.0.0.1:23336/health > /dev/null 2>&1; then break; fi
  sleep 0.2
done
curl -fsS http://127.0.0.1:23336/health > /dev/null
test "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:23336/installer-fixture-entrance/)" = 200
test "$(stat -c %a /var/backups/qqbotmanager)" = 700

# Explicit flags after the wrapper's defaults must win, including data/port.
phase=wrapper
/opt/qqbotmanager/start.sh --host 127.0.0.1 --port 23337 --data /tmp/wrapper-fixture --no-auto-connect > /tmp/wrapper.log 2>&1 &
wrapper_pid=$!
trap 'kill -TERM "$wrapper_pid" 2>/dev/null || true; systemctl stop qqbotmanager || true' EXIT
for ((i=0;i<30;i++)); do
  if curl -fsS http://127.0.0.1:23337/health > /dev/null 2>&1; then break; fi
  sleep 0.2
done
curl -fsS http://127.0.0.1:23337/health > /dev/null
test -f /tmp/wrapper-fixture/setup-token.txt
kill -TERM "$wrapper_pid"
wait "$wrapper_pid"
trap 'systemctl stop qqbotmanager || true' EXIT
printf 'PASS: isolated real install, browser-only setup, permissions, upgrade preservation, rollback and CLI overrides\n'

#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
names=$(node tool/package_names.mjs json)
filename=$(printf '%s' "$names" | node -pe 'JSON.parse(require("fs").readFileSync(0,"utf8")).linux_file')
stage=$(mktemp -d "${RUNNER_TEMP:-/tmp}/qqm-linux.XXXXXXXX")
package="$stage/qqbotmanager"
mkdir -p "$package/server" "$package/assets/branding" "$package/plugins" dist
# Native Dart, no X11, GTK, browser engine or Flutter desktop runtime required.
dart compile exe server/bin/manager.dart -o "$package/qqm-server"
cp -R server/web "$package/server/web"
cp assets/branding/logo.png "$package/assets/branding/logo.png"
cp plugins/index.json "$package/plugins/index.json"
for plugin in example_plugin weather_plugin dice_plugin translate_comment daily_club group_games group_authorization; do
  cp -R "plugins/$plugin" "$package/plugins/$plugin"
done
cp server/README.md "$package/README.md"
cp server/qqbotmanager.service "$package/qqbotmanager.service"
cp server/start.sh "$package/start.sh"
cp LICENSE "$package/LICENSE"
chmod 755 "$package/qqm-server" "$package/start.sh"
# Ensure the Ubuntu 22.04 artifact can start before publishing it.
"$package/qqm-server" --help
"$package/qqm-server" --host 127.0.0.1 --port 23336 --assets "$package" --data "$stage/smoke-data" --no-auto-connect > "$stage/smoke.log" 2>&1 &
service_pid=$!
trap 'kill -TERM "$service_pid" 2>/dev/null || true' EXIT
curl --retry 15 --retry-connrefused --retry-delay 1 --fail --silent http://127.0.0.1:23336/health |
  node -e 'let s="";process.stdin.on("data",x=>s+=x);process.stdin.on("end",()=>{if(JSON.parse(s).ok!==true)process.exit(1);console.log("Ubuntu 22.04: compiled HTTP service healthy on 23336");});'
kill -TERM "$service_pid"
wait "$service_pid"
trap - EXIT
tar -czf "dist/$filename" -C "$stage" qqbotmanager
(cd dist && sha256sum "$filename" > "$filename.sha256")
printf 'Linux 网页服务包已生成：%s\n' "$filename"

#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
names=$(node tool/package_names.mjs json)
filename=$(printf '%s' "$names" | node -pe 'JSON.parse(require("fs").readFileSync(0,"utf8")).linux_file')
stage=$(mktemp -d "${RUNNER_TEMP:-/tmp}/qqm-linux.XXXXXXXX")
package="$stage/qqbotmanager"
mkdir -p "$package/server" "$package/assets/branding" "$package/plugins" dist
# The same embedded QuickJS core as Android/iOS, without Flutter/GTK.
qjs_package=$(dart run tool/agent_engine_path.dart | tail -1)
bash scripts/build_linux_agent.sh "$qjs_package" "$stage/agent-js"
mkdir -p "$package/lib"
cp "$stage/agent-js/libqqm_agent_js.so" "$package/lib/"
cp "$stage/agent-js/GCC-runtime-LICENSE.txt" "$package/lib/"
export FLUTTER_QJS_NEXT_LIBRARY="$package/lib/libqqm_agent_js.so"
flutter test --no-pub --concurrency 2 test/agent_js_packages_test.dart test/agent_local_dependencies_test.dart test/agent_yy_tts_test.dart test/agent_gradio_stream_test.dart
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
cp server/install.sh "$package/install.sh"
cp LICENSE "$package/LICENSE"
cp "$qjs_package/LICENSE" "$package/lib/QuickJS-bindings-LICENSE.txt"
# Upstream ships QuickJS's MIT notice in the source header rather than a LICENSE file.
sed -n '1,/\*\//p' "$qjs_package/cxx/quickjs/quickjs.c" > "$package/lib/QuickJS-LICENSE.txt"
chmod 755 "$package/qqm-server" "$package/start.sh" "$package/install.sh"
# The Dart executable contains the SDK's prelinked AOT runtime. Check its real
# glibc requirements, not the name of the runner's distribution.
required_glibc=$(LC_ALL=C readelf --version-info "$package/qqm-server" | sed -nE 's/.*Name: GLIBC_([0-9.]+).*/\1/p' | sort -Vu | tail -1)
[[ -n "$required_glibc" && $(printf '%s\n' "$required_glibc" 2.31 | sort -V | tail -1) == 2.31 ]] || { printf 'Unexpected glibc requirement: %s\n' "$required_glibc" >&2; exit 1; }
# Ensure the compiled artifact can start before publishing it.
"$package/qqm-server" --help
"$package/qqm-server" --check-agent-engine
"$package/qqm-server" --host 127.0.0.1 --port 23336 --assets "$package" --data "$stage/smoke-data" --no-auto-connect > "$stage/smoke.log" 2>&1 &
service_pid=$!
trap 'kill -TERM "$service_pid" 2>/dev/null || true' EXIT
curl --retry 15 --retry-connrefused --retry-delay 1 --fail --silent http://127.0.0.1:23336/health |
  node -e 'let s="";process.stdin.on("data",x=>s+=x);process.stdin.on("end",()=>{if(JSON.parse(s).ok!==true)process.exit(1);console.log("Ubuntu 22.04: compiled HTTP service healthy on 23336");});'
kill -TERM "$service_pid"
wait "$service_pid"
trap - EXIT
bash scripts/test_linux_distros.sh "$package"
bash scripts/test_linux_installer.sh "$package"
tar -czf "dist/$filename" -C "$stage" qqbotmanager
(cd dist && sha256sum "$filename" > "$filename.sha256")
printf 'Linux 网页服务包已生成：%s\n' "$filename"

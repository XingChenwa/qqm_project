#!/usr/bin/env bash
# Build only the public native dependency in an older glibc toolchain.
set -euo pipefail
qjs_package=$(realpath "${1:?Pass the QuickJS package directory}")
native_output=$(realpath -m "${2:?Pass the native output directory}")
native_source=$(cd "$(dirname "$0")/../tool/native_agent" && pwd -P)
mkdir -p "$native_output"
context=$(mktemp -d "${RUNNER_TEMP:-/tmp}/qqm-agent-toolchain.XXXXXXXX")
docker build --quiet -t qqm-agent-toolchain:glibc231 -f - "$context" <<'IMAGE'
FROM ubuntu:20.04
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    cmake g++ make && rm -rf /var/lib/apt/lists/*
IMAGE
# No credentials, home directory or private configuration enter the container.
docker run --rm --network none --read-only --cap-drop ALL \
  --security-opt no-new-privileges --user "$(id -u):$(id -g)" \
  --tmpfs /tmp:rw,nosuid,size=128m \
  -v "$qjs_package:/qjs:ro" -v "$native_source:/src:ro" \
  -v "$native_output:/out:rw" --entrypoint /bin/bash qqm-agent-toolchain:glibc231 -c '
set -euo pipefail
cmake -S /src -B /out -DCMAKE_BUILD_TYPE=Release -DQJS_PACKAGE=/qjs
cmake --build /out --parallel 2
cp /usr/share/doc/libstdc++-9-dev/copyright /out/GCC-runtime-LICENSE.txt
'
required_glibc=$(LC_ALL=C readelf --version-info "$native_output/libqqm_agent_js.so" | sed -nE 's/.*Name: GLIBC_([0-9.]+).*/\1/p' | sort -Vu | tail -1)
[[ -n "$required_glibc" && $(printf '%s\n' "$required_glibc" 2.31 | sort -V | tail -1) == 2.31 ]] || {
  printf 'Unexpected native glibc requirement: %s\n' "$required_glibc" >&2; exit 1;
}
if readelf -d "$native_output/libqqm_agent_js.so" | grep -Eq 'NEEDED.*(libstdc\+\+|libgcc_s)'; then
  printf 'Native engine unexpectedly requires compiler-specific dynamic runtimes\n' >&2; exit 1
fi
printf 'Portable native engine verified: glibc %s, static C++ runtime\n' "$required_glibc"

#!/usr/bin/env bash
set -euo pipefail
package=$(realpath "${1:?Pass the staged Linux package directory}")
fixtures=$(cd "$(dirname "$0")/../tool/support" && pwd -P)
context=$(mktemp -d "${RUNNER_TEMP:-/tmp}/qqm-installer-test.XXXXXXXX")
# Empty build context: no repository/private data is sent into the test image.
docker build --quiet -t qqm-installer-test -f - "$context" <<'IMAGE'
FROM ubuntu:22.04
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates curl jq tar gzip coreutils util-linux passwd && rm -rf /var/lib/apt/lists/*
IMAGE
docker run --rm --init --network none --security-opt no-new-privileges \
  -v "$package:/input:ro" -v "$fixtures:/test:ro" qqm-installer-test \
  bash /test/linux_installer_fixture.sh

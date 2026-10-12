#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TASK_WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/siliconplayer-node-options.XXXXXX")"
trap 'rm -rf "$TASK_WORK_DIR"' EXIT
swiftc -parse-as-library -O -I Sources/CMPV -L Vendor/lib \
  -Xlinker -rpath -Xlinker "$PWD/Vendor/lib" \
  Sources/SiliconPlayer/LiveASRTypes.swift Sources/SiliconPlayer/MPVCommandOptions.swift Tests/Integration/MPVCommandOptionChecks.swift \
  -o "$TASK_WORK_DIR/checks"
"$TASK_WORK_DIR/checks" "$PWD/Tests/Fixtures/中文 测试 H264.mp4"

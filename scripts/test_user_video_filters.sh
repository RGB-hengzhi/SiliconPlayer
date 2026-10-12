#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
FILTER_TEST_DIR="$(mktemp -d /private/tmp/siliconplayer-user-filters.XXXXXX)"
FILTER_REPORT_DIR="${1:-Tests/Integration/Reports}"
trap 'rm -rf "$FILTER_TEST_DIR"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$FILTER_REPORT_DIR"
{
    python3 - "$FILTER_TEST_DIR" <<'PY'
from pathlib import Path
import sys
source = Path('Tests/PlayerCoreTests/StandaloneRunner.swift').read_text()
marker = '@main\nstruct StandaloneRunner'
if source.count(marker) != 1:
    raise RuntimeError('Standalone assertion-helper boundary changed')
helpers = source.split(marker, 1)[0].replace('#if PLAYER_CORE_STANDALONE', '#if USER_VIDEO_FILTER_STANDALONE', 1)
(Path(sys.argv[1]) / 'Assertions.swift').write_text(helpers + '\n#endif\n')
PY
    xcrun swiftc -emit-library -emit-module -parse-as-library -module-name PlayerCore \
        -target arm64-apple-macos14.0 Sources/PlayerCore/[A-Z]*.swift \
        -emit-module-path "$FILTER_TEST_DIR/PlayerCore.swiftmodule" -o "$FILTER_TEST_DIR/libPlayerCore.dylib"
    xcrun swiftc -parse-as-library -D USER_VIDEO_FILTER_STANDALONE -target arm64-apple-macos14.0 \
        -I "$FILTER_TEST_DIR" -L "$FILTER_TEST_DIR" -lPlayerCore \
        -Xlinker -rpath -Xlinker "$FILTER_TEST_DIR" \
        "$FILTER_TEST_DIR/Assertions.swift" Sources/SiliconPlayer/UserVideoFiltersController.swift \
        Tests/PlayerCoreTests/UserVideoFiltersTests.swift Tests/Integration/UserVideoFiltersChecks.swift \
        -o "$FILTER_TEST_DIR/UserVideoFiltersChecks"
    "$FILTER_TEST_DIR/UserVideoFiltersChecks"
} 2>&1 | tee "$FILTER_REPORT_DIR/user-video-filters-results.txt"

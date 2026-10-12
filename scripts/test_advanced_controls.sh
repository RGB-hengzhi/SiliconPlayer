#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
    echo "These orchestration checks require Apple Silicon and macOS 14+." >&2
    exit 1
fi
ADVANCED_TEST_DIR="$(mktemp -d /private/tmp/siliconplayer-advanced-tests.XXXXXX)"
ADVANCED_REPORT_DIR="${1:-Tests/Integration/Reports}"
trap 'rm -rf "$ADVANCED_TEST_DIR"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$ADVANCED_REPORT_DIR"
{
    python3 - "$ADVANCED_TEST_DIR/ApplySettings.swift" <<'PY'
from pathlib import Path
import hashlib, sys
source = Path('Sources/SiliconPlayer/PlayerModelAdvanced.swift')
text = source.read_text()
start = text.index('    func applySettings() {')
end = text.index('\n    func refreshAdvancedState()', start)
integration = Path('Sources/SiliconPlayer/UserVideoFiltersIntegration.swift')
helper = integration.read_text()
helper_start = helper.index('    func configuredVideoFragments(')
helper_end = helper.index('\n    func applyVideoFilterProperties(', helper_start)
Path(sys.argv[1]).write_text('import AppKit\nimport CMPV\nimport PlayerCore\nextension PlayerModel {\n' + text[start:end] + '\n' + helper[helper_start:helper_end] + '\n}\n')
print('Production advanced source SHA-256: ' + hashlib.sha256(source.read_bytes()).hexdigest(), flush=True)
print('Production video helper SHA-256: ' + hashlib.sha256(integration.read_bytes()).hexdigest(), flush=True)
print('Compiled video scope: requested fragments/configuration factory only; MPV acceptance and video lifecycle NOT tested', flush=True)
print('Secondary subtitle style scope: typed dependency recorder only; MPV properties, rendering and performance NOT tested', flush=True)
PY
    xcrun swiftc -emit-library -emit-module -parse-as-library -module-name PlayerCore \
        -target arm64-apple-macos14.0 Sources/PlayerCore/[A-Z]*.swift \
        -emit-module-path "$ADVANCED_TEST_DIR/PlayerCore.swiftmodule" -o "$ADVANCED_TEST_DIR/libPlayerCore.dylib"
    xcrun swiftc -parse-as-library -target arm64-apple-macos14.0 \
        -I "$ADVANCED_TEST_DIR" -I Sources/CMPV -L "$ADVANCED_TEST_DIR" -lPlayerCore -L Vendor/lib -lmpv \
        -Xlinker -rpath -Xlinker "$PWD/Vendor/lib" \
        -Xlinker -rpath -Xlinker "$ADVANCED_TEST_DIR" \
        "$ADVANCED_TEST_DIR/ApplySettings.swift" Tests/Integration/AdvancedControlsChecks.swift -o "$ADVANCED_TEST_DIR/AdvancedControlsChecks"
    "$ADVANCED_TEST_DIR/AdvancedControlsChecks" "$ADVANCED_REPORT_DIR/advanced-controls.json"
} 2>&1 | tee "$ADVANCED_REPORT_DIR/advanced-controls-results.txt"

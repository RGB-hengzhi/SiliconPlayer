#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
    echo "These input checks require an Apple Silicon Mac running macOS 14 or later." >&2
    exit 1
fi

INPUT_TEST_DIR="$(mktemp -d /private/tmp/siliconplayer-input-tests.XXXXXX)"
INPUT_REPORT_DIR="${1:-Tests/Integration/Reports}"
trap 'rm -rf "$INPUT_TEST_DIR"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$INPUT_REPORT_DIR"

{
    # Compile the production binding/controller definitions, excluding system
    # media controls. A changed boundary fails extraction instead of silently
    # replacing production logic with a copied test implementation.
    python3 - "$INPUT_TEST_DIR/InputController.swift" <<'PY'
from pathlib import Path
import hashlib
import re
import sys

source = Path('Sources/SiliconPlayer/InputAndMediaControls.swift')
data = source.read_bytes()
text = data.decode('utf-8')
markers = list(re.finditer(r'(?m)^@MainActor\s*\nfinal class SystemMediaController\b', text))
if len(markers) != 1 or 'final class InputController' not in text[:markers[0].start()]:
    raise RuntimeError('Cannot locate production InputController / SystemMediaController boundary')
Path(sys.argv[1]).write_text(text[:markers[0].start()], encoding='utf-8')
print('Production input source SHA-256: ' + hashlib.sha256(data).hexdigest(), flush=True)
PY
    xcrun swiftc -parse-as-library -target arm64-apple-macos14.0 \
        "$INPUT_TEST_DIR/InputController.swift" Tests/Integration/InputChecks.swift \
        -o "$INPUT_TEST_DIR/InputChecks"
    "$INPUT_TEST_DIR/InputChecks"
} 2>&1 | tee "$INPUT_REPORT_DIR/input-results.txt"

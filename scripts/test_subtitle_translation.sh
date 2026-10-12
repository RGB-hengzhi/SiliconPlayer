#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
    echo "These translation checks require Apple Silicon and macOS 14+ (logic execution 15+)." >&2
    exit 1
fi
TRANSLATION_TEST_DIR="$(mktemp -d /private/tmp/siliconplayer-translation-tests.XXXXXX)"
TRANSLATION_REPORT_DIR="${1:-Tests/Integration/Reports}"
trap 'rm -rf "$TRANSLATION_TEST_DIR"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$TRANSLATION_REPORT_DIR"
{
    python3 - <<'PY'
from pathlib import Path
import hashlib
name = 'Sources/SiliconPlayer/SubtitleTranslationView.swift'
print(name + ' SHA-256: ' + hashlib.sha256(Path(name).read_bytes()).hexdigest(), flush=True)
PY
    xcrun swiftc -emit-library -emit-module -parse-as-library -module-name PlayerCore \
        -target arm64-apple-macos14.0 Sources/PlayerCore/[A-Z]*.swift \
        -emit-module-path "$TRANSLATION_TEST_DIR/PlayerCore.swiftmodule" -o "$TRANSLATION_TEST_DIR/libPlayerCore.dylib"
    cat Sources/SiliconPlayer/SubtitleTranslationView.swift Tests/Integration/SubtitleTranslationChecks.swift \
        > "$TRANSLATION_TEST_DIR/SubtitleTranslationChecks.swift"
    xcrun swiftc -parse-as-library -target arm64-apple-macos14.0 \
        -I "$TRANSLATION_TEST_DIR" -L "$TRANSLATION_TEST_DIR" -lPlayerCore \
        -Xlinker -rpath -Xlinker "$TRANSLATION_TEST_DIR" \
        "$TRANSLATION_TEST_DIR/SubtitleTranslationChecks.swift" -o "$TRANSLATION_TEST_DIR/SubtitleTranslationChecks"
    python3 - "$TRANSLATION_TEST_DIR/SubtitleTranslationChecks" <<'PY'
import subprocess, sys
blocks = subprocess.check_output(['otool', '-l', sys.argv[1]], text=True).split('Load command ')
links = [b for b in blocks if '/Translation.framework/' in b or '/_Translation_SwiftUI.framework/' in b]
if not links or any('LC_LOAD_WEAK_DYLIB' not in b for b in links):
    raise RuntimeError('Translation frameworks must be weak-linked for macOS 14')
print('PASS macOS 14 target compile and weak Translation framework links', flush=True)
PY
    "$TRANSLATION_TEST_DIR/SubtitleTranslationChecks"
} 2>&1 | tee "$TRANSLATION_REPORT_DIR/translation-results.txt"

#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
    echo "These encoding checks require an Apple Silicon Mac running macOS 14 or later." >&2
    exit 1
fi

CAPTURE_TEST_DIR="$(mktemp -d /private/tmp/siliconplayer-capture-tests.XXXXXX)"
CAPTURE_REPORT_DIR="${1:-Tests/Integration/Reports}"
trap 'rm -rf "$CAPTURE_TEST_DIR"' EXIT
mkdir -p "$CAPTURE_REPORT_DIR"

{
    cat Sources/SiliconPlayer/CaptureController.swift Tests/Integration/CaptureEncodingChecks.swift \
        > "$CAPTURE_TEST_DIR/CaptureEncodingChecks.swift"
    xcrun swiftc -parse-as-library -target arm64-apple-macos14.0 \
        "$CAPTURE_TEST_DIR/CaptureEncodingChecks.swift" -o "$CAPTURE_TEST_DIR/CaptureEncodingChecks"
    "$CAPTURE_TEST_DIR/CaptureEncodingChecks"
} 2>&1 | tee "$CAPTURE_REPORT_DIR/capture-encoding-results.txt"

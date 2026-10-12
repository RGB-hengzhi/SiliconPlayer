#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
    echo "These integration checks require an Apple Silicon Mac running macOS 14 or later." >&2
    exit 1
fi

NETWORK_TEST_DIR="$(mktemp -d /private/tmp/siliconplayer-network-tests.XXXXXX)"
NETWORK_REPORT_DIR="${1:-Tests/Integration/Reports}"
NETWORK_FIXTURE_PID=""
cleanup() {
    if [[ -n "$NETWORK_FIXTURE_PID" ]]; then
        kill "$NETWORK_FIXTURE_PID" 2>/dev/null || true
        wait "$NETWORK_FIXTURE_PID" 2>/dev/null || true
    fi
    rm -rf "$NETWORK_TEST_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$NETWORK_REPORT_DIR"

python3 Tests/Integration/network_fixture.py --port-file "$NETWORK_TEST_DIR/port" > "$NETWORK_TEST_DIR/fixture-output.txt" 2>&1 &
NETWORK_FIXTURE_PID=$!
for ((NETWORK_WAIT=0; NETWORK_WAIT<100; NETWORK_WAIT++)); do
    if [[ -s "$NETWORK_TEST_DIR/port" ]]; then break; fi
    if ! kill -0 "$NETWORK_FIXTURE_PID" 2>/dev/null; then
        cat "$NETWORK_TEST_DIR/fixture-output.txt" >&2
        exit 1
    fi
    sleep 0.1
done
if [[ ! -s "$NETWORK_TEST_DIR/port" ]]; then
    echo "Loopback fixture did not start within 10 seconds." >&2
    exit 1
fi

{
    xcrun swiftc -emit-library -emit-module -parse-as-library -module-name PlayerCore \
        -target arm64-apple-macos14.0 Sources/PlayerCore/[A-Z]*.swift \
        -emit-module-path "$NETWORK_TEST_DIR/PlayerCore.swiftmodule" -o "$NETWORK_TEST_DIR/libPlayerCore.dylib"
    xcrun swiftc -parse-as-library -target arm64-apple-macos14.0 \
        -I "$NETWORK_TEST_DIR" -L "$NETWORK_TEST_DIR" -lPlayerCore \
        -Xlinker -rpath -Xlinker "$NETWORK_TEST_DIR" \
        Sources/SiliconPlayer/NetworkMediaService.swift Tests/Integration/NetworkChecks.swift \
        -o "$NETWORK_TEST_DIR/NetworkChecks"
    "$NETWORK_TEST_DIR/NetworkChecks" "$NETWORK_TEST_DIR/port"
    xcrun swiftc -parse-as-library -target arm64-apple-macos14.0 \
        -I "$NETWORK_TEST_DIR" -L "$NETWORK_TEST_DIR" -lPlayerCore \
        -Xlinker -rpath -Xlinker "$NETWORK_TEST_DIR" \
        Sources/SiliconPlayer/NetworkMediaService.swift Tests/Integration/NetworkNamespaceChecks.swift \
        -o "$NETWORK_TEST_DIR/NetworkNamespaceChecks"
    "$NETWORK_TEST_DIR/NetworkNamespaceChecks"
} 2>&1 | tee "$NETWORK_REPORT_DIR/network-results.txt"

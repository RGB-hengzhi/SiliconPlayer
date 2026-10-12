#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
    echo "These thumbnail checks require Apple Silicon and macOS 14+." >&2
    exit 1
fi
THUMBNAIL_TEST_DIR="$(mktemp -d /private/tmp/siliconplayer-thumbnail-tests.XXXXXX)"
THUMBNAIL_REPORT_DIR="${1:-Tests/Integration/Reports}"
trap 'rm -rf "$THUMBNAIL_TEST_DIR"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$THUMBNAIL_REPORT_DIR"
{
    python3 - <<'PY'
from pathlib import Path
import hashlib
for name in ('Sources/SiliconPlayer/ThumbnailTools.swift', 'Sources/SiliconPlayer/MediaTools.swift'):
    print(name + ' SHA-256: ' + hashlib.sha256(Path(name).read_bytes()).hexdigest(), flush=True)
PY
    Vendor/tools/ffmpeg -hide_banner -loglevel error -nostdin -y -f lavfi \
        -i 'testsrc2=size=320x180:rate=24' -t 5 -an -c:v h264_videotoolbox -allow_sw 0 \
        -b:v 600k "$THUMBNAIL_TEST_DIR/中文 generated-video.mp4"
    Vendor/tools/ffmpeg -hide_banner -loglevel error -nostdin -y -f lavfi \
        -i 'color=c=red:size=320x180:rate=24' -t 5 -an -c:v h264_videotoolbox -allow_sw 0 \
        -b:v 600k "$THUMBNAIL_TEST_DIR/alternate.mp4"
    Vendor/tools/ffmpeg -hide_banner -loglevel error -nostdin -y -f lavfi \
        -i 'sine=frequency=440:duration=1' -c:a pcm_s16le "$THUMBNAIL_TEST_DIR/audio-only.wav"
    printf '%s\n' 'not a valid media container' > "$THUMBNAIL_TEST_DIR/damaged.mp4"
    cat Sources/SiliconPlayer/ThumbnailTools.swift Tests/Integration/ThumbnailChecks.swift > "$THUMBNAIL_TEST_DIR/ThumbnailChecks.swift"
    xcrun swiftc -parse-as-library -target arm64-apple-macos14.0 \
        Sources/SiliconPlayer/MediaTools.swift "$THUMBNAIL_TEST_DIR/ThumbnailChecks.swift" -o "$THUMBNAIL_TEST_DIR/ThumbnailChecks"
    "$THUMBNAIL_TEST_DIR/ThumbnailChecks" "$THUMBNAIL_TEST_DIR" "$THUMBNAIL_REPORT_DIR"
} 2>&1 | tee "$THUMBNAIL_REPORT_DIR/thumbnails-results.txt"

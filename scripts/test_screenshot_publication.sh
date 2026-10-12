#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "${1:-}" == "--help" ]]; then
    echo "Usage: scripts/test_screenshot_publication.sh [report-file]"
    echo "Extract actual screenshot publication helpers; verify APFS and workspace filesystems without running the app."
    exit 0
fi
task_report="${1:-$task_root/Tests/Integration/Reports/screenshot-publication-results.txt}"
task_scratch="$(mktemp -d /private/tmp/siliconplayer-publication-checks.XXXXXX)"
trap 'rm -rf "$task_scratch"' EXIT
python3 - "$task_root" "$task_scratch/checks.swift" <<'PY'
from pathlib import Path
import sys
root, output = Path(sys.argv[1]), Path(sys.argv[2])
source = (root / 'Sources/SiliconPlayer/ScreenshotActions.swift').read_text()
start, end = source.index('private struct ScreenshotFailure:'), source.index('private struct PreparedScreenshot {')
production = source[start:end]
harness = (root / 'Tests/Integration/ScreenshotPublicationChecks.swift').read_text()
output.write_text('import Foundation\nimport Darwin\n' + production + '\n' + harness)
PY
xcrun swiftc -parse-as-library -target arm64-apple-macos14.0 "$task_scratch/checks.swift" -o "$task_scratch/checks"
mkdir -p "$(dirname "$task_report")"
"$task_scratch/checks" "$task_root/Tests/Integration" | tee "$task_report"

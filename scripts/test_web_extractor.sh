#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -gt 1 ]]; then
    echo "Usage: test_web_extractor.sh [new-report-directory]" >&2
    exit 2
fi
if [[ $# -eq 1 ]]; then
    python3 Tests/Integration/WebExtractorProcessChecks.py "$1"
else
    python3 Tests/Integration/WebExtractorProcessChecks.py
fi

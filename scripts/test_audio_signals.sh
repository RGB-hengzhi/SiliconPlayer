#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 Tests/Integration/AudioSignalChecks.py "$@"

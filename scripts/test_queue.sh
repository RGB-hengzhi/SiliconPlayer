#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 Tests/Integration/run_queue_checks.py "${1:-Tests/Integration/Reports/queue-list02}"

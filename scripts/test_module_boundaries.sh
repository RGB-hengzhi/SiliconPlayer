#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 Tests/Integration/run_module_boundaries.py "${1:-Tests/Integration/Reports/module-boundaries}"

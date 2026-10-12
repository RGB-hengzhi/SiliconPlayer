#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d /tmp/siliconplayer-installed-translation.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -parse-as-library -target arm64-apple-macosx14.0 Tests/Integration/InstalledTranslationChecks.swift -o "$TEST_DIR/probe" -Xlinker -weak_framework -Xlinker Translation
"$TEST_DIR/probe" "${1:-Docs/IncrementalTest-2026-10-04/installed-translation.json}"

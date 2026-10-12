#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d /tmp/siliconplayer-screenshot.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc Sources/PlayerCore/[A-Z]*.swift Tests/Integration/ScreenshotPreferencesChecks.swift -o "$TEST_DIR/checks"
"$TEST_DIR/checks"

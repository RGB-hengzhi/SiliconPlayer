#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d /tmp/siliconplayer-core.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -D PLAYER_CORE_STANDALONE Sources/PlayerCore/[A-Z]*.swift Tests/PlayerCoreTests/[A-Z]*.swift -o "$TEST_DIR/PlayerCoreTests"
"$TEST_DIR/PlayerCoreTests"

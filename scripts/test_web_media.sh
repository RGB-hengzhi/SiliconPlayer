#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
    echo "Web media checks require Apple Silicon macOS 14 or later." >&2
    exit 1
fi
WEB_MEDIA_REPORT_DIR="${1:-Docs/IncrementalTest-0.4.0-2026-10-04/web-media-module}"
WEB_MEDIA_PROBE_DIR="${2:-Docs/IncrementalTest-0.4.0-2026-10-04/extractor-fixture-probe}"
if [[ -e "$WEB_MEDIA_REPORT_DIR/web-media-results.txt" ]]; then
    echo "Refusing to overwrite an existing web-media result; choose a fresh report directory." >&2
    exit 1
fi
WEB_MEDIA_TEST_DIR="$(mktemp -d /private/tmp/siliconplayer-web-media-tests.XXXXXX)"
cleanup() {
    python3 - "$WEB_MEDIA_TEST_DIR" <<'PY'
import pathlib, shutil, sys
p = pathlib.Path(sys.argv[1])
if p.parent == pathlib.Path('/private/tmp') and p.name.startswith('siliconplayer-web-media-tests.'):
    shutil.rmtree(p)
PY
}
trap cleanup EXIT
mkdir -p "$WEB_MEDIA_REPORT_DIR"
python3 - "$WEB_MEDIA_REPORT_DIR/inputs-before.json" "$WEB_MEDIA_PROBE_DIR" <<'PY'
import hashlib, json, pathlib, sys
paths = list(pathlib.Path('Sources/PlayerCore').glob('[A-Z]*.swift'))
paths += [pathlib.Path(p) for p in ['Sources/SiliconPlayer/WebMediaResolver.swift',
    'Sources/SiliconPlayer/PlayerModelAdvanced.swift', 'Tests/Integration/WebMediaChecks.swift', 'scripts/test_web_media.sh']]
paths += [pathlib.Path(sys.argv[2]) / (name + '.json') for name in ['progressive', 'dash', 'unknown']]
files = {str(p): {'SHA256': hashlib.sha256(p.read_bytes()).hexdigest(), 'bytes': p.stat().st_size} for p in sorted(paths)}
pathlib.Path(sys.argv[1]).write_text(json.dumps(files, ensure_ascii=False, indent=2) + '\n')
PY
{
    xcrun swiftc -emit-library -emit-module -parse-as-library -module-name PlayerCore \
        -target arm64-apple-macos14.0 Sources/PlayerCore/[A-Z]*.swift \
        -emit-module-path "$WEB_MEDIA_TEST_DIR/PlayerCore.swiftmodule" -o "$WEB_MEDIA_TEST_DIR/libPlayerCore.dylib"
    xcrun swiftc -parse-as-library -target arm64-apple-macos14.0 \
        -I "$WEB_MEDIA_TEST_DIR" -L "$WEB_MEDIA_TEST_DIR" -lPlayerCore \
        -Xlinker -rpath -Xlinker "$WEB_MEDIA_TEST_DIR" \
        Sources/SiliconPlayer/WebMediaResolver.swift Tests/Integration/WebMediaChecks.swift \
        -o "$WEB_MEDIA_TEST_DIR/WebMediaChecks"
    "$WEB_MEDIA_TEST_DIR/WebMediaChecks" "$WEB_MEDIA_PROBE_DIR"
} 2>&1 | tee "$WEB_MEDIA_REPORT_DIR/web-media-results.txt"
python3 - "$WEB_MEDIA_REPORT_DIR" <<'PY'
import hashlib, json, pathlib, sys
report = pathlib.Path(sys.argv[1])
before = json.loads((report / 'inputs-before.json').read_text())
after = {name: {'SHA256': hashlib.sha256(pathlib.Path(name).read_bytes()).hexdigest(), 'bytes': pathlib.Path(name).stat().st_size} for name in before}
(report / 'inputs-after.json').write_text(json.dumps(after, ensure_ascii=False, indent=2) + '\n')
rows = [line[5:] for line in (report / 'web-media-results.txt').read_text().splitlines() if line.startswith('PASS ')]
passed = before == after and len(rows) == len(set(rows)) == 22
summary = {'passed': passed, 'scenarioCount': len(rows), 'uniqueScenarioCount': len(set(rows)), 'inputsUnchanged': before == after,
    'scope': 'Production models and controlled real subprocesses, plus frozen real extractor JSON; no player/native GUI/live-site playback', 'scenarios': rows}
(report / 'summary.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2) + '\n')
if not passed:
    raise SystemExit('Input hashes or independent scenario count did not match')
PY

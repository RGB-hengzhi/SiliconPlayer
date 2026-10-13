#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"
export COPYFILE_DISABLE=1
BUILD_PROFILE="${SILICONPLAYER_BUILD_PROFILE:-full}"
case "$BUILD_PROFILE" in
    full) DEFAULT_OUTPUT_APP="$PROJECT_ROOT/dist/SiliconPlayer-development.app" ;;
    core) DEFAULT_OUTPUT_APP="$PROJECT_ROOT/dist/SiliconPlayer-core-development.app" ;;
    *) echo "SILICONPLAYER_BUILD_PROFILE must be full or core." >&2; exit 1 ;;
esac
OUTPUT_APP="${SILICONPLAYER_OUTPUT_APP:-$DEFAULT_OUTPUT_APP}"
python3 - "$PROJECT_ROOT" "$OUTPUT_APP" <<'PY'
from pathlib import Path
import sys
root, target = (Path(value).resolve() for value in sys.argv[1:])
if target.suffix != '.app' or target == root:
    raise SystemExit('Output must name a distinct .app path.')
if root / 'ReleaseBaselines' in target.parents:
    raise SystemExit('ReleaseBaselines are immutable; choose a new candidate output.')
if target.exists() and target.name not in ('SiliconPlayer-development.app', 'SiliconPlayer-core-development.app'):
    raise SystemExit('Existing candidate/release bundles are preserved; choose a new output.')
PY

if [[ "$(uname -m)" != "arm64" ]]; then
    echo "SiliconPlayer requires an Apple Silicon Mac." >&2
    exit 1
fi
if [[ ! -f Vendor/lib/libmpv.dylib || ! -f Vendor/manifest.json ]]; then
    if [[ "$BUILD_PROFILE" == "core" ]]; then
        echo "Core builds require pre-materialized libmpv dependencies; no download was started." >&2
        exit 1
    fi
    python3 scripts/bootstrap_mpv.py
fi
python3 scripts/bootstrap_mpv.py --verify
if [[ "$BUILD_PROFILE" == "full" ]]; then
if [[ ! -f Vendor/tools/manifest.json ]]; then
    python3 scripts/bootstrap_media_tools.py
fi
python3 scripts/bootstrap_media_tools.py --verify
if [[ ! -f Vendor/WebTools/manifest.json ]]; then
    WEB_BUILD_PYTHON="${SILICONPLAYER_WEB_BUILD_PYTHON:-$HOME/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3}"
    python3 scripts/bootstrap_web_tools.py --build-python "$WEB_BUILD_PYTHON"
fi
python3 scripts/bootstrap_web_tools.py --verify
else
# Verify only the media tools that the core bundle will actually contain. A
# core build never materializes Whisper, WebTools or Live ASR dependencies.
python3 - "$PROJECT_ROOT/Vendor/tools" <<'PY'
from pathlib import Path
import hashlib
import json
import subprocess
import sys
root = Path(sys.argv[1])
manifest = root / 'manifest.json'
if manifest.is_symlink() or not manifest.is_file():
    raise SystemExit('Core builds require a materialized media-tools manifest; no download was started.')
value = json.loads(manifest.read_text())
required = {'ffmpeg', 'ffprobe', 'licenses/FFmpeg-COPYING.LGPLv2.1',
            'licenses/FFmpeg-COPYING.LGPLv3', 'licenses/FFmpeg-LICENSE.md'}
rows = [row for row in value['files'] if row['path'] in required]
if len(rows) != len(required) or {row['path'] for row in rows} != required:
    raise SystemExit('Core FFmpeg files must be declared exactly once in the pinned manifest.')
for row in rows:
    path = root / row['path']
    if path.is_symlink() or not path.is_file() or path.stat().st_size != row['bytes']:
        raise SystemExit('Invalid core media tool: ' + row['path'])
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    if digest.hexdigest() != row['sha256']:
        raise SystemExit('Core media tool hash mismatch: ' + row['path'])
    if row['path'] in ('ffmpeg', 'ffprobe'):
        if not row.get('executable') or subprocess.check_output(['lipo', '-archs', str(path)], text=True).strip() != 'arm64':
            raise SystemExit('Core media tools require arm64 executable inputs.')
        for line in subprocess.check_output(['otool', '-L', str(path)], text=True).splitlines()[1:]:
            if not line.strip().split(' (', 1)[0].startswith(('/usr/lib/', '/System/Library/')):
                raise SystemExit('Non-system core media-tool dependency: ' + row['path'])
print('Core FFmpeg/ffprobe hashes, arm64 architecture and system-only dependencies verified.')
PY
fi

# ASR assets are materialized explicitly, never fetched from a Docs cache while
# packaging. Helper build verifies the complete fixed Vendor/model inventories.
LIVE_ASR_PINS="$PROJECT_ROOT/Resources/live-asr-package-pins.json"
LIVE_ASR_PINS_SHA256="96dbba05ab9767347a2fe60d248cd2085486bb1d5fd5dd5f12c0317c448dfa2e"
if [[ "$BUILD_PROFILE" == "full" ]]; then
for LIVE_ASR_INPUT in "$LIVE_ASR_PINS" "$PROJECT_ROOT/Vendor/LiveASR/manifest.json" \
    "$PROJECT_ROOT/Vendor/LiveASRModel/model-manifest.json"; do
    if [[ ! -f "$LIVE_ASR_INPUT" || -L "$LIVE_ASR_INPUT" ]]; then
        echo "Materialized Live ASR dependency required: $LIVE_ASR_INPUT" >&2
        exit 1
    fi
done
fi

# SwiftPM creates symlinks, so its cache must live on APFS rather than exFAT.
# Final application output remains in this project's dist directory.
PROJECT_KEY="$(printf '%s' "$PROJECT_ROOT" | shasum -a 256 | cut -c1-12)"
BUILD_CACHE="${SILICONPLAYER_BUILD_CACHE:-$HOME/Library/Caches/SiliconPlayer/$PROJECT_KEY}"
mkdir -p "$BUILD_CACHE"
if [[ "$BUILD_PROFILE" == "full" ]]; then
LIVE_ASR_BUILD_REPORT_ROOT="$(mktemp -d "$BUILD_CACHE/live-asr-build.XXXXXX")"
echo "Live ASR build evidence: $LIVE_ASR_BUILD_REPORT_ROOT"
fi
BUILD_INPUTS="$BUILD_CACHE/build-inputs-before.json"
# macOS /bin/bash 3.2 rejects an empty array expansion with nounset enabled.
PROVENANCE_ARGS=(--profile "$BUILD_PROFILE")
SWIFT_BUILD_ARGS=(--scratch-path "$BUILD_CACHE/swift-build" -c release --arch arm64)
if [[ "$BUILD_PROFILE" == "core" ]]; then
    SWIFT_BUILD_ARGS+=(--product SiliconPlayer)
fi
python3 scripts/build_provenance.py before "$BUILD_INPUTS" "${PROVENANCE_ARGS[@]}"
swift build "${SWIFT_BUILD_ARGS[@]}"
BINARY_DIR="$(swift build "${SWIFT_BUILD_ARGS[@]}" --show-bin-path)"

STAGING_APP="$BUILD_CACHE/SiliconPlayer.app"
rm -rf "$STAGING_APP"
mkdir -p "$STAGING_APP/Contents/MacOS" "$STAGING_APP/Contents/Frameworks" "$STAGING_APP/Contents/Resources"
cp "$BINARY_DIR/SiliconPlayer" "$STAGING_APP/Contents/MacOS/SiliconPlayer"
# The system Swift runtime and bundled Frameworks resolve every runtime load.
# SwiftPM also adds its build toolchain path; remove that development search path
# from the distributed executable before signing.
python3 - "$STAGING_APP/Contents/MacOS/SiliconPlayer" <<'PY'
import re
import subprocess
import sys
binary = sys.argv[1]
commands = subprocess.check_output(['otool', '-l', binary], text=True)
for path in re.findall(r'cmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset', commands):
    if path.startswith('/Library/Developer/') or path.startswith('/Applications/Xcode'):
        subprocess.run(['install_name_tool', '-delete_rpath', path, binary], check=True)
PY
cp Resources/Info.plist "$STAGING_APP/Contents/Info.plist"
python3 - "$STAGING_APP/Contents/Info.plist" "$BUILD_PROFILE" <<'PY'
from pathlib import Path
import plistlib
import sys
path = Path(sys.argv[1])
profile = sys.argv[2]
value = plistlib.loads(path.read_bytes())
value['SiliconPlayerCapabilities'] = {'schema': 1, 'profile': profile, 'features': {
    'mediaTools': True, 'webMediaExtractor': profile == 'full',
    'offlineSpeechRecognition': profile == 'full', 'liveSpeechRecognition': profile == 'full'}}
path.write_bytes(plistlib.dumps(value, sort_keys=False))
PY

# The linker alias has the same install id; bundle just the canonical dylib.
for LIBRARY in Vendor/lib/*.dylib; do
    [[ "$(basename "$LIBRARY")" == "libmpv.dylib" ]] && continue
    cp "$LIBRARY" "$STAGING_APP/Contents/Frameworks/"
done
python3 - "$PROJECT_ROOT/Vendor/licenses" "$STAGING_APP/Contents/Resources/Licenses" <<'PY'
from pathlib import Path
import shutil
import sys
source, target = map(Path, sys.argv[1:])
target.mkdir(parents=True, exist_ok=True)
for path in source.rglob("*"):
    relative = path.relative_to(source)
    if path.is_file() and not any(part.startswith("._") for part in relative.parts):
        destination = target / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        # Copy data only. exFAT AppleDouble metadata must not become resources.
        shutil.copyfile(path, destination)
PY
python3 - "$PROJECT_ROOT/Resources/PublicLicenses" "$STAGING_APP/Contents/Resources/Licenses" <<'PY'
from pathlib import Path
import shutil
import sys
source, target = map(Path, sys.argv[1:])
if source.is_symlink() or not source.is_dir():
    raise SystemExit('Public license resources are required before packaging.')
for path in source.rglob('*'):
    relative = path.relative_to(source)
    if any(part.startswith('._') for part in relative.parts):
        continue
    if path.is_symlink():
        raise SystemExit(f'Public license resources must be regular files: {relative}')
    if path.is_file():
        destination = target / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, destination)
        destination.chmod(0o644)
PY
if [[ "$BUILD_PROFILE" == "full" ]]; then
python3 - "$PROJECT_ROOT/Vendor/WebTools" "$STAGING_APP/Contents/Resources/WebTools" <<'PY'
from pathlib import Path
import shutil
import sys
source, target = map(Path, sys.argv[1:])
for path in source.rglob('*'):
    relative = path.relative_to(source)
    if any(part.startswith('._') for part in relative.parts):
        continue
    if path.is_symlink():
        raise SystemExit(f'WebTools must be materialized before packaging: {relative}')
    if path.is_file():
        destination = target / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, destination)
        destination.chmod(path.stat().st_mode & 0o777)
PY
cp "$BINARY_DIR/web-extractor" "$STAGING_APP/Contents/Resources/WebTools/web-extractor"
chmod 755 "$STAGING_APP/Contents/Resources/WebTools/web-extractor" \
    "$STAGING_APP/Contents/Resources/WebTools/yt-dlp/yt-dlp_macos" \
    "$STAGING_APP/Contents/Resources/WebTools/deno"
fi
cp Vendor/manifest.json "$STAGING_APP/Contents/Resources/dependency-manifest.json"
python3 - "$PROJECT_ROOT/Vendor/tools" "$STAGING_APP/Contents/Resources/Tools" "$BUILD_PROFILE" <<'PY'
from pathlib import Path
import json
import shutil
import sys
source, target = map(Path, sys.argv[1:3])
profile = sys.argv[3]
selected = {'ffmpeg', 'ffprobe', 'licenses/FFmpeg-COPYING.LGPLv2.1',
            'licenses/FFmpeg-COPYING.LGPLv3', 'licenses/FFmpeg-LICENSE.md'}
for path in source.rglob('*'):
    relative = path.relative_to(source)
    if profile == 'core' and str(relative) not in selected:
        continue
    if path.is_file() and 'validation' not in relative.parts and not any(part.startswith('._') for part in relative.parts):
        destination = target / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, destination)
        if path.name in ('ffmpeg', 'ffprobe', 'whisper-cli'):
            destination.chmod(0o755)
if profile == 'core':
    original = json.loads((source / 'manifest.json').read_text())
    value = {key: original[key] for key in ('schema', 'architecture', 'minimum_macos', 'ffmpeg', 'ffmpeg_configure')}
    value.update(profile='core', files=[row for row in original['files'] if row['path'] in selected],
                 corresponding_sources=[original['ffmpeg']['url']])
    (target / 'manifest.json').write_text(json.dumps(value, indent=2) + '\n')
PY
if [[ "$BUILD_PROFILE" == "full" ]]; then
python3 scripts/build_live_asr_helpers.py build \
    --pins "$LIVE_ASR_PINS" --expected-pins-sha256 "$LIVE_ASR_PINS_SHA256" \
    --project-root "$PROJECT_ROOT" --vendor-root "$PROJECT_ROOT/Vendor/LiveASR" \
    --model-directory "$PROJECT_ROOT/Vendor/LiveASRModel" --staging-app "$STAGING_APP" \
    --work-directory "$LIVE_ASR_BUILD_REPORT_ROOT/work" \
    --report-directory "$LIVE_ASR_BUILD_REPORT_ROOT/helper-build"
fi
if [[ -f LICENSE ]]; then
    cp LICENSE "$STAGING_APP/Contents/Resources/SiliconPlayer-LICENSE.txt"
fi
if [[ -d Resources ]]; then
    while IFS= read -r -d '' RESOURCE; do
        [[ "$RESOURCE" == "Resources/Info.plist" ]] && continue
        [[ "$BUILD_PROFILE" == "core" && "$RESOURCE" == "Resources/live-asr-package-pins.json" ]] && continue
        [[ "$(basename "$RESOURCE")" == ._* ]] && continue
        cp "$RESOURCE" "$STAGING_APP/Contents/Resources/"
    done < <(find Resources -maxdepth 1 -type f -print0)
fi
xattr -cr "$STAGING_APP"
python3 - "$STAGING_APP" <<'PY'
from pathlib import Path
import sys
for path in Path(sys.argv[1]).rglob("._*"):
    if path.is_file():
        path.unlink(missing_ok=True)
PY
MACHO_LIST="$BUILD_CACHE/macho-inputs.nul"
python3 - "$STAGING_APP" "$MACHO_LIST" <<'PY'
from pathlib import Path
import sys
magic = {b'\xfe\xed\xfa\xce', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xcf\xfa\xed\xfe',
         b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca', b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca'}
paths = []
for path in sorted(Path(sys.argv[1]).rglob('*')):
    if path.is_file():
        with path.open('rb') as stream:
            if stream.read(4) in magic:
                paths.append(str(path).encode('utf-8') + b'\0')
if not paths:
    raise SystemExit('No Mach-O inputs found; signing aborted.')
Path(sys.argv[2]).write_bytes(b''.join(paths))
PY
while IFS= read -r -d '' MACHO; do
    ARCHS="$(lipo -archs "$MACHO")"
    if [[ "$ARCHS" != "arm64" ]]; then
        echo "Unexpected architecture '$ARCHS' in $MACHO" >&2
        exit 1
    fi
    codesign --force --sign - --timestamp=none "$MACHO"
done < "$MACHO_LIST"

# The validator consumes signed nested bytes while capability is still false.
# Testing never mutates that initial manifest midway through its run.
if [[ "$BUILD_PROFILE" == "full" ]]; then
python3 scripts/build_live_asr_helpers.py finalize-runtime \
    --pins "$LIVE_ASR_PINS" --expected-pins-sha256 "$LIVE_ASR_PINS_SHA256" \
    --staging-app "$STAGING_APP" \
    --report-directory "$LIVE_ASR_BUILD_REPORT_ROOT/initial-runtime"
LIVE_ASR_PCM_BINARY="$STAGING_APP/Contents/Resources/LiveASR/Helpers/media-pcm-pts"
LIVE_ASR_PCM_SHA256="$(shasum -a 256 "$LIVE_ASR_PCM_BINARY" | cut -d ' ' -f 1)"
if [[ ! -f scripts/verify_live_asr_pcm.py ]]; then
    echo "Signed Live ASR PCM verification script is required before packaging." >&2
    exit 1
fi
python3 scripts/verify_live_asr_pcm.py \
    --pcm-binary "$LIVE_ASR_PCM_BINARY" --expected-pcm-sha256 "$LIVE_ASR_PCM_SHA256" \
    --report-directory "$LIVE_ASR_BUILD_REPORT_ROOT/signed-pcm-verification" \
    --fixture-root "$PROJECT_ROOT/Tests/Fixtures" --project-root "$PROJECT_ROOT" \
    --ffprobe "$STAGING_APP/Contents/Resources/Tools/ffprobe"
LIVE_ASR_GRACEFUL_EVIDENCE="$LIVE_ASR_BUILD_REPORT_ROOT/signed-pcm-verification/capability-evidence.json"
# finalize-runtime rejects overwrites. Preserve the verified false manifest's
# exact bytes in this build's fresh report directory, then generate the true
# manifest from the same signed bytes and newly completed 19-case evidence.
python3 - "$STAGING_APP" "$LIVE_ASR_BUILD_REPORT_ROOT/initial-runtime-manifest.json" <<'PY'
from pathlib import Path
import json
import sys
bundle, preserved = map(Path, sys.argv[1:])
source = bundle / 'Contents/Resources/LiveASR/runtime-manifest.json'
if source.is_symlink() or not source.is_file() or preserved.exists():
    raise SystemExit('Owned initial runtime manifest cannot be preserved.')
value = json.loads(source.read_text())
if value.get('features', {}).get('gracefulInputLimit', {}).get('verified') is not False:
    raise SystemExit('Expected the initial unverified runtime manifest.')
source.rename(preserved)
PY
python3 scripts/build_live_asr_helpers.py finalize-runtime \
    --pins "$LIVE_ASR_PINS" --expected-pins-sha256 "$LIVE_ASR_PINS_SHA256" \
    --staging-app "$STAGING_APP" --graceful-evidence "$LIVE_ASR_GRACEFUL_EVIDENCE" \
    --report-directory "$LIVE_ASR_BUILD_REPORT_ROOT/finalize-runtime"
fi
python3 scripts/build_provenance.py verify "$BUILD_INPUTS" --bundle "$STAGING_APP" "${PROVENANCE_ARGS[@]}"
codesign --force --sign - --timestamp=none "$STAGING_APP"
codesign --verify --deep --strict "$STAGING_APP"
plutil -lint "$STAGING_APP/Contents/Info.plist"

mkdir -p dist
if [[ "$OUTPUT_APP" != *.app || "$OUTPUT_APP" == "$STAGING_APP" ]]; then
    echo "SILICONPLAYER_OUTPUT_APP must name a distinct .app output path." >&2
    exit 1
fi
mkdir -p "$(dirname "$OUTPUT_APP")"
rm -rf "$OUTPUT_APP"
ditto --norsrc --noextattr "$STAGING_APP" "$OUTPUT_APP"
python3 - "$OUTPUT_APP" <<'PY'
from pathlib import Path
import sys
for path in Path(sys.argv[1]).rglob("._*"):
    if path.is_file():
        path.unlink(missing_ok=True)
PY
codesign --verify --deep --strict "$OUTPUT_APP"
echo "Built arm64 application: $OUTPUT_APP"
echo "Local GPL prototype: ad hoc signed, not notarized or cleared for distribution."

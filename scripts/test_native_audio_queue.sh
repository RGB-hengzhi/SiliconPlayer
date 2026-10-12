#!/bin/bash
# Draft: execute only after reviewed production apply and Root authorization.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]]
NATIVE_AUDIO_REPORT="${1:?fresh report directory required}"
[[ ! -e "$NATIVE_AUDIO_REPORT" ]] || { echo 'Refusing existing evidence leaf' >&2; exit 1; }
mkdir -p "$NATIVE_AUDIO_REPORT"
NATIVE_AUDIO_APFS="$(mktemp -d /private/tmp/siliconplayer-native-audio.XXXXXX)"
trap 'rm -rf "$NATIVE_AUDIO_APFS"' EXIT
mkdir "$NATIVE_AUDIO_APFS/fixtures"
python3 - "$NATIVE_AUDIO_REPORT/inputs-before.json" <<'PY'
import hashlib,json,pathlib,sys
paths=list(pathlib.Path('Sources/PlayerCore').glob('[A-Z]*.swift'))
paths += [pathlib.Path('Sources/SiliconPlayer')/n for n in ['NativeQueueRuntimeIdentity.swift','NativeQueueHistoryLedger.swift','NativeAudioPreparedPlan.swift','NativeLocalAudioInspector.swift']]
paths += [pathlib.Path('Tests/Integration/NativeAudioQueueChecks.swift'),pathlib.Path('scripts/test_native_audio_queue.sh'),pathlib.Path('Vendor/tools/ffmpeg'),pathlib.Path('Vendor/tools/ffprobe')]
obj={str(p):{'SHA256':hashlib.sha256(p.read_bytes()).hexdigest(),'bytes':p.stat().st_size} for p in paths if not p.name.startswith('._')}
pathlib.Path(sys.argv[1]).write_text(json.dumps(obj,ensure_ascii=False,indent=2)+'\n')
PY
Vendor/tools/ffmpeg -v error -f lavfi -i 'sine=frequency=440:sample_rate=48000:duration=2' -ac 2 -channel_layout stereo -c:a pcm_s24le "$NATIVE_AUDIO_APFS/fixtures/A 中文.wav"
Vendor/tools/ffmpeg -v error -f lavfi -i 'sine=frequency=660:sample_rate=48000:duration=2' -ac 2 -channel_layout stereo -sample_fmt s32 -c:a flac "$NATIVE_AUDIO_APFS/fixtures/B 空格.flac"
{
 xcrun swiftc -emit-library -emit-module -parse-as-library -module-name PlayerCore -target arm64-apple-macos14.0 \
  Sources/PlayerCore/[A-Z]*.swift -emit-module-path "$NATIVE_AUDIO_APFS/PlayerCore.swiftmodule" -o "$NATIVE_AUDIO_APFS/libPlayerCore.dylib"
 xcrun swiftc -parse-as-library -target arm64-apple-macos14.0 -I "$NATIVE_AUDIO_APFS" -L "$NATIVE_AUDIO_APFS" -lPlayerCore \
  -Xlinker -rpath -Xlinker "$NATIVE_AUDIO_APFS" Sources/SiliconPlayer/NativeQueueRuntimeIdentity.swift \
  Sources/SiliconPlayer/NativeQueueHistoryLedger.swift Sources/SiliconPlayer/NativeAudioPreparedPlan.swift \
  Sources/SiliconPlayer/NativeLocalAudioInspector.swift Tests/Integration/NativeAudioQueueChecks.swift -o "$NATIVE_AUDIO_APFS/NativeAudioQueueChecks"
 "$NATIVE_AUDIO_APFS/NativeAudioQueueChecks" "$NATIVE_AUDIO_APFS/fixtures" "$PWD/Vendor/tools"
 file "$NATIVE_AUDIO_APFS/NativeAudioQueueChecks"
} 2>&1 | tee "$NATIVE_AUDIO_REPORT/results.txt"
cp -R "$NATIVE_AUDIO_APFS/fixtures" "$NATIVE_AUDIO_REPORT/fixtures"
python3 - "$NATIVE_AUDIO_REPORT" <<'PY'
import hashlib,json,pathlib,sys
r=pathlib.Path(sys.argv[1]);before=json.loads((r/'inputs-before.json').read_text())
after={n:{'SHA256':hashlib.sha256(pathlib.Path(n).read_bytes()).hexdigest(),'bytes':pathlib.Path(n).stat().st_size} for n in before}
(r/'inputs-after.json').write_text(json.dumps(after,ensure_ascii=False,indent=2)+'\n')
lines=(r/'results.txt').read_text().splitlines(); rows=[s[5:] for s in lines if s.startswith('PASS ')]
expected=['native-audio.event-ticket-late-receipt','native-audio.history-all-loaded-own-duration','native-audio.history-newer-original-url-wins','native-audio.plan-window-preserves-queue-resume-boundary','native-audio.real-inspector-file-and-discovery-proof']
arm=any('NativeAudioQueueChecks: Mach-O 64-bit executable arm64' in s for s in lines)
passed=rows==expected and len(set(rows))==5 and before==after and arm
obj={'status':'passed' if passed else 'failed','scenarioCount':len(rows),'expected':expected,'scenarios':rows,'arm64':arm,'inputsUnchanged':before==after,'appGroups':0,'videoLifecycleTested':False,'physicalGaplessTested':False,'scope':'New actual receipt/history/plan bodies plus bundled real ffprobe fixtures; no coordinator/App/physical device acceptance'}
(r/'summary.json').write_text(json.dumps(obj,ensure_ascii=False,indent=2)+'\n')
if not passed:sys.exit(1)
PY

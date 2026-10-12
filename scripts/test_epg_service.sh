#!/bin/bash
# Production EPG service/cache/preferences and View typecheck; no app startup.
set -euo pipefail
prototype_dir="$(cd "$(dirname "$0")/.." && pwd)"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/silicon-epg-service-XXXXXX")"
report_dir="${1:-$work_dir/report}"
if [ -e "$report_dir" ]; then
    echo "Choose a new report directory; existing evidence is never replaced." >&2
    exit 2
fi
mkdir -p "$report_dir"
inputs=( "$prototype_dir/Sources/PlayerCore/XMLTVDocument.swift" "$prototype_dir/Sources/PlayerCore/EPGChannelMapping.swift" "$prototype_dir/Sources/PlayerCore/EPGCatalog.swift" "$prototype_dir/Sources/SiliconPlayer/EPGTransport.swift" "$prototype_dir/Sources/SiliconPlayer/EPGLogoCache.swift" "$prototype_dir/Sources/SiliconPlayer/EPGPreferences.swift" "$prototype_dir/Sources/SiliconPlayer/EPGPreferencesDuplicateKeys.swift" "$prototype_dir/Sources/SiliconPlayer/EPGService.swift" )
python3 - "$prototype_dir" "$report_dir/inputs-before.json" <<'PY'
import hashlib,json,pathlib,sys
root=pathlib.Path(sys.argv[1])
files=[root/'Sources/PlayerCore'/name for name in ['XMLTVDocument.swift','EPGChannelMapping.swift','EPGCatalog.swift']]+[root/'Sources/SiliconPlayer'/name for name in ['EPGTransport.swift','EPGLogoCache.swift','EPGPreferences.swift','EPGPreferencesDuplicateKeys.swift','EPGService.swift','EPGView.swift']]+[root/'Tests/Integration/EPG/ServiceChecks.swift',root/'scripts/test_epg_service.sh']
pathlib.Path(sys.argv[2]).write_text(json.dumps({str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files},indent=2)+'\n')
PY
set +e
xcrun swiftc -target arm64-apple-macosx14.0 -swift-version 5 -parse-as-library \
    "${inputs[@]}" "$prototype_dir/Tests/Integration/EPG/ServiceChecks.swift" \
    -o "$work_dir/epg-service-tests" >"$report_dir/build.log" 2>&1
compile_exit=$?
set -e
if [ "$compile_exit" -ne 0 ]; then
    python3 - "$report_dir/summary.json" "$compile_exit" <<'PY'
import json,pathlib,sys
pathlib.Path(sys.argv[1]).write_text(json.dumps({'status':'failed_compile','compileExitCode':int(sys.argv[2]),'executedScenarioGroups':0,'passed':0},indent=2)+'\n')
PY
    exit "$compile_exit"
fi
set +e
xcrun swiftc -target arm64-apple-macosx14.0 -swift-version 5 -typecheck \
    "${inputs[@]}" "$prototype_dir/Sources/SiliconPlayer/EPGView.swift" >"$report_dir/view-typecheck.log" 2>&1
view_exit=$?
set -e
cp "$work_dir/epg-service-tests" "$report_dir/compiled-epg-service-tests"
lipo -archs "$work_dir/epg-service-tests" >"$report_dir/architectures.txt"
set +e
"$work_dir/epg-service-tests" "$report_dir/results" >"$report_dir/results.txt" 2>&1
test_exit=$?
set -e
python3 - "$prototype_dir" "$report_dir" "$test_exit" "$view_exit" <<'PY'
from datetime import datetime,timezone
import hashlib,json,pathlib,sys
root,report=pathlib.Path(sys.argv[1]),pathlib.Path(sys.argv[2])
before=json.loads((report/'inputs-before.json').read_text())
after={p:hashlib.sha256((root/p).read_bytes()).hexdigest() for p in before}
(report/'inputs-after.json').write_text(json.dumps(after,indent=2)+'\n')
result_file=report/'results/summary.json'
results=json.loads(result_file.read_text()) if result_file.exists() else {'status':'failed','results':[],'passed':0,'failed':1}
names=[r['case'] for r in results.get('results',[])]
valid=int(sys.argv[3])==0 and int(sys.argv[4])==0 and results.get('status')=='passed' and len(names)==25 and len(set(names))==25 and before==after
summary={'recordedUTC':datetime.now(timezone.utc).isoformat(),'status':'passed' if valid else 'failed',
 'scope':'Production EPG service and ImageIO/cache/preferences with controlled mocks; EPGView typecheck only, no actual app/HTTP/UI acceptance.',
 'uniqueScenarioGroups':len(names),'passed':results.get('passed',0),'failed':results.get('failed',1),'compileExitCode':0,'viewTypecheckExitCode':int(sys.argv[4]),'testExitCode':int(sys.argv[3]),
 'inputHashesUnchanged':before==after,'actualArchitectures':(report/'architectures.txt').read_text().strip(),
 'executableSHA256':hashlib.sha256((report/'compiled-epg-service-tests').read_bytes()).hexdigest(),
 'actualHTTPRun':False,'actualAppGUIRun':False,'productionTransportAdapterTypechecked':False,'results':results.get('results',[])}
(report/'summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2)+'\n')
if not valid: sys.exit(1)
PY
cat "$report_dir/results.txt"

#!/bin/bash
# Actual production-model/service/cache/preferences/loopback EPG checks.
# Does not start the application or claim physical UI acceptance.
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/silicon-epg-XXXXXX")"
report_dir="${1:-$work_dir/report}"
if [ -e "$report_dir" ]; then echo "Choose a new EPG report directory." >&2; exit 2; fi
mkdir -p "$report_dir"
python3 - "$project_dir" "$report_dir" <<'PY'
import hashlib,json,pathlib,sys
root,report=map(pathlib.Path,sys.argv[1:])
files=[root/'Sources/PlayerCore'/name for name in ['XMLTVDocument.swift','EPGChannelMapping.swift','EPGCatalog.swift','ChannelDocument.swift','PlaylistDocument.swift']]
files += [p for p in sorted((root/'Sources/SiliconPlayer').glob('EPG*.swift')) if not p.name.startswith('.')]+[root/'Sources/SiliconPlayer/NetworkMediaView.swift',root/'Sources/SiliconPlayer/NetworkMediaService.swift']
files += [p for p in sorted((root/'Tests/Integration/EPG').glob('*')) if p.is_file() and not p.name.startswith('.')]+[root/'scripts'/name for name in ['test_epg.sh','test_epg_service.sh','test_epg_http.sh']]
(report/'inputs-before.json').write_text(json.dumps({str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files},indent=2)+'\n')
source=(root/'Sources/PlayerCore/PlaylistDocument.swift').read_text()
(report/'DocumentTextDecoder-production-excerpt.swift').write_text('import Foundation\nimport CoreFoundation\nenum DocumentTextDecoder {'+source.split('enum DocumentTextDecoder {',1)[1])
PY
core_sources=( "$project_dir/Sources/PlayerCore/XMLTVDocument.swift" "$project_dir/Sources/PlayerCore/EPGChannelMapping.swift" "$project_dir/Sources/PlayerCore/EPGCatalog.swift" )
for family in core channels; do
    mkdir -p "$report_dir/$family"
    if [ "$family" = core ]; then
        test_file="$project_dir/Tests/Integration/EPG/CoreChecks.swift"
        compile_sources=( "${core_sources[@]}" )
    else
        test_file="$project_dir/Tests/Integration/EPG/ChannelChecks.swift"
        compile_sources=( "${core_sources[@]}" "$project_dir/Sources/PlayerCore/ChannelDocument.swift" "$report_dir/DocumentTextDecoder-production-excerpt.swift" )
    fi
    set +e
    xcrun swiftc -target arm64-apple-macosx14.0 -swift-version 5 -parse-as-library \
        "${compile_sources[@]}" "$test_file" -o "$work_dir/$family-tests" >"$report_dir/$family/build.log" 2>&1
    compile_exit=$?
    set -e
    if [ "$compile_exit" -ne 0 ]; then
        python3 - "$report_dir/summary.json" "$family" "$compile_exit" <<'PY'
import json,pathlib,sys
pathlib.Path(sys.argv[1]).write_text(json.dumps({'status':'failed_compile','family':sys.argv[2],'compileExitCode':int(sys.argv[3]),'passed':0},indent=2)+'\n')
PY
        exit "$compile_exit"
    fi
    cp "$work_dir/$family-tests" "$report_dir/$family/compiled-tests"
    lipo -archs "$work_dir/$family-tests" >"$report_dir/$family/architectures.txt"
    set +e
    "$work_dir/$family-tests" >"$report_dir/$family/results.txt" 2>&1
    test_exit=$?
    set -e
    python3 - "$report_dir/$family" "$test_exit" <<'PY'
import hashlib,json,pathlib,sys
report=pathlib.Path(sys.argv[1]); lines=(report/'results.txt').read_text().splitlines()
ids=[line.removeprefix('PASS ') for line in lines if line.startswith('PASS ')]
failed=[line for line in lines if line.startswith('FAIL ')]
expected=15 if report.name=='core' else 7
valid=int(sys.argv[2])==0 and len(ids)==expected and len(set(ids))==expected and not failed
summary={'status':'passed' if valid else 'failed','uniqueScenarioGroups':expected,'passed':len(ids),'failed':len(failed),'compileExitCode':0,'testExitCode':int(sys.argv[2]),'actualArchitectures':(report/'architectures.txt').read_text().strip(),'executableSHA256':hashlib.sha256((report/'compiled-tests').read_bytes()).hexdigest(),'passedScenarioIDs':ids,'failures':failed}
(report/'summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2)+'\n')
if not valid: sys.exit(1)
PY
    cat "$report_dir/$family/results.txt"
done
bash "$project_dir/scripts/test_epg_service.sh" "$report_dir/service"
bash "$project_dir/scripts/test_epg_http.sh" "$report_dir/http"
python3 - "$project_dir" "$report_dir" <<'PY'
from datetime import datetime,timezone
import hashlib,json,pathlib,sys
root,report=map(pathlib.Path,sys.argv[1:])
before=json.loads((report/'inputs-before.json').read_text()); after={name:hashlib.sha256((root/name).read_bytes()).hexdigest() for name in before}
(report/'inputs-after.json').write_text(json.dumps(after,indent=2)+'\n')
families={name:json.loads((report/name/'summary.json').read_text()) for name in ['core','channels','service','http']}
expected={'core':15,'channels':7,'service':25,'http':11}
valid=before==after and all(value['status']=='passed' and value['passed']==expected[name] and value['failed']==0 for name,value in families.items())
summary={'recordedUTC':datetime.now(timezone.utc).isoformat(),'status':'passed' if valid else 'failed','passed':sum(v['passed'] for v in families.values()),'failed':sum(v['failed'] for v in families.values()),'uniqueScenarioGroups':58,'inputHashesUnchanged':before==after,'scope':'Production EPG model/channel migration/service/cache/preferences and actual loopback HTTP. EPGView typechecked. No app or physical UI acceptance.','actualAppGUIRun':False,'actualLoopbackHTTPRun':True,'familyCounts':expected,'familyReports':{name:{'path':name+'/summary.json','sha256':hashlib.sha256((report/name/'summary.json').read_bytes()).hexdigest(),'status':value['status']} for name,value in families.items()}}
(report/'summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2)+'\n')
if not valid: sys.exit(1)
PY

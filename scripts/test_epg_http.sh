#!/bin/bash
# Actual loopback-only transport tests; never starts the player or GUI.
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
prototype_dir="$project_dir"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/silicon-epg-http-XXXXXX")"
report_dir="${1:-$work_dir/report}"
if [ -e "$report_dir" ]; then echo "Choose a new evidence directory." >&2; exit 2; fi
mkdir -p "$report_dir"
python3 - "$project_dir" "$prototype_dir" "$report_dir" <<'PY'
import hashlib,json,pathlib,sys
project,root,report=map(pathlib.Path,sys.argv[1:])
network=project/'Sources/SiliconPlayer/NetworkMediaService.swift'
playlist=project/'Sources/PlayerCore/PlaylistDocument.swift'
channel=project/'Sources/PlayerCore/ChannelDocument.swift'
text=network.read_text()
marker='/// RFC 4918 multistatus parsing.'
assert text.count(marker)==1 and text.count('import PlayerCore\n')==1
prefix=text.split(marker,1)[0]
(report/'NetworkHTTPClient-production-excerpt.swift').write_text(prefix.replace('import PlayerCore\n',''))
decoder=playlist.read_text().split('enum DocumentTextDecoder {',1)[1]
(report/'DocumentTextDecoder-production-excerpt.swift').write_text('import Foundation\nimport CoreFoundation\nenum DocumentTextDecoder {'+decoder)
files=[root/'Sources/PlayerCore'/name for name in ['XMLTVDocument.swift','EPGChannelMapping.swift','EPGCatalog.swift']]+[p for p in sorted((root/'Sources/SiliconPlayer').glob('EPG*.swift')) if not p.name.startswith('.')]+[root/'Tests/Integration/EPG/HTTPChecks.swift',root/'Tests/Integration/EPG/fixture_server.py',root/'scripts/test_epg_http.sh',network,playlist,channel]
manifest={str(p.relative_to(project)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
(report/'inputs-before.json').write_text(json.dumps(manifest,indent=2)+'\n')
(report/'production-extraction.json').write_text(json.dumps({'method':'Exact NetworkMediaService prefix before RFC4918 parser, only import PlayerCore removed for standalone same-module compile; exact DocumentTextDecoder tail plus Foundation/CoreFoundation imports; full original ChannelDocument linked unchanged.', 'networkSourceSHA256':hashlib.sha256(network.read_bytes()).hexdigest(),'networkPrefixSHA256':hashlib.sha256(prefix.encode()).hexdigest(),'generatedNetworkSHA256':hashlib.sha256((report/'NetworkHTTPClient-production-excerpt.swift').read_bytes()).hexdigest(),'actualPlayerLaunched':False},indent=2)+'\n')
PY
set +e
xcrun swiftc -target arm64-apple-macosx14.0 -swift-version 5 -parse-as-library \
    "$prototype_dir/Sources/PlayerCore/XMLTVDocument.swift" "$prototype_dir/Sources/PlayerCore/EPGChannelMapping.swift" "$prototype_dir/Sources/PlayerCore/EPGCatalog.swift" "$prototype_dir/Sources/SiliconPlayer/EPGTransport.swift" "$prototype_dir/Sources/SiliconPlayer/EPGLogoCache.swift" "$prototype_dir/Sources/SiliconPlayer/EPGPreferences.swift" "$prototype_dir/Sources/SiliconPlayer/EPGPreferencesDuplicateKeys.swift" "$prototype_dir/Sources/SiliconPlayer/EPGService.swift" "$prototype_dir/Sources/SiliconPlayer/EPGSourceTransport.swift" \
    "$report_dir/NetworkHTTPClient-production-excerpt.swift" "$report_dir/DocumentTextDecoder-production-excerpt.swift" "$project_dir/Sources/PlayerCore/ChannelDocument.swift" \
    "$prototype_dir/Tests/Integration/EPG/HTTPChecks.swift" -o "$work_dir/epg-http-tests" >"$report_dir/build.log" 2>&1
compile_exit=$?
set -e
if [ "$compile_exit" -ne 0 ]; then
    python3 - "$report_dir/summary.json" "$compile_exit" <<'PY'
import json,pathlib,sys
pathlib.Path(sys.argv[1]).write_text(json.dumps({'status':'failed_compile','compileExitCode':int(sys.argv[2]),'executedScenarioGroups':0,'passed':0},indent=2)+'\n')
PY
    exit "$compile_exit"
fi
cp "$work_dir/epg-http-tests" "$report_dir/compiled-epg-http-tests"
lipo -archs "$work_dir/epg-http-tests" >"$report_dir/architectures.txt"
python3 "$prototype_dir/Tests/Integration/EPG/fixture_server.py" --report-directory "$report_dir/server" >"$report_dir/server-start.log" 2>&1 &
server_pid=$!
trap 'kill -TERM "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true' EXIT
origin=""
for attempt in {1..50}; do
    if [ -f "$report_dir/server/fixture-session.json" ]; then
        origin="$(python3 - "$report_dir/server/fixture-session.json" <<'PY'
import json,pathlib,sys
print(json.loads(pathlib.Path(sys.argv[1]).read_text())['origins'][0])
PY
)"
        break
    fi
    sleep 0.1
done
if [ -z "$origin" ]; then echo "Fixture did not start." >&2; exit 1; fi
set +e
"$work_dir/epg-http-tests" "$origin" "$report_dir/results" "$report_dir/server/server-log.jsonl" >"$report_dir/results.txt" 2>&1
test_exit=$?
set -e
kill -TERM "$server_pid"
wait "$server_pid"
trap - EXIT
python3 - "$project_dir" "$report_dir" "$test_exit" "$server_pid" <<'PY'
from datetime import datetime,timezone
import hashlib,json,pathlib,subprocess,sys
project,report=map(pathlib.Path,sys.argv[1:3]); test_exit=int(sys.argv[3]); server_pid=int(sys.argv[4])
before=json.loads((report/'inputs-before.json').read_text())
after={name:hashlib.sha256((project/name).read_bytes()).hexdigest() for name in before}
(report/'inputs-after.json').write_text(json.dumps(after,indent=2)+'\n')
results=json.loads((report/'results/summary.json').read_text()) if (report/'results/summary.json').exists() else {'results':[],'passed':0,'failed':1}
ids=[r['case'] for r in results['results']]
check=subprocess.run(['ps','-p',str(server_pid),'-o','pid='],capture_output=True,text=True)
cleanup={'ownedServerPID':server_pid,'psExitCode':check.returncode,'ownedServerGone':check.returncode!=0 and not check.stdout.strip()}
(report/'process-cleanup.json').write_text(json.dumps(cleanup,indent=2)+'\n')
valid=test_exit==0 and results.get('status')=='passed' and len(ids)==11 and len(set(ids))==11 and before==after and cleanup['ownedServerGone']
summary={'recordedUTC':datetime.now(timezone.utc).isoformat(),'status':'passed' if valid else 'failed','uniqueScenarioGroups':len(ids),'passed':results.get('passed',0),'failed':results.get('failed',1),
 'compileExitCode':0,'testExitCode':test_exit,'inputHashesUnchanged':before==after,'scope':'Actual loopback HTTP with production NetworkHTTPClient excerpt and production EPG service/cache; no app/UI/public sources.',
 'actualArchitectures':(report/'architectures.txt').read_text().strip(),'executableSHA256':hashlib.sha256((report/'compiled-epg-http-tests').read_bytes()).hexdigest(),'actualLoopbackHTTPRun':True,'actualAppGUIRun':False,'processCleanup':cleanup,'results':results['results']}
(report/'summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2)+'\n')
if not valid: sys.exit(1)
PY
cat "$report_dir/results.txt"

#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
report_dir="${1:?choose a new report directory}"
mkdir -p "$report_dir"
if [ -n "$(ls -A "$report_dir")" ]; then echo "Preserve previous evidence: report directory must be empty" >&2; exit 2; fi
work_dir="$(mktemp -d /private/tmp/siliconplayer-media-controller.XXXXXX)"
trap 'rm -rf "$work_dir"' EXIT
python3 - "$project_dir" "$report_dir/inputs-before.json" <<'PY'
import hashlib,json,pathlib,sys
root=pathlib.Path(sys.argv[1]);files=sorted((root/'Sources/PlayerCore').glob('[A-Z]*.swift'))+[root/'Sources/SiliconPlayer/MediaPreferencesController.swift',root/'Tests/Integration/MediaPreferenceControllerChecks.swift',root/'scripts/test_media_preferences_controller.sh']
pathlib.Path(sys.argv[2]).write_text(json.dumps({str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files},indent=2)+'\n')
PY
set +e
xcrun swiftc -target arm64-apple-macosx14.0 -swift-version 5 -module-name PlayerCore -emit-library -emit-module -emit-module-path "$work_dir/PlayerCore.swiftmodule" \
 "$project_dir"/Sources/PlayerCore/[A-Z]*.swift -o "$work_dir/libPlayerCore.dylib" -Xlinker -install_name -Xlinker '@rpath/libPlayerCore.dylib' >"$report_dir/build-core.log" 2>&1
core_exit=$?; compile_exit=$core_exit; test_exit=0
if [ "$core_exit" -eq 0 ]; then
 xcrun swiftc -target arm64-apple-macosx14.0 -swift-version 5 -parse-as-library -I "$work_dir" -L "$work_dir" -lPlayerCore \
 "$project_dir/Sources/SiliconPlayer/MediaPreferencesController.swift" "$project_dir/Tests/Integration/MediaPreferenceControllerChecks.swift" \
 -Xlinker -rpath -Xlinker '@executable_path' -o "$work_dir/media-controller-checks" >"$report_dir/build-controller-tests.log" 2>&1
 compile_exit=$?
fi
if [ "$compile_exit" -eq 0 ]; then
 cp "$work_dir/media-controller-checks" "$report_dir/compiled-media-controller-checks"
 cp "$work_dir/libPlayerCore.dylib" "$report_dir/libPlayerCore.dylib"
 lipo -archs "$work_dir/media-controller-checks" >"$report_dir/architectures.txt"
 lipo -archs "$work_dir/libPlayerCore.dylib" >"$report_dir/library-architectures.txt"
 "$work_dir/media-controller-checks" "$report_dir" "$work_dir/test-files" >"$report_dir/results.txt" 2>&1
 test_exit=$?
fi
set -e
python3 - "$project_dir" "$report_dir" "$core_exit" "$compile_exit" "$test_exit" <<'PY'
import datetime,hashlib,json,pathlib,sys
root,report=map(pathlib.Path,sys.argv[1:3]);core,comp,test=map(int,sys.argv[3:6])
before=json.loads((report/'inputs-before.json').read_text())
files=sorted((root/'Sources/PlayerCore').glob('[A-Z]*.swift'))+[root/'Sources/SiliconPlayer/MediaPreferencesController.swift',root/'Tests/Integration/MediaPreferenceControllerChecks.swift',root/'scripts/test_media_preferences_controller.sh']
after={str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files};(report/'inputs-after.json').write_text(json.dumps(after,indent=2)+'\n')
scenarios=json.loads((report/'scenario-summary.json').read_text()) if (report/'scenario-summary.json').exists() else {}
expected={'controller-stale-entry-and-before-load-save-preserve-file','controller-late-external-track-retry-resolves-once','controller-missing-ambiguity-timeout-visible-auto-fallback','controller-manual-choice-and-stop-cancel-late-restoration','controller-recovery-block-prevents-all-sheet-publications','controller-clear-current-and-corrupt-reload-preserve-other-records','controller-loaded-global-reset-keeps-media-edits-and-cancels-old-restore'}
ids=scenarios.get('passedScenarioIDs',[]);arch=(report/'architectures.txt').read_text().strip() if (report/'architectures.txt').exists() else '';libarch=(report/'library-architectures.txt').read_text().strip() if (report/'library-architectures.txt').exists() else ''
status='passed' if core==comp==test==0 and before==after and set(ids)==expected and len(ids)==len(set(ids))==scenarios.get('uniqueScenarioGroups')==scenarios.get('passed')==7 and scenarios.get('failed')==0 and scenarios.get('status')=='passed' and arch==libarch=='arm64' else 'failed'
summary={'recordedUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'status':status,'coreCompileExitCode':core,'controllerTestCompileExitCode':comp,'testExitCode':test,'inputsUnchanged':before==after,'inputPinCount':len(before),'scenarioResult':scenarios,'actualArchitecture':arch,'actualLibraryArchitecture':libarch}
if comp==0: summary.update(executableSHA256=hashlib.sha256((report/'compiled-media-controller-checks').read_bytes()).hexdigest(),productionCoreLibrarySHA256=hashlib.sha256((report/'libPlayerCore.dylib').read_bytes()).hexdigest())
(report/'summary.json').write_text(json.dumps(summary,indent=2)+'\n');print(json.dumps({k:summary[k] for k in ['status','coreCompileExitCode','controllerTestCompileExitCode','testExitCode','inputsUnchanged','inputPinCount']}))
if status!='passed': raise SystemExit(1)
PY

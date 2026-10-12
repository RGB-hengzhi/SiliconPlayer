#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
report_dir="${1:?choose a new report directory}"
mkdir -p "$report_dir"
if [ -n "$(ls -A "$report_dir")" ]; then
  echo "Preserve previous evidence: report directory must be empty" >&2
  exit 2
fi
work_dir="$(mktemp -d /private/tmp/siliconplayer-media-preferences.XXXXXX)"
trap 'rm -rf "$work_dir"' EXIT
python3 - "$project_dir" "$report_dir/inputs-before.json" <<'PY'
import hashlib,json,pathlib,sys
root=pathlib.Path(sys.argv[1]);files=sorted((root/'Sources/PlayerCore').glob('[A-Z]*.swift'))+[root/'Tests/Integration/MediaPreferenceChecks.swift',root/'scripts/test_media_preferences.sh']
pathlib.Path(sys.argv[2]).write_text(json.dumps({str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files},indent=2)+'\n')
PY
set +e
xcrun swiftc -target arm64-apple-macosx14.0 -swift-version 5 -module-name PlayerCore \
  -emit-library -emit-module -emit-module-path "$work_dir/PlayerCore.swiftmodule" \
  "$project_dir"/Sources/PlayerCore/[A-Z]*.swift -o "$work_dir/libPlayerCore.dylib" \
  -Xlinker -install_name -Xlinker '@rpath/libPlayerCore.dylib' >"$report_dir/build-production-core.log" 2>&1
production_compile_exit=$?
if [ "$production_compile_exit" -eq 0 ]; then
  xcrun swiftc -target arm64-apple-macosx14.0 -swift-version 5 -parse-as-library \
    -I "$work_dir" -L "$work_dir" -lPlayerCore "$project_dir/Tests/Integration/MediaPreferenceChecks.swift" \
    -Xlinker -rpath -Xlinker '@executable_path' -o "$work_dir/media-preference-checks" >"$report_dir/build-tests.log" 2>&1
  compile_exit=$?
else
  compile_exit=$production_compile_exit
fi
test_exit=0
if [ "$compile_exit" -eq 0 ]; then
  cp "$work_dir/media-preference-checks" "$report_dir/compiled-media-preference-checks"
  cp "$work_dir/libPlayerCore.dylib" "$report_dir/libPlayerCore.dylib"
  lipo -archs "$work_dir/media-preference-checks" >"$report_dir/architectures.txt"
  lipo -archs "$work_dir/libPlayerCore.dylib" >"$report_dir/library-architectures.txt"
  "$work_dir/media-preference-checks" "$report_dir" "$work_dir/test-files" >"$report_dir/results.txt" 2>&1
  test_exit=$?
fi
set -e
python3 - "$project_dir" "$report_dir" "$production_compile_exit" "$compile_exit" "$test_exit" <<'PY'
import datetime,hashlib,json,pathlib,sys
root,report=map(pathlib.Path,sys.argv[1:3]);prod,comp,test=map(int,sys.argv[3:6])
before=json.loads((report/'inputs-before.json').read_text())
files=sorted((root/'Sources/PlayerCore').glob('[A-Z]*.swift'))+[root/'Tests/Integration/MediaPreferenceChecks.swift',root/'scripts/test_media_preferences.sh']
after={str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
(report/'inputs-after.json').write_text(json.dumps(after,indent=2)+'\n')
scenarios=json.loads((report/'scenario-summary.json').read_text()) if (report/'scenario-summary.json').exists() else {}
expected={
 'identity-local-unicode-space-and-distinct-case','identity-network-normalization-query-order-and-fragment','identity-rejects-credentials-encoded-queries-and-controls',
 'track-description-reordered-runtime-ids','track-commentary-ambiguity-and-missing-fallback','track-auxiliary-flags-and-explicit-off','track-external-original-and-manual-auto-source',
 'track-local-filename-language-missing-compatible-only','track-local-language-fallback-rejects-wrong-source-codec-and-ambiguity',
 'track-runtime-id-namespace-per-kind-and-total-bound',
 'geometry-delay-bounds-reject-nan-and-cross-kind','media-roundtrip-explicit-save-clear-and-original-page','media-upsert-and-auto-restore-no-other-media-change',
 'media-duplicate-escaped-keys-version-and-key-identity','media-entry-and-byte-nesting-bounds','store-missing-old-empty-and-corrupt-preserves-bytes','store-real-atomic-roundtrip-rejected-save-preserves',
 'bounded-read-rejects-fifo-device-symlink-without-blocking','backup-actual-settings-filter-chain-and-shortcuts-roundtrip','backup-strict-global-malformed-and-clamped-rejection',
 'backup-invalid-filters-shortcut-reserved-duplicate-version','backup-runtime-id-and-sensitive-url-exclusion','transaction-invalid-backup-zero-writes',
 'transaction-real-files-and-isolated-userdefaults-success','transaction-second-and-third-file-failure-rolls-all-back','transaction-shortcut-failure-restores-files-and-defaults',
 'transaction-malformed-old-shortcut-raw-bytes-rollback','transaction-restart-recovers-pending-real-journal','transaction-corrupt-journal-preflight-zero-writes',
 'transaction-committed-cleanup-restart-preserves-new-stores','transaction-checksum-corruption-restart-zero-writes','redactor-retains-nonsecret-error-code-codec-filter',
 'redactor-full-http-https-path-query-and-multiple-urls','redactor-escaped-unicode-percent-and-credentials','redactor-invalid-utf8-control-and-size-bounds',
 'redactor-mpv-trailing-crlf-and-unicode-line-injection','redactor-playback-protocols-and-encoded-schemes',
 'session-restored-geometry-unrelated-edit-does-not-persist-overlay','session-geometry-and-nested-edits-clear-on-next-media-and-stop',
 'session-explicit-global-install-and-idle-edit-reset-overrides','session-runtime-id-never-persists-and-invalid-record-keeps-state'}
count=scenarios.get('uniqueScenarioGroups',0);passed=scenarios.get('passed',0);ids=scenarios.get('passedScenarioIDs',[])
arch=(report/'architectures.txt').read_text().strip() if (report/'architectures.txt').exists() else ''
libarch=(report/'library-architectures.txt').read_text().strip() if (report/'library-architectures.txt').exists() else ''
status='passed' if prod==comp==test==0 and count==passed==len(ids)==len(set(ids))==len(expected)==41 and set(ids)==expected and scenarios.get('status')=='passed' and before==after and arch==libarch=='arm64' else 'failed'
summary={'recordedUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'status':status,'productionCoreCompileExitCode':prod,'testCompileExitCode':comp,'testExitCode':test,'inputsUnchanged':before==after,'inputPinCount':len(before),'scenarioResult':scenarios,'scope':'Actual production Core models/backup transaction/redactor. Real APFS test execution/file publication and unique UserDefaults suite. No player/app/GUI/standard defaults writes; host validator injection is not InputController certification.'}
if comp==0: summary.update(executableSHA256=hashlib.sha256((report/'compiled-media-preference-checks').read_bytes()).hexdigest(),actualArchitecture=arch,actualLibraryArchitecture=libarch,productionCoreLibrarySHA256=hashlib.sha256((report/'libPlayerCore.dylib').read_bytes()).hexdigest())
(report/'summary.json').write_text(json.dumps(summary,indent=2)+'\n');print(json.dumps({k:summary[k] for k in ['status','productionCoreCompileExitCode','testCompileExitCode','testExitCode','inputsUnchanged','inputPinCount']}))
if status!='passed': raise SystemExit(1)
PY
if [ "$compile_exit" -ne 0 ]; then exit "$compile_exit"; fi
exit "$test_exit"

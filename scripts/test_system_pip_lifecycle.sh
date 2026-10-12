#!/bin/bash
# Pure production lifecycle guards. No AppKit, private framework, or GUI loaded.
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/silicon-pip-lifecycle-XXXXXX")"
report_dir="${1:-$work_dir/report}"
if [ -e "$report_dir" ]; then echo "Choose a new PiP lifecycle report directory." >&2; exit 2; fi
mkdir -p "$report_dir"
python3 - "$project_dir" "$report_dir" <<'PY'
import hashlib,json,pathlib,sys
root,report=map(pathlib.Path,sys.argv[1:])
names=['Sources/PlayerCore/SystemPiPLifecycle.swift','Tests/PlayerCoreTests/SystemPiPLifecycleTests.swift','Tests/PlayerCoreTests/StandaloneRunner.swift','scripts/test_system_pip_lifecycle.sh','Sources/SiliconPlayer/SystemPiPController.swift','Sources/SystemPiPBridge/SystemPiPBridge.m','Sources/SystemPiPBridge/include/SystemPiPBridge.h','Package.swift']
(report/'inputs-before.json').write_text(json.dumps({n:hashlib.sha256((root/n).read_bytes()).hexdigest() for n in names},indent=2)+'\n')
source=(root/names[2]).read_text()
assertions=source.split('@main\nstruct StandaloneRunner',1)[0]
assert '#if PLAYER_CORE_STANDALONE' in assertions
(report/'StandaloneAssertions.swift').write_text(assertions+'\n#endif\n')
(report/'LifecycleRunner.swift').write_text('''import Foundation
@main struct LifecycleRunner {
    static func main() {
        let tests = SystemPiPLifecycleTests()
        let cases: [(String, () -> Void)] = [
            ("pip.lifecycle.duplicate-enter-close", tests.testDuplicateEnterAndDuplicateCloseAreRejected),
            ("pip.lifecycle.exit-during-startup", tests.testExitDuringStartupRejectsLateStartWithoutLosingCloseTicket),
            ("pip.lifecycle.old-generation-close", tests.testOldCloseCannotRestoreNewPresentation),
            ("pip.lifecycle.reusable-exit-terminal-shutdown", tests.testOrdinaryExitPermitsAnotherEntryButTerminalShutdownDoesNot),
            ("pip.lifecycle.forced-teardown-registration", tests.testForcedTeardownInvalidatesCallbacksAndNewRegistrationCanRecover),
            ("pip.lifecycle.cancelled-quit-generation", tests.testCancelledQuitPreservesGenerationAndRequiresSafeClose)
        ]
        for (id, run) in cases { run(); print("PASS \\(id)") }
    }
}
''')
PY
set +e
xcrun swiftc -target arm64-apple-macosx14.0 -swift-version 5 -D PLAYER_CORE_STANDALONE \
    "$project_dir/Sources/PlayerCore/SystemPiPLifecycle.swift" \
    "$project_dir/Tests/PlayerCoreTests/SystemPiPLifecycleTests.swift" \
    "$report_dir/StandaloneAssertions.swift" "$report_dir/LifecycleRunner.swift" \
    -o "$work_dir/lifecycle-tests" >"$report_dir/build.log" 2>&1
compile_exit=$?
set -e
if [ "$compile_exit" -ne 0 ]; then
    python3 - "$report_dir/summary.json" "$compile_exit" <<'PY'
import json,pathlib,sys
pathlib.Path(sys.argv[1]).write_text(json.dumps({'status':'failed_compile','compileExitCode':int(sys.argv[2]),'passed':0,'actualAppGUIRun':False},indent=2)+'\n')
PY
    exit "$compile_exit"
fi
cp "$work_dir/lifecycle-tests" "$report_dir/compiled-tests"
lipo -archs "$work_dir/lifecycle-tests" >"$report_dir/architectures.txt"
set +e
"$work_dir/lifecycle-tests" >"$report_dir/results.txt" 2>&1
test_exit=$?
set -e
python3 - "$project_dir" "$report_dir" "$test_exit" <<'PY'
from datetime import datetime,timezone
import hashlib,json,pathlib,sys
root,report=map(pathlib.Path,sys.argv[1:3]); test_exit=int(sys.argv[3])
before=json.loads((report/'inputs-before.json').read_text()); after={n:hashlib.sha256((root/n).read_bytes()).hexdigest() for n in before}
(report/'inputs-after.json').write_text(json.dumps(after,indent=2)+'\n')
lines=(report/'results.txt').read_text().splitlines(); ids=[s[5:] for s in lines if s.startswith('PASS ')]
expected=['pip.lifecycle.duplicate-enter-close','pip.lifecycle.exit-during-startup','pip.lifecycle.old-generation-close','pip.lifecycle.reusable-exit-terminal-shutdown','pip.lifecycle.forced-teardown-registration','pip.lifecycle.cancelled-quit-generation']
arch=(report/'architectures.txt').read_text().strip()
valid=test_exit==0 and ids==expected and len(set(ids))==6 and before==after and arch=='arm64'
summary={'recordedUTC':datetime.now(timezone.utc).isoformat(),'status':'passed' if valid else 'failed','uniqueScenarioGroups':6,'passed':len(ids),'failed':0 if valid else 1,'compileExitCode':0,'testExitCode':test_exit,'passedScenarioIDs':ids,'inputHashesUnchanged':before==after,'actualArchitectures':arch,'executableSHA256':hashlib.sha256((report/'compiled-tests').read_bytes()).hexdigest(),'actualAppGUIRun':False,'scope':'Six pure production SystemPiPLifecycle guard groups. Does not load AppKit/private PiP or certify native ownership, renderer, animation, system window, or GUI.'}
(report/'summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2)+'\n')
if not valid: sys.exit(1)
PY
cat "$report_dir/results.txt"

#!/usr/bin/env python3
"""Test actual queue AppKit types and model methods without starting SiliconPlayer."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
report_dir = Path(sys.argv[1] if len(sys.argv) > 1 else root / "Tests/Integration/Reports/queue-list02").resolve()
report_dir.mkdir(parents=True, exist_ok=True)
os.chdir(root)
paths = ["Sources/PlayerCore/Playlist.swift", "Sources/PlayerCore/PlaylistDragPayload.swift",
         "Sources/SiliconPlayer/PlayerView.swift", "Sources/SiliconPlayer/PlayerModelAdvanced.swift",
         "Sources/SiliconPlayer/InputAndMediaControls.swift"]
snapshots = {path: (root / path).read_bytes() for path in paths}
summary = {"target": "arm64-apple-macos14.0",
           "production_sha256": {path: hashlib.sha256(snapshots[path]).hexdigest() for path in paths},
           "limitations": ["No production app launch or real mpv playback",
                           "Native table/callbacks run without visible windows; real Command/Shift clicks, mouse drag gestures and insertion indicator appearance still require UI acceptance",
                           "Model test invokes exact production queue methods with instrumented save/load/stop/persist boundaries"]}

def run(name, command, env=None):
    result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env)
    (report_dir / f"{name}.txt").write_text(result.stdout)
    summary[name] = {"exit_code": result.returncode, "pass_groups": result.stdout.count("PASS "), "command": command}
    print(result.stdout, end="")
    if result.returncode:
        (report_dir / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2))
        sys.exit(result.returncode)

with tempfile.TemporaryDirectory(prefix="siliconplayer-queue-", dir="/private/tmp") as scratch:
    scratch = Path(scratch)
    core = sorted(str(path) for path in (root / "Sources/PlayerCore").glob("[A-Z]*.swift"))
    app_sources = sorted(str(path) for path in (root / "Sources/SiliconPlayer").glob("[A-Z]*.swift"))
    bridge_source = root / "Sources/SystemPiPBridge/SystemPiPBridge.m"
    bridge_headers = root / "Sources/SystemPiPBridge/include"
    ftp_source = root / "Sources/RemoteTransferBridge/SPFTPTransfer.m"
    ftp_header = root / "Sources/RemoteTransferBridge/include/SPFTPTransfer.h"
    metal_source = root / "Sources/MetalRenderBridge/MetalRenderBridge.m"
    metal_header = root / "Sources/MetalRenderBridge/include/MetalRenderBridge.h"
    metal_private = root / "Sources/MetalRenderBridge/pinned-mpv/include"
    metal_headers = [metal_private / "mpv" / name for name in ("client.h", "render.h", "render_mtl.h")]
    watched = [metal_source, metal_header, *metal_headers, ftp_source, ftp_header] + [Path(path) for path in core + app_sources] + [bridge_source, bridge_headers / "SystemPiPBridge.h",
        root / "Tests/Integration/QueueInteractionChecks.swift", Path(__file__).resolve(), root / "scripts/test_queue.sh", root / "Package.swift"]
    input_hashes = {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest() for path in watched}
    summary["input_sha256_before"] = input_hashes
    # Mirror the production SwiftPM ObjC target, without using a stale build
    # cache or replacing its header/implementation with testing declarations.
    sdk = subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip()
    bridge_module = scratch / "SystemPiPBridge"
    bridge_module.mkdir()
    modulemap = bridge_module / "module.modulemap"
    modulemap.write_text('module SystemPiPBridge {\n  header "' + str(bridge_headers / "SystemPiPBridge.h") +
                         '"\n  link framework "AppKit"\n  export *\n}\n')
    bridge_object = scratch / "SystemPiPBridge.o"
    summary["bridge_modulemap_sha256"] = hashlib.sha256(modulemap.read_bytes()).hexdigest()
    run("bridge-compile", ["xcrun", "clang", "-target", "arm64-apple-macos14.0", "-isysroot", sdk,
                           "-fobjc-arc", "-fmodules", "-fmodules-cache-path=" + str(scratch / "clang-module-cache"),
                           "-I", str(bridge_headers), "-c", str(bridge_source), "-o", str(bridge_object)])
    bridge_arch = subprocess.check_output(["lipo", "-archs", str(bridge_object)], text=True).strip()
    if bridge_arch != "arm64":
        raise RuntimeError("Production bridge object is not arm64: " + bridge_arch)
    summary["production_bridge_object"] = {"architecture": bridge_arch, "sha256": hashlib.sha256(bridge_object.read_bytes()).hexdigest(),
                                            "source": str(bridge_source.relative_to(root)), "instantiated": False}
    ftp_module = scratch / "RemoteTransferBridge"
    ftp_module.mkdir()
    ftp_modulemap = ftp_module / "module.modulemap"
    ftp_modulemap.write_text('module RemoteTransferBridge {\n  header "' + str(ftp_header) +
                            '"\n  link framework "Foundation"\n  link "curl"\n  export *\n}\n')
    ftp_object = scratch / "SPFTPTransfer.o"
    run("ftp-bridge-compile", ["xcrun", "clang", "-target", "arm64-apple-macos14.0", "-isysroot", sdk,
        "-fobjc-arc", "-fmodules", "-fmodules-cache-path=" + str(scratch / "clang-module-cache"),
        "-I", str(ftp_header.parent), "-c", str(ftp_source), "-o", str(ftp_object)])
    ftp_arch = subprocess.check_output(["lipo", "-archs", str(ftp_object)], text=True).strip()
    if ftp_arch != "arm64":
        raise RuntimeError("Production FTP bridge object is not arm64: " + ftp_arch)
    summary["production_ftp_bridge_object"] = {"architecture": ftp_arch,
        "sha256": hashlib.sha256(ftp_object.read_bytes()).hexdigest(),
        "modulemap_sha256": hashlib.sha256(ftp_modulemap.read_bytes()).hexdigest(),
        "source": str(ftp_source.relative_to(root)), "instantiated": False}
    metal_module = scratch / "MetalRenderBridge"
    metal_module.mkdir()
    metal_modulemap = metal_module / "module.modulemap"
    metal_modulemap.write_text('module MetalRenderBridge {\n  header "' + str(metal_header) +
                              '"\n  link framework "Metal"\n  link framework "QuartzCore"\n  export *\n}\n')
    metal_object = scratch / "MetalRenderBridge.o"
    run("metal-bridge-compile", ["xcrun", "clang", "-target", "arm64-apple-macos14.0", "-isysroot", sdk,
        "-fobjc-arc", "-fblocks", "-fmodules", "-fmodules-cache-path=" + str(scratch / "clang-module-cache"),
        "-I", str(metal_header.parent), "-I", str(metal_private), "-c", str(metal_source), "-o", str(metal_object)])
    metal_arch = subprocess.check_output(["lipo", "-archs", str(metal_object)], text=True).strip()
    if metal_arch != "arm64":
        raise RuntimeError("Production Metal bridge object is not arm64: " + metal_arch)
    metal_symbols = subprocess.check_output(["nm", "-g", str(metal_object)], text=True)
    (report_dir / "metal-bridge-object-symbols.txt").write_text(metal_symbols)
    if "_SPMetalSessionCreate" not in metal_symbols or "_mpv_render_context_create" not in metal_symbols:
        raise RuntimeError("Metal object omitted its production bridge or actual mpv API dependency")
    summary["production_metal_bridge_object"] = {"architecture": metal_arch,
        "sha256": hashlib.sha256(metal_object.read_bytes()).hexdigest(),
        "modulemap_sha256": hashlib.sha256(metal_modulemap.read_bytes()).hexdigest(),
        "source": str(metal_source.relative_to(root)), "instantiated": False, "linkedIntoQueueChecks": False,
        "scope": "Actual ObjC compile and whole-App Swift typecheck only; no Metal context/device/GPU runtime"}
    run("core", ["bash", "scripts/test_core.sh"])
    run("core-module", ["swiftc", "-emit-library", "-emit-module", "-module-name", "PlayerCore",
                        "-target", "arm64-apple-macos14.0", *core, "-o", str(scratch / "libPlayerCore.dylib"),
                        "-emit-module-path", str(scratch / "PlayerCore.swiftmodule")])
    run("app-typecheck", ["swiftc", "-typecheck", "-parse-as-library", "-target", "arm64-apple-macos14.0",
                          "-I", str(scratch), "-I", str(bridge_module), "-I", str(ftp_module), "-I", str(metal_module), "-I", str(root / "Sources/CMPV"),
                          "-module-cache-path", str(scratch / "swift-module-cache"), *app_sources])
    view = snapshots[paths[2]].decode()
    native = view[view.index("private struct QueueRow {"):view.index("private enum DropLoader {")]
    trace = view[view.index("@MainActor private enum QueueDragTrace {"):view.index("private let accent =")]
    input_source = snapshots[paths[4]].decode()
    suite_method = input_source[input_source.index("    static func verificationSuiteName(environment:"):input_source.index("    @discardableResult", input_source.index("    static func verificationSuiteName(environment:"))]
    summary["compiled_drag_trace_sha256"] = hashlib.sha256(trace.encode()).hexdigest()
    summary["compiled_verification_suite_method_sha256"] = hashlib.sha256(suite_method.encode()).hexdigest()
    model = snapshots[paths[3]].decode()
    methods = model[model.index("    func removePlaylistItems("):model.index("    var currentURL:")]
    summary["compiled_native_region_sha256"] = hashlib.sha256(native.encode()).hexdigest()
    summary["compiled_model_methods_sha256"] = hashlib.sha256(methods.encode()).hexdigest()
    tail = (root / "Tests/Integration/QueueInteractionChecks.swift").read_text()
    generated = scratch / "QueueChecks.swift"
    generated.write_text("import AppKit\nimport SwiftUI\nimport CryptoKit\nimport PlayerCore\n" +
                         "@MainActor private enum InputController {\n" + suite_method + "}\n" +
                         trace + native + tail + "\nextension PlayerModel {\n" + methods + "\n}\n")
    binary = scratch / "QueueChecks"
    run("native-compile", ["swiftc", "-parse-as-library", "-target", "arm64-apple-macos14.0", "-I", str(scratch),
                           "-L", str(scratch), "-lPlayerCore", str(generated), str(bridge_object), str(ftp_object), "-lcurl", "-framework", "Foundation", "-framework", "AppKit", "-o", str(binary)])
    symbols = subprocess.check_output(["nm", "-g", str(binary)], text=True)
    (report_dir / "bridge-linked-symbols.txt").write_text(symbols)
    if not all(name in symbols for name in ["_OBJC_CLASS_$_SPSystemPiPBridge", "_OBJC_CLASS_$_SPSystemPiPAttachment"]):
        raise RuntimeError("Queue executable did not link the actual production bridge classes")
    summary["production_bridge_linked"] = True
    if "_OBJC_CLASS_$_SPFTPTransfer" not in symbols:
        raise RuntimeError("Queue executable did not link the actual production FTP bridge class")
    summary["production_ftp_bridge_linked"] = True
    env = os.environ.copy(); env["DYLD_LIBRARY_PATH"] = str(scratch)
    run("native-model", [str(binary)], env)
    summary["input_sha256_after"] = {path: hashlib.sha256((root / path).read_bytes()).hexdigest() for path in input_hashes}
    summary["inputs_unchanged"] = summary["input_sha256_after"] == input_hashes
    summary["status"] = "passed" if summary["inputs_unchanged"] else "failed"
(report_dir / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2))
if not summary["inputs_unchanged"]:
    raise RuntimeError("Queue module source/test/bridge inputs changed during the run")
print(f"Reports: {report_dir}")

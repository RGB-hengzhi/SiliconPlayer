import Foundation
import Darwin
import PlayerCore

// Prepared behavioral checks only. No compiler, filesystem test or renderer
// has been run for this draft. Root may execute on an owned APFS scratch later.
@MainActor final class AssetRuntimeDouble: VideoAssetRuntime {
    var assetBinding:VideoAssetPlaybackBinding? = .init(coreID:UUID(),mediaEpoch:UUID(),loadedItemID:UUID(),loadToken:UUID())
    var activeAssets=VideoAssetPipeline(shaders:[],lutGraphs:[])
    var rejectShader=false,failApply=false,failRestore=false,suspended=false
    var applyingHook:(()->Void)?
    var applied:[VideoAssetPipeline]=[],restored:[VideoAssetPipeline]=[]
    func applyAssets(_ p:VideoAssetPipeline,binding:VideoAssetPlaybackBinding,ticket:UUID) async throws -> VideoAssetAcceptance {
        applied.append(p);applyingHook?()
        if failApply {throw VideoAssetError.applyFailed}
        activeAssets=p
        return .init(binding:binding,ticket:ticket,pipeline:p,configuredAndReadBack:true,
                     producedVideoOutput:true,shadersConfirmed:!rejectShader,
                     shaderEvidence:p.shaders.isEmpty ? [] : ["actual-test-double-pass"])
    }
    func restoreAssets(_ p:VideoAssetPipeline,binding:VideoAssetPlaybackBinding,ticket:UUID) async throws -> VideoAssetAcceptance {
        restored.append(p)
        if failRestore {throw VideoAssetError.rollbackFailed}
        activeAssets=p
        return .init(binding:binding,ticket:ticket,pipeline:p,configuredAndReadBack:true,
                     producedVideoOutput:true,shadersConfirmed:true,shaderEvidence:p.shaders.isEmpty ? [] : ["actual-test-double-restore"])
    }
    func cancelAssets(ticket:UUID) {}
    func suspendAssetsForCurrentMedia() {suspended=true;activeAssets = .init(shaders:[],lutGraphs:[])}
}

@main struct VideoAssetChecks {
    static let shader=Data("//!HOOK MAIN\n//!BIND HOOKED\n//!DESC SPAsset Invert\nvec4 hook() { return vec4(1.0-HOOKED_tex(HOOKED_pos).rgb, 1.0); }\n".utf8)
    static let cube=Data("TITLE \"Tiny identity\"\nLUT_3D_SIZE 2\nDOMAIN_MIN 0 0 0\nDOMAIN_MAX 1 1 1\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n".utf8)
    static func require(_ value:Bool,_ message:String) throws {if !value {throw NSError(domain:message,code:1)}}
    static func rejects(_ name:String,_ operation:() throws -> Void) throws {
        do {try operation()} catch {return}
        throw NSError(domain:name+" unexpectedly accepted",code:1)
    }
    @MainActor static func main() async throws {
        let environment=ProcessInfo.processInfo.environment
        guard let path=environment["VIDEO_ASSET_TEST_DIRECTORY"],path.hasPrefix("/private/"),
              !FileManager.default.fileExists(atPath:path) else {throw VideoAssetError.invalidSource}
        let root=URL(fileURLWithPath:path,isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
        // Test runner owns this fresh directory; it records inputs/compile/run
        // and retains output even on failure. Tests do not remove the evidence.
        var count=0
        func passed(_ id:String) {count+=1;print("PASS "+id)}
        try VideoAssetContent.validate(shader,kind:.glsl)
        try VideoAssetContent.validate(cube,kind:.cube)
        passed("valid-managed-subsets")
        for bad in ["LUT_3D_SIZE 1\n","LUT_3D_SIZE 34\n",String(decoding:cube,as:UTF8.self)+"0 0 0\n",String(decoding:cube,as:UTF8.self).replacingOccurrences(of:"1 1 1\n",with:"NaN 1 1\n")] {
            try rejects("bad cube") {try VideoAssetContent.validate(Data(bad.utf8),kind:.cube)}
        };passed("cube-shape-and-nonfinite-reject")
        for bad in [String(decoding:cube,as:UTF8.self).replacingOccurrences(of:"DOMAIN_MAX 1 1 1",with:"DOMAIN_MAX 0 1 1"),String(decoding:cube,as:UTF8.self).replacingOccurrences(of:"DOMAIN_MIN 0 0 0",with:"DOMAIN_MIN -1 0 0")] {
            try rejects("nondefault domain") {try VideoAssetContent.validate(Data(bad.utf8),kind:.cube)}
        };passed("normalized-domain-not-silent-hdr")
        try rejects("missing headers") {try VideoAssetContent.validate(Data("vec4 hook(){return vec4(1);}".utf8),kind:.glsl)}
        try rejects("conditional unverified shader") {try VideoAssetContent.validate(shader+Data("//!WHEN 0\n".utf8),kind:.glsl)}
        passed("shader-structural-not-compile-proof")
        var doc=VideoAssetDocument(entries:[.init(kind:.glsl,name:"着色器",sha256:VideoAssetContent.checksum(shader),byteCount:shader.count),.init(kind:.cube,name:"LUT",sha256:VideoAssetContent.checksum(cube),byteCount:cube.count)])
        let first=doc.entries[0].id,second=doc.entries[1].id
        try doc.setEnabled(first,true);try doc.move(second,before:first)
        try require(doc.entries.map(\.id)==[second,first] && doc.enabled(.glsl).map(\.id)==[first] && doc.enabled(.cube).isEmpty,"stable IDs and per-stage order")
        try require(try VideoAssetDocument.decode(doc.encoded())==doc,"roundtrip")
        passed("identity-stage-order-and-roundtrip")
        try rejects("duplicate JSON") {_=try VideoAssetDocument.decode(Data("{\"version\":1,\"version\":1,\"entries\":[]}".utf8))}
        try rejects("upper hash") {_=try VideoAssetDocument(entries:[.init(kind:.glsl,name:"x",sha256:VideoAssetContent.checksum(shader).uppercased(),byteCount:shader.count)]).validated()}
        passed("duplicate-and-sha-exact-schema")
        let escaped=try VideoAssetGraph.lut3d(path:"/private/中文 path:a,b'c\\d[1];.cube")
        try require(escaped=="lut3d=file=/private/中文\\\\ path\\\\:a\\,b\\\\\\'c\\\\\\\\d\\[1\\]\\;.cube:interp=tetrahedral","two-layer escaping exact vector")
        passed("ffmpeg-two-layer-literal-path-vector")
        let source=root.appendingPathComponent("source GLSL.glsl")
        try shader.write(to:source)
        let store=try VideoAssetStore(directory:root.appendingPathComponent("managed"))
        let lease=try await store.begin()
        let entry=try await store.importFile(source,lease:lease)
        try require(!entry.enabled && entry.basename==VideoAssetContent.checksum(shader)+".glsl","disabled owned SHA copy")
        try await store.commit(.init(entries:[entry]),lease:lease);await store.end(lease)
        try require(try await store.loadVerified()==VideoAssetDocument(entries:[entry]),"verified store")
        passed("import-disabled-full-sha-copy")
        let secondLease=try await store.begin()
        let same=try await store.importFile(source,lease:secondLease)
        try require(same.id==entry.id,"dedup retains UUID");await store.end(secondLease)
        passed("content-dedup-stable-identity")
        let alias=root.appendingPathComponent("alias.glsl")
        try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:source)
        let special=root.appendingPathComponent("pipe.glsl")
        try require(mkfifo(special.path,mode_t(0o600))==0,"fresh FIFO")
        for url in [alias,special] {
            let l=try await store.begin()
            do {_=try await store.importFile(url,lease:l);await store.end(l);throw NSError(domain:"nonregular accepted",code:1)} catch let e as NSError where e.domain=="nonregular accepted" {throw e} catch {await store.end(l)}
        };passed("nofollow-nonblocking-fifo-and-link-reject")
        let portable=try await store.exportSnapshot()
        try require(try VideoAssetPortableBundle.decode(portable.encoded())==portable,"full archive roundtrip")
        let other=try VideoAssetStore(directory:root.appendingPathComponent("restored"))
        let restore=try await other.begin();try await other.stageRestore(portable,lease:restore)
        try await other.commit(portable.document,lease:restore);await other.end(restore)
        try require(try await other.exportSnapshot()==portable,"portable bytes and SHA")
        try rejects("missing portable file") {_=try VideoAssetPortableBundle(document:portable.document,files:[:]).validated()}
        passed("portable-resource-restore-no-missing-assets")
        let runtime=AssetRuntimeDouble(),controller=VideoAssetsController(store:store,runtime:runtime)
        controller.load();await controller.waitForIdle()
        try rejects("profile must not silently omit resources") {try controller.requireSeparateProfileArchive()}
        let manifest=root.appendingPathComponent("managed/video-assets.json")
        let prior=try Data(contentsOf:manifest)
        runtime.rejectShader=true
        controller.enabled(entry.id,true);await controller.waitForIdle()
        try require(controller.document.entries[0].enabled==false && runtime.restored.count==1 && (try Data(contentsOf:manifest))==prior,"unconfirmed shader rejected and restored")
        passed("property-only-shader-success-does-not-commit")
        runtime.rejectShader=false;runtime.failApply=true;runtime.failRestore=true
        controller.enabled(entry.id,true);await controller.waitForIdle()
        try require(runtime.suspended && (try Data(contentsOf:manifest))==prior,"double failure saved state protected")
        passed("apply-restore-failure-suspend-protect-old-manifest")
        runtime.failApply=false;runtime.failRestore=false
        runtime.applyingHook={controller.contextEnded();runtime.assetBinding = .init(coreID:UUID(),mediaEpoch:UUID(),loadedItemID:UUID(),loadToken:UUID())}
        let restoreCount=runtime.restored.count
        controller.enabled(entry.id,true);await controller.waitForIdle()
        try require(runtime.restored.count==restoreCount && (try Data(contentsOf:manifest))==prior,"old callback cannot restore onto new media")
        passed("late-completion-and-same-url-epoch-no-old-rollback")
        runtime.applyingHook=nil
        controller.enabled(entry.id,true);await controller.waitForIdle()
        try require(controller.document.entries[0].enabled,"positive receipt commit")
        let committed=try Data(contentsOf:manifest)
        _=await controller.shutdown()
        controller.enabled(entry.id,false);await controller.waitForIdle()
        try require((try Data(contentsOf:manifest))==committed && !controller.hasActiveJobs,"closing rejects resurrection")
        passed("actual-completion-and-termination-gate")
        // Simulate post-import tampering; full re-read rejects it without
        // adopting a manifest with a guessed/clamped/recomputed identity.
        try Data("tampered".utf8).write(to:root.appendingPathComponent("managed/"+entry.basename))
        do {_=try await store.loadVerified();throw NSError(domain:"mutation accepted",code:1)} catch let e as NSError where e.domain=="mutation accepted" {throw e} catch {}
        try require((try Data(contentsOf:manifest))==committed,"changed owned payload protected")
        passed("changed-owned-resource-rejected")
        // Repeated scans on the SAME store must each start at directory zero.
        // No manifest commit is needed: immutable orphan assets count as well.
        let countStore=try VideoAssetStore(directory:root.appendingPathComponent("count-bound"))
        let countLease=try await countStore.begin()
        for i in 0..<128 {
            let bytes=shader+Data("// unique count asset \(i)\n".utf8)
            let input=root.appendingPathComponent("count-input.glsl");try bytes.write(to:input)
            _=try await countStore.importFile(input,lease:countLease)
        }
        let overCount=root.appendingPathComponent("count-over.glsl")
        try (shader+Data("// distinct 129th\n".utf8)).write(to:overCount)
        do {_=try await countStore.importFile(overCount,lease:countLease);throw NSError(domain:"file count bypassed",code:1)} catch let e as NSError where e.domain=="file count bypassed" {throw e} catch let e as VideoAssetError {try require(e == .tooLarge,"exact count rejection")} catch {throw error}
        await countStore.end(countLease)
        passed("repeated-full-scan-128-file-bound")
        let byteStore=try VideoAssetStore(directory:root.appendingPathComponent("byte-bound"))
        let byteLease=try await byteStore.begin()
        let line="#"+String(repeating:"z",count:496)+"\n"
        let fill=String(repeating:line,count:(2*1024*1024-cube.count-100)/line.utf8.count)
        for i in 0..<16 {
            let input=root.appendingPathComponent("byte-input.cube")
            try (cube+Data((fill+"# unique byte asset \(i)\n").utf8)).write(to:input)
            _=try await byteStore.importFile(input,lease:byteLease)
        }
        let overBytes=root.appendingPathComponent("byte-over.cube")
        try (cube+Data((fill+"# distinct 17th\n").utf8)).write(to:overBytes)
        do {_=try await byteStore.importFile(overBytes,lease:byteLease);throw NSError(domain:"byte bound bypassed",code:1)} catch let e as NSError where e.domain=="byte bound bypassed" {throw e} catch let e as VideoAssetError {try require(e == .tooLarge,"exact byte bound rejection")} catch {throw error}
        await byteStore.end(byteLease)
        passed("repeated-full-scan-32MiB-byte-bound")
        print("PREPARED BEHAVIORAL CASES \(count); no renderer/App claim")
    }
}

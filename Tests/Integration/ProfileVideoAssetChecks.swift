import Foundation
import PlayerCore

private enum Failure:Error {case rejected}
private func expect(_ value:Bool,_ message:String) throws {if !value {throw NSError(domain:message,code:1)}}
@MainActor private final class Shortcuts:ProfileShortcutStorage {
    var bytes=Data("old-shortcuts".utf8),failNext=false
    func read() throws -> Data? {bytes}
    func write(_ value:Data?) throws {if failNext {failNext=false;throw Failure.rejected};bytes=value ?? Data()}
}
private final class Publication:ProfilePublication {
    var failRemoval=false
    func publish(_ data:Data,to target:URL) throws {try AtomicProfilePublication().publish(data,to:target)}
    func remove(_ target:URL) throws {
        if target.lastPathComponent=="profile-import-journal.json",failRemoval {failRemoval=false;throw Failure.rejected}
        try AtomicProfilePublication().remove(target)
    }
}
@MainActor private final class Gate {var current=true,blocked=false}
@MainActor private final class Runtime:VideoAssetRuntime {
    var assetBinding:VideoAssetPlaybackBinding?=VideoAssetPlaybackBinding(coreID:UUID(),mediaEpoch:UUID(),loadedItemID:UUID(),loadToken:UUID())
    var activeAssets=VideoAssetPipeline(shaders:[],lutGraphs:[]),reject=false,stale=false
    var applications=0,restorations=0
    func applyAssets(_ value:VideoAssetPipeline,binding:VideoAssetPlaybackBinding,ticket:UUID) async throws -> VideoAssetAcceptance {receipt(value,binding:binding,ticket:ticket)}
    func applyProfileAssets(_ value:VideoAssetPipeline,settings:PlaybackSettings,userFragments:[String],binding:VideoAssetPlaybackBinding,ticket:UUID) async throws -> VideoAssetAcceptance {
        applications+=1;try expect(settings.brightness==22 && userFragments.isEmpty,"complete candidate context lost")
        if reject {throw Failure.rejected};if stale {assetBinding=nil}
        return receipt(value,binding:binding,ticket:ticket)
    }
    func restoreAssets(_ value:VideoAssetPipeline,binding:VideoAssetPlaybackBinding,ticket:UUID) async throws -> VideoAssetAcceptance {restorations+=1;return receipt(value,binding:binding,ticket:ticket)}
    private func receipt(_ value:VideoAssetPipeline,binding:VideoAssetPlaybackBinding,ticket:UUID)->VideoAssetAcceptance {
        activeAssets=value
        return VideoAssetAcceptance(binding:binding,ticket:ticket,pipeline:value,configuredAndReadBack:true,producedVideoOutput:true,shadersConfirmed:true,shaderEvidence:value.shaders.isEmpty ? []:["typed injected receipt; no GPU claim"])
    }
    func cancelAssets(ticket:UUID) {}
    func suspendAssetsForCurrentMedia() {activeAssets=VideoAssetPipeline(shaders:[],lutGraphs:[])}
}
@main @MainActor private struct Checks {
    static let identity:BackupShortcutValidator={_,key in key}
    static func resources(_ name:String)->VideoAssetPortableBundle {
        let data=Data("//!DESC \(name)\n//!HOOK MAIN\n//!BIND HOOKED\nvec4 hook() { return HOOKED_tex(HOOKED_pos); }\n".utf8)
        let entry=VideoAssetEntry(kind:.glsl,name:name,sha256:VideoAssetContent.checksum(data),byteCount:data.count,enabled:false)
        return VideoAssetPortableBundle(document:VideoAssetDocument(entries:[entry]),files:[entry.basename:data])
    }
    static func backup(_ resources:VideoAssetPortableBundle?)->UserProfileBackupDocument {
        var global=PlaybackSettings();global.brightness=22
        return UserProfileBackupDocument(global:global,shortcuts:[BackupShortcut(action:"stop",key:"v")],filters:UserVideoFilterChain(),media:MediaPreferenceDocument(),videoAssets:resources,appVersion:"prepared-only")
    }
    static func main() async throws {
        guard CommandLine.arguments.count==2 else {throw Failure.rejected}
        let work=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        guard !FileManager.default.fileExists(atPath:work.path) else {throw Failure.rejected}
        try FileManager.default.createDirectory(at:work,withIntermediateDirectories:true)
        var passed=0
        func group(_ id:String,_ body:() async throws ->Void) async throws {try await body();passed+=1;print("PASS \(id)")}
        func setup(_ id:String) async throws ->(URL,VideoAssetStore,VideoAssetLease,Shortcuts,Data,Data) {
            let dir=work.appendingPathComponent(id,isDirectory:true)
            try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:false)
            let store=try VideoAssetStore(directory:dir.appendingPathComponent("video-assets",isDirectory:true))
            let lease=try await store.begin(),old=resources("old")
            try await store.stageRestore(old,lease:lease);try await store.commit(old.document,lease:lease);await store.end(lease)
            let current=try await store.begin(),oldManifest=try await store.manifestBytes(lease:current)!
            let oldGlobal=Data("old-global-raw".utf8);try oldGlobal.write(to:dir.appendingPathComponent("preferences.json"))
            return (dir,store,current,Shortcuts(),oldGlobal,oldManifest)
        }
        func plan(_ resources:VideoAssetPortableBundle?) throws ->PreparedUserProfileStores {try .prepare(backup(resources),shortcuts:Data("new-shortcuts".utf8))}
        try await group("profile-assets-legacy-canonical-omit-nil") {
            let data=try backup(nil).encoded(shortcutValidator:identity)
            let object=try JSONSerialization.jsonObject(with:data) as! [String:Any]
            try expect(object["videoAssets"]==nil && (object["includes"] as? [String])==["global","shortcuts","filters","media"],"legacy fields changed")
            let restored=try UserProfileBackupDocument.boundedDecode(data,shortcutValidator:identity)
            try expect(try restored.encoded(shortcutValidator:identity)==data,"legacy canonical roundtrip changed")
        }
        try await group("profile-assets-full-bytes-order-enable-roundtrip") {
            let a=resources("first"),b=resources("second");var second=b.document.entries[0];second.enabled=true
            let payload=VideoAssetPortableBundle(document:VideoAssetDocument(entries:a.document.entries+[second]),files:a.files.merging(b.files){_,_ in fatalError()})
            let restored=try UserProfileBackupDocument.boundedDecode(backup(payload).encoded(shortcutValidator:identity),shortcutValidator:identity)
            try expect(restored.videoAssets==payload && restored.includes.last=="videoAssets","full resources/order/enable lost")
        }
        try await group("profile-assets-nested-corruption-before-any-path") {
            let data=try backup(resources("valid")).encoded(shortcutValidator:identity)
            for mutation in 0..<8 {
                var object=try JSONSerialization.jsonObject(with:data) as! [String:Any],assets=object["videoAssets"] as! [String:Any]
                if mutation==0 {assets["extra"]=true}
                else if mutation==1 {assets["files"]=[String:String]()}
                else if mutation==2 {var files=assets["files"] as! [String:String];files[files.keys.first!]=Data("corrupt".utf8).base64EncodedString();assets["files"]=files}
                if mutation>=4 {
                    let malformedDocuments:[Any]=[NSNull(),"not-an-object",1,[Any]()]
                    assets["document"]=malformedDocuments[mutation-4]
                }
                if mutation==3 {object["videoAssets"]=NSNull()} else {object["videoAssets"]=assets}
                var rejected=false
                do {_=try UserProfileBackupDocument.boundedDecode(JSONSerialization.data(withJSONObject:object),shortcutValidator:identity)} catch {rejected=true}
                try expect(rejected,"invalid resource carrier accepted")
            }
            try expect(!FileManager.default.fileExists(atPath:work.appendingPathComponent("never-created").path),"decode created path")
        }
        try await group("profile-assets-nil-legacy-import-preserves-real-manifest") {
            let (dir,store,lease,shortcuts,_,oldManifest)=try await setup("legacy")
            _=try await UserProfileImportCoordinator(directory:dir,shortcuts:shortcuts).applyPrepared(plan(nil),previousAssetManifest:oldManifest,publishAssetManifest:{_ in throw Failure.rejected},isCurrent:{true})
            let saved=try await store.manifestBytes(lease:lease);try expect(saved==oldManifest,"legacy nil cleared assets")
            await store.end(lease)
        }
        try await group("profile-assets-real-immutable-stage-and-journal-commit") {
            let (dir,store,lease,shortcuts,_,old)=try await setup("commit"),incoming=resources("incoming")
            try await store.stageRestore(incoming,lease:lease)
            _=try await UserProfileImportCoordinator(directory:dir,shortcuts:shortcuts).applyPrepared(plan(incoming),previousAssetManifest:old,publishAssetManifest:{try await store.publishProfileManifest($0,lease:lease)},isCurrent:{true})
            await store.end(lease)
            let saved=try await store.exportSnapshot();try expect(saved==incoming && shortcuts.bytes==Data("new-shortcuts".utf8),"complete commit lost bytes")
            try expect(!FileManager.default.fileExists(atPath:dir.appendingPathComponent("profile-import-journal.json").path),"committed cleanup incomplete")
        }
        try await group("profile-assets-shortcut-failure-full-file-rollback") {
            let (dir,store,lease,shortcuts,oldGlobal,old)=try await setup("shortcut-fault"),incoming=resources("incoming")
            try await store.stageRestore(incoming,lease:lease);shortcuts.failNext=true
            var rolled=false
            do {_=try await UserProfileImportCoordinator(directory:dir,shortcuts:shortcuts).applyPrepared(plan(incoming),previousAssetManifest:old,publishAssetManifest:{try await store.publishProfileManifest($0,lease:lease)},isCurrent:{true})}
            catch ProfileImportError.failedAndRolledBack {rolled=true}
            try expect(rolled && shortcuts.bytes==Data("old-shortcuts".utf8),"shortcut failure accepted/lost original")
            let saved=try await store.manifestBytes(lease:lease);try expect(saved==old,"resource manifest rollback failed")
            try expect(try Data(contentsOf:dir.appendingPathComponent("preferences.json"))==oldGlobal,"global rollback failed")
            await store.end(lease)
        }
        try await group("profile-assets-failed-resource-rollback-restart-recovery") {
            let (dir,store,lease,shortcuts,oldGlobal,_)=try await setup("restart"),incoming=resources("incoming")
            let old=try await store.manifestBytes(lease:lease);try await store.stageRestore(incoming,lease:lease)
            var pending=false
            do {_=try await UserProfileImportCoordinator(directory:dir,shortcuts:shortcuts).applyPrepared(plan(incoming),previousAssetManifest:old,publishAssetManifest:{_ in throw Failure.rejected},isCurrent:{true})}
            catch ProfileImportError.recoveryRequired {pending=true}
            try expect(pending,"failed rollback did not block/recover")
            await store.end(lease)
            let recovered=try UserProfileImportCoordinator(directory:dir,shortcuts:shortcuts).recoverPendingImport()
            try expect(recovered == .rolledBack,"pending journal not recovered")
            try expect(try Data(contentsOf:dir.appendingPathComponent("preferences.json"))==oldGlobal,"restart lost original global")
            let saved=try await store.exportSnapshot();try expect(saved.document.entries[0].name=="old","restart lost asset manifest")
        }
        try await group("profile-assets-committed-cleanup-restart-keeps-new") {
            let (dir,store,lease,shortcuts,_,old)=try await setup("cleanup"),incoming=resources("incoming")
            try await store.stageRestore(incoming,lease:lease);let publication=Publication();publication.failRemoval=true
            let outcome=try await UserProfileImportCoordinator(directory:dir,shortcuts:shortcuts,publication:publication).applyPrepared(plan(incoming),previousAssetManifest:old,publishAssetManifest:{try await store.publishProfileManifest($0,lease:lease)},isCurrent:{true})
            try expect(outcome.cleanupPending,"cleanup false success")
            await store.end(lease)
            let recovered=try UserProfileImportCoordinator(directory:dir,shortcuts:shortcuts).recoverPendingImport()
            try expect(recovered == .committedCleanup,"committed journal rolled back")
            let saved=try await store.exportSnapshot();try expect(saved==incoming,"new committed resources lost")
        }
        try await group("profile-assets-current-cancellation-restores-all-before-commit") {
            let (dir,store,lease,shortcuts,oldGlobal,old)=try await setup("cancel"),incoming=resources("incoming")
            try await store.stageRestore(incoming,lease:lease)
            let gate=Gate(),newManifest=try incoming.document.encoded()
            var rolled=false
            do {_=try await UserProfileImportCoordinator(directory:dir,shortcuts:shortcuts).applyPrepared(plan(incoming),previousAssetManifest:old,publishAssetManifest:{bytes in
                try await store.publishProfileManifest(bytes,lease:lease)
                if bytes==newManifest {await MainActor.run {gate.current=false}}
            },isCurrent:{gate.current})}
            catch ProfileImportError.failedAndRolledBack {rolled=true}
            let saved=try await store.manifestBytes(lease:lease)
            try expect(rolled && saved==old && shortcuts.bytes==Data("old-shortcuts".utf8),"cancelled current gate left new resources/shortcuts")
            try expect(try Data(contentsOf:dir.appendingPathComponent("preferences.json"))==oldGlobal,"cancelled current gate lost legacy files")
            try expect(!FileManager.default.fileExists(atPath:dir.appendingPathComponent("profile-import-journal.json").path),"cancelled rollback leaked journal")
            await store.end(lease)
        }
        try await group("profile-assets-second-coordinator-recovery-refused-during-publication") {
            let (dir,store,lease,shortcuts,_,old)=try await setup("reentrant"),incoming=resources("incoming")
            try await store.stageRestore(incoming,lease:lease)
            let gate=Gate()
            _=try await UserProfileImportCoordinator(directory:dir,shortcuts:shortcuts).applyPrepared(plan(incoming),previousAssetManifest:old,publishAssetManifest:{bytes in
                await MainActor.run {
                    do {_=try UserProfileImportCoordinator(directory:dir,shortcuts:shortcuts).recoverPendingImport()}
                    catch ProfileImportError.pendingRecovery {gate.blocked=true}
                    catch {gate.blocked=false}
                }
                try await store.publishProfileManifest(bytes,lease:lease)
            },isCurrent:{true})
            try expect(gate.blocked,"second coordinator restored a live asynchronous journal")
            await store.end(lease)
            let saved=try await store.exportSnapshot();try expect(saved==incoming,"reentrant recovery damaged committed resource carrier")
        }
        try await group("profile-assets-binding-changes-after-runtime-before-commit-rollback") {
            let (dir,store,lease,shortcuts,oldGlobal,old)=try await setup("media-mid-journal")
            await store.end(lease)
            let incoming=resources("incoming"),newManifest=try incoming.document.encoded(),runtime=Runtime()
            let owner=VideoAssetsController(store:store,runtime:runtime);owner.load();await owner.waitForIdle()
            var rejected=false,attempted=0
            do {_=try await owner.importProfile(backup(incoming),commit:{previous,publish,assetCurrent in
                attempted+=1
                return try await UserProfileImportCoordinator(directory:dir,shortcuts:shortcuts).applyPrepared(plan(incoming),previousAssetManifest:previous,publishAssetManifest:{bytes in
                    try await publish(bytes)
                    if bytes==newManifest {await MainActor.run {runtime.assetBinding=nil}}
                },isCurrent:{assetCurrent()})
            })} catch ProfileImportError.failedAndRolledBack {rejected=true}
            try expect(rejected && attempted==1 && !owner.hasActiveJobs,"late obsolete binding was committed or left a live job")
            let current=try await store.begin(),saved=try await store.manifestBytes(lease:current)
            try expect(saved==old && shortcuts.bytes==Data("old-shortcuts".utf8),"late obsolete binding left candidate manifest or shortcut bytes")
            try expect(try Data(contentsOf:dir.appendingPathComponent("preferences.json"))==oldGlobal,"late obsolete binding left candidate global bytes")
            await store.end(current)
        }
        for stale in [false,true] {
            try await group(stale ? "profile-assets-runtime-epoch-stale-no-commit":"profile-assets-runtime-reject-no-commit") {
                let store=try VideoAssetStore(directory:work.appendingPathComponent(stale ? "stale":"reject",isDirectory:true)),runtime=Runtime()
                runtime.reject = !stale;runtime.stale=stale
                let owner=VideoAssetsController(store:store,runtime:runtime);owner.load();await owner.waitForIdle()
                var commits=0,rejected=false
                do {_=try await owner.importProfile(backup(resources("candidate")),commit:{_,_,_ in commits+=1;return ProfileImportOutcome(cleanupPending:false)})} catch {rejected=true}
                try expect(rejected && commits==0 && !owner.hasActiveJobs && runtime.applications==1,"failed/stale runtime committed or leaked job")
                try expect(stale ? runtime.restorations==0 : runtime.restorations==1,"restore crossed obsolete binding or was not actually awaited")
                let saved=try await store.exportSnapshot();try expect(saved.document.entries.isEmpty,"failed candidate changed flat manifest")
            }
        }
        try expect(passed==13,"prepared ID count changed")
        print("MODEL/FILESYSTEM ONLY; no App/GPU/pixel success claim")
    }
}

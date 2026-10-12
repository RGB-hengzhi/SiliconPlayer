import Foundation
import CryptoKit

/// Pure byte plan built in a background task after host shortcut-policy checks.
/// Internal construction prevents an external caller injecting arbitrary journal paths.
public struct PreparedUserProfileStores: Sendable {
    let targets: [String:Data]
    let shortcuts: Data
    public let videoAssetManifest: Data?
    public static func prepare(_ backup: UserProfileBackupDocument, shortcuts: Data) throws -> Self {
        _=try backup.encoded(shortcutValidator: {_,key in key})
        guard shortcuts.count<=UserProfileImportCoordinator.maximumShortcutBytes else {throw MediaPreferenceError.tooLarge}
        let encoder=JSONEncoder()
        var targets=["preferences.json":try encoder.encode(backup.global),
                     "user-video-filters.json":try encoder.encode(backup.filters),
                     "media-preferences.json":try backup.media.encoded()]
        if let web=backup.web {targets["web-media-preferences.json"]=try encoder.encode(web)}
        let manifest=try backup.videoAssets?.document.encoded()
        if let manifest {targets["video-assets/video-assets.json"]=manifest}
        return Self(targets:targets,shortcuts:shortcuts,videoAssetManifest:manifest)
    }
}

/// File-only phases run on this actor; isolated shortcut reads/writes stay on
/// MainActor between these phases. Original journal schema remains recoverable.
actor ProfileImportDiskWorker {
    private struct Previous: Codable {let existed:Bool;let data:Data?;let sha256:String?}
    private enum Phase:String,Codable {case prepared,committed}
    private struct Journal:Codable {
        let version:Int;let phase:Phase;let stagingID:UUID
        let files:[String:Previous];let shortcuts:Data?;let shortcutSHA256:String?
    }
    private static let order=["preferences.json","user-video-filters.json","media-preferences.json","web-media-preferences.json","video-assets/video-assets.json"]
    private let directory:URL
    private let publication:any ProfilePublication
    private var journal:Journal?
    private var targets:[String:Data]=[:]
    private var journalURL:URL {directory.appendingPathComponent("profile-import-journal.json")}
    private var stage:URL {directory.appendingPathComponent(".profile-import-"+journal!.stagingID.uuidString,isDirectory:true)}
    init(directory:URL,publication:any ProfilePublication) {self.directory=directory;self.publication=publication}
    private func checksum(_ bytes:Data?) -> String? {bytes.map{SHA256.hash(data:$0).map{String(format:"%02x",$0)}.joined()}}
    func prepare(_ plan:PreparedUserProfileStores,shortcuts:Data?,previousAssetManifest:Data?) throws {
        guard journal==nil,Set(plan.targets.keys).isSubset(of:Set(Self.order)),directory.isFileURL,
              !FileManager.default.fileExists(atPath:journalURL.path) else {throw ProfileImportError.pendingRecovery}
        var previous:[String:Previous]=[:]
        for name in Self.order where plan.targets[name] != nil {
            let bytes:Data?
            if name=="video-assets/video-assets.json" {bytes=previousAssetManifest}
            else {bytes=try BoundedProfileFile.read(directory.appendingPathComponent(name),maximumBytes:UserProfileBackupDocument.maximumLegacyBytes,allowMissing:true)}
            guard (bytes?.count ?? 0)<=(name.hasPrefix("video-assets/") ? VideoAssetDocument.maximumManifestBytes : UserProfileBackupDocument.maximumLegacyBytes) else {throw MediaPreferenceError.tooLarge}
            previous[name]=Previous(existed:bytes != nil,data:bytes,sha256:checksum(bytes))
        }
        let value=Journal(version:1,phase:.prepared,stagingID:UUID(),files:previous,shortcuts:shortcuts,shortcutSHA256:checksum(shortcuts))
        let bytes=try JSONEncoder().encode(value);guard bytes.count<=64*1024*1024 else {throw MediaPreferenceError.tooLarge}
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let staging=directory.appendingPathComponent(".profile-import-"+value.stagingID.uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:staging,withIntermediateDirectories:false)
        do {
            for name in Self.order where plan.targets[name] != nil {
                let target=staging.appendingPathComponent(name)
                if name.hasPrefix("video-assets/") {try FileManager.default.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:false)}
                try publication.publish(plan.targets[name]!,to:target)
            }
            try publication.publish(bytes,to:journalURL)
        } catch {try? FileManager.default.removeItem(at:staging);throw error}
        targets=plan.targets;journal=value
    }
    func publishTargets() throws {
        guard journal?.phase == .prepared else {throw ProfileImportError.invalidJournal}
        for name in Self.order where name != "video-assets/video-assets.json" {
            if let bytes=targets[name] {try Task.checkCancellation();try publication.publish(bytes,to:directory.appendingPathComponent(name))}
        }
    }
    func markCommitted() throws {
        guard let old=journal,old.phase == .prepared else {throw ProfileImportError.invalidJournal}
        let committed=Journal(version:1,phase:.committed,stagingID:old.stagingID,files:old.files,shortcuts:old.shortcuts,shortcutSHA256:old.shortcutSHA256)
        try publication.publish(JSONEncoder().encode(committed),to:journalURL)
        journal=committed
    }
    func restoreFiles() throws {
        guard let value=journal,value.phase == .prepared else {throw ProfileImportError.invalidJournal}
        for name in value.files.keys.sorted() where name != "video-assets/video-assets.json" {
            let prior=value.files[name]!,target=directory.appendingPathComponent(name)
            if let bytes=prior.data {guard checksum(bytes)==prior.sha256 else {throw ProfileImportError.invalidJournal};try publication.publish(bytes,to:target)}
            else {try publication.remove(target)}
        }
    }
    func clear() throws {
        guard journal != nil else {throw ProfileImportError.invalidJournal}
        if FileManager.default.fileExists(atPath:stage.path) {try FileManager.default.removeItem(at:stage)}
        try publication.remove(journalURL)
    }
}

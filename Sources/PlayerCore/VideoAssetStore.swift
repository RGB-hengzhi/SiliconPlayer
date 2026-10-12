import Foundation
import Darwin

public struct VideoAssetLease: Sendable {
    public let id: UUID
    public let document: VideoAssetDocument
    public let previousManifestSHA256: String?
}

/// Background actor, descriptor anchored. One owned lock covers candidate
/// staging, runtime acceptance and flat-manifest publication. Immutable assets
/// precede that commit; this is not a multiple-file power-loss atomic promise.
public actor VideoAssetStore {
    public let directory: URL
    private let root: Int32
    private var leases: [UUID:(fd:Int32,previousSHA:String?)] = [:]
    public init(directory: URL) throws {
        self.directory=directory.standardizedFileURL
        root=try Self.directoryFD(directory,createFinal:true)
    }
    deinit { for value in leases.values { Darwin.close(value.fd) }; Darwin.close(root) }

    public func begin() throws -> VideoAssetLease {
        guard leases.isEmpty else { throw VideoAssetError.busy }
        let lock=openat(root,".video-assets.lock",O_RDWR|O_CREAT|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK,mode_t(0o600))
        guard lock>=0 else { throw VideoAssetError.invalidSource }
        do {
            var st=stat()
            guard fstat(lock,&st)==0, Self.regular(st), flock(lock,LOCK_EX|LOCK_NB)==0 else { throw VideoAssetError.busy }
            let data=try read("video-assets.json",limit:VideoAssetDocument.maximumManifestBytes,missing:true)
            let doc=try data.map(VideoAssetDocument.decode) ?? VideoAssetDocument()
            let id=UUID(), digest=data.map(VideoAssetContent.checksum)
            leases[id]=(lock,digest)
            return VideoAssetLease(id:id,document:doc,previousManifestSHA256:digest)
        } catch { Darwin.close(lock); throw error }
    }
    public func end(_ lease: VideoAssetLease) {
        if let value=leases.removeValue(forKey:lease.id) { _=flock(value.fd,LOCK_UN); Darwin.close(value.fd) }
    }
    public func loadVerified() throws -> VideoAssetDocument {
        let lease=try begin(); defer {end(lease)}
        for entry in lease.document.entries { _=try assetBytes(entry) }
        return lease.document
    }
    public func importFile(_ source: URL, lease: VideoAssetLease) throws -> VideoAssetEntry {
        try assertLease(lease)
        guard let kind=VideoAssetKind(rawValue:source.pathExtension.lowercased()) else { throw VideoAssetError.unsupportedFormat }
        let descriptor=try Self.fileFD(source)
        defer {Darwin.close(descriptor)}
        let data=try Self.bytes(descriptor,limit:VideoAssetContent.maximumBytes(kind))
        try Task.checkCancellation()
        try VideoAssetContent.validate(data,kind:kind)
        let digest=VideoAssetContent.checksum(data)
        if let prior=lease.document.entries.first(where:{$0.kind==kind && $0.sha256==digest}) {
            _=try assetBytes(prior); return prior
        }
        let name=source.deletingPathExtension().lastPathComponent
        let result=VideoAssetEntry(kind:kind,name:name,sha256:digest,byteCount:data.count)
        _=try VideoAssetDocument(entries:lease.document.entries+[result]).validated()
        try immutable(data,entry:result)
        return result
    }
    public func verifiedURLs(_ candidate: VideoAssetDocument, lease: VideoAssetLease) throws -> [UUID:URL] {
        try assertLease(lease); _=try candidate.validated()
        var urls:[UUID:URL]=[:]
        for entry in candidate.entries {
            _=try assetBytes(entry)
            urls[entry.id]=directory.appendingPathComponent(entry.basename)
        }
        return urls
    }
    public func commit(_ candidate: VideoAssetDocument, lease: VideoAssetLease) throws {
        try assertLease(lease)
        let data=try candidate.encoded()
        for entry in candidate.entries { _=try assetBytes(entry) }
        let current=try read("video-assets.json",limit:VideoAssetDocument.maximumManifestBytes,missing:true)
        guard current.map(VideoAssetContent.checksum)==lease.previousManifestSHA256 else { throw VideoAssetError.changedAsset }
        try Task.checkCancellation()
        try publish(data,to:"video-assets.json")
    }
    public func manifestBytes(lease: VideoAssetLease) throws -> Data? {
        try assertLease(lease)
        let bytes=try read("video-assets.json",limit:VideoAssetDocument.maximumManifestBytes,missing:true)
        guard bytes.map(VideoAssetContent.checksum)==lease.previousManifestSHA256 else {throw VideoAssetError.changedAsset}
        return bytes
    }
    /// Profile journal owns this publication and rollback while our exact lock
    /// remains held. It has no resource-byte deletion or renderer success claim.
    public func publishProfileManifest(_ bytes: Data?,lease: VideoAssetLease) throws {
        try assertLease(lease)
        if let bytes { _=try VideoAssetDocument.decode(bytes); try publish(bytes,to:"video-assets.json") }
        else if unlinkat(root,"video-assets.json",0) != 0 && errno != ENOENT {throw VideoAssetError.applyFailed}
    }
    /// Startup recovery precedes any service initialization. Descriptor-rooted
    /// publication protects the fixed flat manifest even in the sync recovery.
    public nonisolated static func recoverProfileManifest(_ bytes: Data?,directory: URL) throws {
        let root=try directoryFD(directory,createFinal:true);defer {Darwin.close(root)}
        if let bytes {
            guard bytes.count<=VideoAssetDocument.maximumManifestBytes else {throw VideoAssetError.tooLarge}
            let temporary=".video-assets-recovery-"+UUID().uuidString+".tmp"
            let fd=openat(root,temporary,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC,mode_t(0o600))
            guard fd>=0 else {throw VideoAssetError.invalidSource}
            defer {Darwin.close(fd);_=unlinkat(root,temporary,0)}
            try writeAll(bytes,fd:fd);guard fsync(fd)==0 else {throw VideoAssetError.applyFailed}
            guard renameat(root,temporary,root,"video-assets.json")==0 else {throw VideoAssetError.applyFailed}
        } else if unlinkat(root,"video-assets.json",0) != 0 && errno != ENOENT {throw VideoAssetError.applyFailed}
    }
    public func exportSnapshot() throws -> VideoAssetPortableBundle {
        let lease=try begin(); defer {end(lease)}
        var files:[String:Data]=[:]
        for entry in lease.document.entries {files[entry.basename]=try assetBytes(entry)}
        return try VideoAssetPortableBundle(document:lease.document,files:files).validated()
    }
    /// Host stages the entire profile before this method, then places the flat
    /// video-assets.json in its existing prepared/committed rollback journal.
    /// Only this immutable-resource step occurs here, not that journal commit.
    public func stageRestore(_ backup: VideoAssetPortableBundle, lease: VideoAssetLease) throws {
        try assertLease(lease); _=try backup.validated()
        for entry in backup.document.entries { try immutable(backup.files[entry.basename]!,entry:entry) }
    }
    public nonisolated static func readPortable(_ url: URL) throws -> VideoAssetPortableBundle {
        let fd=try fileFD(url);defer {Darwin.close(fd)}
        return try VideoAssetPortableBundle.decode(bytes(fd,limit:VideoAssetPortableBundle.maximumBytes))
    }
    /// Only the explicit resource archive is exported. The actor snapshots all
    /// managed bytes first; publication never writes into its owned directory.
    public nonisolated static func writePortable(_ bundle: VideoAssetPortableBundle,to target: URL,
                                                 managedDirectory: URL) throws {
        let managed=managedDirectory.standardizedFileURL.path
        guard target.isFileURL,!target.lastPathComponent.hasPrefix("._"),
              target.standardizedFileURL.path != managed,
              !target.standardizedFileURL.path.hasPrefix(managed+"/") else {throw VideoAssetError.invalidSource}
        let data=try bundle.encoded()
        let parent=try directoryFD(target.deletingLastPathComponent());defer {Darwin.close(parent)}
        // Existing special/link targets reject even though rename would replace
        // the leaf. Parent components are separately descriptor anchored.
        var st=stat()
        if fstatat(parent,target.lastPathComponent,&st,AT_SYMLINK_NOFOLLOW)==0 {
            guard regular(st) else {throw VideoAssetError.invalidSource}
        } else {guard errno==ENOENT else {throw VideoAssetError.invalidSource}}
        let temporary=".video-assets-export-"+UUID().uuidString+".tmp"
        let fd=openat(parent,temporary,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC,mode_t(0o600))
        guard fd>=0 else {throw VideoAssetError.invalidSource}
        defer {Darwin.close(fd);_=unlinkat(parent,temporary,0)}
        try writeAll(data,fd:fd);guard fsync(fd)==0 else {throw VideoAssetError.applyFailed}
        try Task.checkCancellation()
        guard renameat(parent,temporary,parent,target.lastPathComponent)==0 else {throw VideoAssetError.applyFailed}
    }
    private func assertLease(_ lease: VideoAssetLease) throws {
        guard let owned=leases[lease.id], owned.previousSHA==lease.previousManifestSHA256 else { throw VideoAssetError.staleTicket }
    }
    private func assetBytes(_ entry: VideoAssetEntry) throws -> Data {
        _=try VideoAssetDocument(entries:[entry]).validated()
        guard let data=try read(entry.basename,limit:VideoAssetContent.maximumBytes(entry.kind)),
              data.count==entry.byteCount, VideoAssetContent.checksum(data)==entry.sha256 else { throw VideoAssetError.changedAsset }
        try VideoAssetContent.validate(data,kind:entry.kind)
        return data
    }
    private func read(_ leaf: String, limit: Int, missing: Bool=false) throws -> Data? {
        let fd=openat(root,leaf,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC)
        guard fd>=0 else { if missing && errno==ENOENT {return nil}; throw VideoAssetError.invalidSource }
        defer {Darwin.close(fd)}
        return try Self.bytes(fd,limit:limit)
    }
    private func immutable(_ data: Data, entry: VideoAssetEntry) throws {
        if let prior=try read(entry.basename,limit:VideoAssetContent.maximumBytes(entry.kind),missing:true) {
            guard prior==data else {throw VideoAssetError.changedAsset}; return
        }
        let storage=try storageUsage()
        guard storage.count<128,storage.bytes+data.count<=32*1024*1024 else {throw VideoAssetError.tooLarge}
        // O_EXCL never overwrites existing content, even if another process
        // ignored our advisory lock. Existing files must match the full SHA.
        let fd=openat(root,entry.basename,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC,mode_t(0o600))
        guard fd>=0 else {
            if errno==EEXIST { _=try assetBytes(entry); return }
            throw VideoAssetError.invalidSource
        }
        var complete=false
        defer {Darwin.close(fd); if !complete {_=unlinkat(root,entry.basename,0)} }
        try Self.writeAll(data,fd:fd); guard fsync(fd)==0 else {throw VideoAssetError.applyFailed}
        complete=true
        _=try assetBytes(entry)
    }
    private func publish(_ data: Data, to leaf: String) throws {
        let temporary=".video-assets-"+UUID().uuidString+".tmp"
        let fd=openat(root,temporary,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC,mode_t(0o600))
        guard fd>=0 else {throw VideoAssetError.invalidSource}
        defer {Darwin.close(fd); _=unlinkat(root,temporary,0)}
        try Self.writeAll(data,fd:fd); guard fsync(fd)==0 else {throw VideoAssetError.applyFailed}
        // rename within the held directory does not follow a swapped leaf.
        // No fallible operation follows a successful publication: callers
        // must never roll runtime back after a manifest was already committed.
        guard renameat(root,temporary,root,leaf)==0 else {throw VideoAssetError.applyFailed}
    }
    private static func regular(_ s: stat) -> Bool {s.st_mode & mode_t(S_IFMT)==mode_t(S_IFREG) && s.st_size>=0}
    private func storageUsage() throws -> (count:Int,bytes:Int) {
        // A dup would share the root directory file-description offset.
        // A fresh open creates an independent offset for every full scan.
        let copy=openat(root,".",O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NONBLOCK)
        guard copy>=0 else {throw VideoAssetError.invalidSource}
        guard let stream=fdopendir(copy) else {Darwin.close(copy);throw VideoAssetError.invalidSource}
        defer {closedir(stream)}
        var count=0,total=0
        while true {
            errno=0
            guard let row=readdir(stream) else {
                guard errno==0 else {throw VideoAssetError.invalidSource}; break
            }
            let name=withUnsafePointer(to:&row.pointee.d_name) {
                $0.withMemoryRebound(to:CChar.self,capacity:MemoryLayout.size(ofValue:row.pointee.d_name)) {String(cString:$0)}
            }
            // Automatic exFAT AppleDouble records are never asset inputs or
            // manifest entries. This store neither reads nor deletes them.
            if name=="." || name==".." || name.hasPrefix("._") || name==".video-assets.lock" || name=="video-assets.json" {continue}
            let url=URL(fileURLWithPath:name),digest=url.deletingPathExtension().lastPathComponent
            guard let kind=VideoAssetKind(rawValue:url.pathExtension),digest.utf8.count==64,
                  digest.utf8.allSatisfy({(48...57).contains($0)||(97...102).contains($0)}) else {throw VideoAssetError.changedAsset}
            var st=stat()
            guard fstatat(root,name,&st,AT_SYMLINK_NOFOLLOW)==0,Self.regular(st),st.st_size<=VideoAssetContent.maximumBytes(kind) else {throw VideoAssetError.changedAsset}
            count+=1; total+=Int(st.st_size)
            guard count<=128,total<=32*1024*1024 else {throw VideoAssetError.tooLarge}
        }
        return (count,total)
    }
    private static func bytes(_ fd: Int32, limit: Int) throws -> Data {
        var before=stat(),after=stat()
        guard fstat(fd,&before)==0,regular(before),before.st_size<=limit else {throw VideoAssetError.invalidSource}
        let file=FileHandle(fileDescriptor:fd,closeOnDealloc:false)
        let bytes=try file.read(upToCount:limit+1) ?? Data()
        guard bytes.count<=limit, bytes.count==before.st_size, fstat(fd,&after)==0,
              before.st_dev==after.st_dev,before.st_ino==after.st_ino,before.st_size==after.st_size,
              before.st_mtimespec.tv_sec==after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec==after.st_mtimespec.tv_nsec else {throw VideoAssetError.changedSource}
        return bytes
    }
    private static func writeAll(_ bytes: Data,fd: Int32) throws {
        try bytes.withUnsafeBytes { buffer in
            var done=0
            while done<buffer.count {
                try Task.checkCancellation()
                let n=Darwin.write(fd,buffer.baseAddress!.advanced(by:done),buffer.count-done)
                if n<0 && errno==EINTR {continue}
                guard n>0 else {throw VideoAssetError.applyFailed}; done+=n
            }
        }
    }
    private static func fileFD(_ url: URL) throws -> Int32 {
        guard url.isFileURL,!url.lastPathComponent.hasPrefix("._") else {throw VideoAssetError.invalidSource}
        let parent=try directoryFD(url.deletingLastPathComponent()); defer {Darwin.close(parent)}
        let fd=openat(parent,url.lastPathComponent,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC)
        guard fd>=0 else {throw VideoAssetError.invalidSource}; return fd
    }
    private static func directoryFD(_ url: URL,createFinal: Bool=false) throws -> Int32 {
        guard url.isFileURL,url.path.hasPrefix("/") else {throw VideoAssetError.invalidSource}
        let parts=url.path.split(separator:"/",omittingEmptySubsequences:true).map(String.init)
        guard url.path.utf8.count<=4096,!parts.isEmpty,
              parts.allSatisfy({$0 != "." && $0 != ".." && !$0.hasPrefix("._") && !$0.unicodeScalars.contains(where:{$0.value<32 || $0.value==127})}) else {throw VideoAssetError.invalidSource}
        var held=Darwin.open("/",O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NONBLOCK)
        guard held>=0 else {throw VideoAssetError.invalidSource}
        do {
            for (i,part) in parts.enumerated() {
                var child=openat(held,part,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC)
                // Only init's explicitly supplied owned store root may create
                // missing support/managed directories. Input/export anchors
                // call this with false and never create source parents.
                if child<0 && errno==ENOENT && createFinal {
                    guard mkdirat(held,part,mode_t(0o700))==0 || errno==EEXIST else {throw VideoAssetError.invalidSource}
                    child=openat(held,part,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC)
                }
                guard child>=0 else {throw VideoAssetError.invalidSource}
                Darwin.close(held); held=child
            }
            return held
        } catch {Darwin.close(held);throw error}
    }
}

/// Portable profile payload has exact SHA-name keys and full bounded bytes.
/// Missing/extra entries reject the restore before creating a target.
public struct VideoAssetPortableBundle: Codable, Equatable, Sendable {
    public static let maximumBytes=24*1024*1024
    public let document: VideoAssetDocument
    public let files: [String:Data]
    public init(document: VideoAssetDocument,files: [String:Data]) {self.document=document;self.files=files}
    public func validated() throws -> Self {
        _=try document.validated()
        guard Set(files.keys)==Set(document.entries.map(\.basename)) else {throw VideoAssetError.invalidDocument}
        for e in document.entries {
            guard let bytes=files[e.basename],bytes.count==e.byteCount,VideoAssetContent.checksum(bytes)==e.sha256 else {throw VideoAssetError.changedAsset}
            try VideoAssetContent.validate(bytes,kind:e.kind)
        }
        return self
    }
    public func encoded() throws -> Data {
        _=try validated()
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let bytes=try encoder.encode(self)
        guard bytes.count<=Self.maximumBytes else {throw VideoAssetError.tooLarge}
        return bytes
    }
    public static func decode(_ bytes: Data) throws -> Self {
        try BoundedProfileJSON.preflight(bytes,maximumBytes:maximumBytes)
        guard let object=try JSONSerialization.jsonObject(with:bytes) as? [String:Any],
              Set(object.keys)==Set(["document","files"]),
              let raw=object["document"] as? [String:Any] else {throw VideoAssetError.invalidDocument}
        _=try VideoAssetDocument.decode(JSONSerialization.data(withJSONObject:raw))
        return try JSONDecoder().decode(Self.self,from:bytes).validated()
    }
}

import Foundation
import CryptoKit

public enum VideoAssetError: Error, Equatable, LocalizedError {
    case invalidDocument, unsupportedFormat, tooLarge, invalidCube, invalidShader
    case invalidSource, changedSource, changedAsset, unknownAsset, busy, staleTicket
    case unsupportedRenderer, shaderNotConfirmed, applyFailed, rollbackFailed
    case separateResourceArchiveRequired
    public var errorDescription:String? {
        switch self {
        case .separateResourceArchiveRequired:return "设置备份尚未包含 GLSL/LUT 资源。请先在资源面板导出完整资源包；一体设置备份仍待补齐。"
        case .busy:return "视频资源仍在读取或验证，请稍后重试。"
        default:return "视频资源验证失败，原保存设置未覆盖。"
        }
    }
}

public enum VideoAssetKind: String, Codable, Sendable { case glsl, cube }

public struct VideoAssetEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let kind: VideoAssetKind
    public let name: String
    public let sha256: String
    public let byteCount: Int
    public var enabled: Bool
    public var basename: String { sha256 + "." + kind.rawValue }
    public init(id: UUID = UUID(), kind: VideoAssetKind, name: String,
                sha256: String, byteCount: Int, enabled: Bool = false) {
        self.id=id; self.kind=kind; self.name=name; self.sha256=sha256
        self.byteCount=byteCount; self.enabled=enabled
    }
}

/// Entries carry user order. Effective order is independently filtered by
/// CPU LUT stage / GPU GLSL stage; this does not promise cross-stage interleave.
public struct VideoAssetDocument: Codable, Equatable, Sendable {
    public static let maximumManifestBytes = 64 * 1024
    public static let maximumAssetCount = 12
    public static let maximumTotalBytes = 16 * 1024 * 1024
    public let version: Int
    public var entries: [VideoAssetEntry]
    public init(entries: [VideoAssetEntry] = []) { version=1; self.entries=entries }
    public func validated() throws -> Self {
        guard version == 1, entries.count <= Self.maximumAssetCount,
              Set(entries.map(\.id)).count == entries.count,
              Set(entries.map(\.basename)).count == entries.count else { throw VideoAssetError.invalidDocument }
        var total=0
        for e in entries {
            guard !e.name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
                  e.name.utf8.count <= 160, !e.name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
                  e.sha256.utf8.count == 64,
                  e.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  e.byteCount > 0, e.byteCount <= VideoAssetContent.maximumBytes(e.kind) else {
                throw VideoAssetError.invalidDocument
            }
            total += e.byteCount
            guard total <= Self.maximumTotalBytes else { throw VideoAssetError.tooLarge }
        }
        return self
    }
    public func encoded() throws -> Data {
        _ = try validated()
        let encoder=JSONEncoder(); encoder.outputFormatting=[.sortedKeys]
        let bytes=try encoder.encode(self)
        guard bytes.count <= Self.maximumManifestBytes else { throw VideoAssetError.tooLarge }
        return bytes
    }
    public static func decode(_ bytes: Data) throws -> Self {
        try BoundedProfileJSON.preflight(bytes, maximumBytes: maximumManifestBytes)
        guard let object=try JSONSerialization.jsonObject(with:bytes) as? [String:Any],
              Set(object.keys)==Set(["version","entries"]),
              let rows=object["entries"] as? [[String:Any]],
              rows.allSatisfy({Set($0.keys)==Set(["id","kind","name","sha256","byteCount","enabled"])}) else {
            throw VideoAssetError.invalidDocument
        }
        return try JSONDecoder().decode(Self.self,from:bytes).validated()
    }
    public func enabled(_ kind: VideoAssetKind) -> [VideoAssetEntry] { entries.filter { $0.kind == kind && $0.enabled } }
    public mutating func setEnabled(_ id: UUID, _ value: Bool) throws {
        guard let i=entries.firstIndex(where:{$0.id==id}) else { throw VideoAssetError.unknownAsset }
        entries[i].enabled=value
    }
    public mutating func move(_ id: UUID, before target: UUID?) throws {
        guard let i=entries.firstIndex(where:{$0.id==id}), target != id else { throw VideoAssetError.unknownAsset }
        if let target, !entries.contains(where:{$0.id==target}) { throw VideoAssetError.unknownAsset }
        let entry=entries.remove(at:i)
        if let target, let j=entries.firstIndex(where:{$0.id==target}) { entries.insert(entry,at:j) }
        else { entries.append(entry) }
    }
}

public enum VideoAssetContent {
    public static func maximumBytes(_ kind: VideoAssetKind) -> Int { kind == .glsl ? 512 * 1024 : 2 * 1024 * 1024 }
    public static func checksum(_ bytes: Data) -> String { SHA256.hash(data:bytes).map { String(format:"%02x",$0) }.joined() }
    public static func validate(_ bytes: Data, kind: VideoAssetKind) throws {
        guard !bytes.isEmpty, bytes.count <= maximumBytes(kind) else { throw VideoAssetError.tooLarge }
        guard let text=String(data:bytes,encoding:.utf8), !text.utf8.contains(0) else { throw VideoAssetError.unsupportedFormat }
        switch kind {
        case .glsl:
            // Structural import gate only. Neither this check nor a property
            // setter certifies compilation, GPU safety, pixels or HDR intent.
            guard text.range(of:"\\bhook\\s*\\(",options:.regularExpression) != nil,
                  text.split(separator:"\n",omittingEmptySubsequences:false).allSatisfy({$0.utf8.count<=8192}) else {
                throw VideoAssetError.invalidShader
            }
            _=try shaderDescription(bytes)
        case .cube: try validateCube(text)
        }
    }
    public static func shaderDescription(_ bytes: Data) throws -> String {
        guard bytes.count<=maximumBytes(.glsl),let text=String(data:bytes,encoding:.utf8) else {throw VideoAssetError.invalidShader}
        let metadata=text.split(separator:"\n").map{$0.trimmingCharacters(in:.whitespacesAndNewlines)}.filter{$0.hasPrefix("//!")}
        // Initial renderer-verifiable subset: one unconditional MAIN hook.
        // PARAM/TEXTURE/WHEN/COMPUTE and multiple hooks need separate routing,
        // allocation and positive-pass evidence before enabling that scope.
        guard metadata.count==3,metadata.filter({$0=="//!HOOK MAIN"}).count==1,
              metadata.filter({$0=="//!BIND HOOKED"}).count==1,
              let desc=metadata.first(where:{$0.hasPrefix("//!DESC ")}) else {throw VideoAssetError.invalidShader}
        let value=String(desc.dropFirst(8))
        guard !value.isEmpty,value.utf8.count<=128,
              !value.unicodeScalars.contains(where:{$0.value<32 || $0.value==127}) else {throw VideoAssetError.invalidShader}
        return value
    }
    private static func validateCube(_ text: String) throws {
        var size: Int?, rows=0, minSeen=false, maxSeen=false, started=false
        for raw in text.split(separator:"\n",omittingEmptySubsequences:false) {
            // FFmpeg parse_cube uses a 512-byte fgets buffer. Keep each source
            // physical line below that bound instead of accepting split lines.
            guard raw.utf8.count <= 500 else { throw VideoAssetError.invalidCube }
            let line=raw.trimmingCharacters(in:.whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let words=line.split(whereSeparator:{$0==" " || $0=="\t"}).map(String.init)
            if words.first=="TITLE" {
                guard size==nil,!started, line.utf8.count<=256 else { throw VideoAssetError.invalidCube }; continue
            }
            if words.first=="LUT_3D_SIZE" {
                guard size==nil, !started, words.count==2,
                      words[1].utf8.allSatisfy({(48...57).contains($0)}),
                      let n=Int(words[1]), (2...33).contains(n) else { throw VideoAssetError.invalidCube }
                size=n; continue
            }
            if words.first=="DOMAIN_MIN" || words.first=="DOMAIN_MAX" {
                guard size != nil, !started, words.count==4 else { throw VideoAssetError.invalidCube }
                let values=try triple(Array(words.dropFirst()))
                let isMin=words[0]=="DOMAIN_MIN"
                // Initial product subset deliberately uses normalized input.
                // FFmpeg 9 parse_cube ignores DOMAIN before SIZE and clips its
                // scale to [0,1]. Non-default domains are not silently reused
                // as an HDR/ICC/color-management transform.
                guard values.allSatisfy({$0 == (isMin ? 0 : 1)}),
                      (isMin ? !minSeen : !maxSeen) else { throw VideoAssetError.invalidCube }
                if isMin {minSeen=true} else {maxSeen=true}; continue
            }
            guard let n=size, words.count==3, rows < n*n*n else { throw VideoAssetError.invalidCube }
            _ = try triple(words); started=true; rows += 1
        }
        guard let n=size, rows==n*n*n else { throw VideoAssetError.invalidCube }
    }
    private static func triple(_ words: [String]) throws -> [Float] {
        try words.map {
            guard $0.utf8.count<=64, let number=Float($0), number.isFinite else { throw VideoAssetError.invalidCube }
            return number
        }
    }
}

/// Two FFmpeg parser layers only. This is not shell or mpv filter-list quoting.
/// Callers pass this graph as typed lavfi params, not inside "lavfi=[...]".
public enum VideoAssetGraph {
    public static func lut3d(path: String) throws -> String {
        guard path.hasPrefix("/"), path.utf8.count<=4096,
              !path.unicodeScalars.contains(where:{$0.value<32 || $0.value==127}) else { throw VideoAssetError.invalidSource }
        func escape(_ text: String, special: Set<Character>) -> String {
            text.reduce(into:"") { result,c in if special.contains(c) {result.append("\\")}; result.append(c) }
        }
        let option=escape(path,special:Set("\\': \t"))
        let graph=escape(option,special:Set("\\'[],;"))
        return "lut3d=file=" + graph + ":interp=tetrahedral"
    }
}

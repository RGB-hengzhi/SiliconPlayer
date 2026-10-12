import Foundation
import Darwin
import CryptoKit

/// Companion helpers leave the original helper pair/runtime manifest intact.
/// A false candidate manifest can be used only in an explicit private suite;
/// ordinary user activation requires an exact post-run nine-contract receipt.
enum LiveASRLinearToolsResolver {
    static let providerSourceSHA256 = "f64a509cea76885f4e86bd9515dc4182ee2b9eb6fd842ab941bbb4ebd650430e"
    static let serviceSourceSHA256 = "dffd5ea6a9232b35a434f667b316e325d4bb723e3013199ea535bef8cb0f7f6e"
    static let contractIDs: Set<String> = ["linear-native-actual-prime-ready-before-core-align",
        "linear-native-three-natural-windows", "linear-native-joint-future-budget",
        "linear-native-paused-start-resume", "linear-native-seek-before-first-and-active",
        "linear-native-stop-reload-quit", "linear-native-final-cue-and-external-short-eof",
        "linear-native-budgeted-logs-and-real-credit-negative", "linear-native-two-hour-then-three-hour"]
    struct Row: Codable, Sendable { let path: String; let bytes: Int64; let sha256: String }
    struct Manifest: Decodable {
        let schema: Int
        let protocolName: String
        let providerSourceSHA256: String
        let serviceSourceSHA256: String
        let originalRuntimeSHA256: String
        let helpers: [Row]
        let verified: Bool
        let evidence: Row?
    }
    struct Evidence: Decodable {
        let schema: Int
        let status: String
        let providerSourceSHA256: String
        let serviceSourceSHA256: String
        let helperHashes: [String: String]
        let inputsUnchanged: Bool
        let driverNaturalExitCode: Int
        let forcedCleanup: Bool
        let contracts: [Contract]
        struct Contract: Decodable { let id: String; let passed: Bool; let rawReportSHA256: String }
    }
    static func resolve(bundleURL: URL = Bundle.main.bundleURL, privateCandidate: Bool = false) async throws -> LiveASRToolsConfiguration {
        // Genuine resolver still verifies original full signed closure/model4
        // and its unchanged25+Range2 metadata. It never treats a file name as ABI.
        let original = try await LiveASRToolsResolver.resolve(bundleURL: bundleURL)
        let resources = bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        let task = Task.detached(priority: .utility) {
            try candidate(original: original, resources: resources, privateCandidate: privateCandidate)
        }
        return try await withTaskCancellationHandler(operation:{try await task.value},onCancel:{task.cancel()})
    }
    private static func candidate(original: LiveASRToolsConfiguration, resources: URL, privateCandidate: Bool) throws -> LiveASRToolsConfiguration {
        let folder = resources.appendingPathComponent("LiveASRLinear",isDirectory:true)
        let raw = try data(folder,"runtime-manifest.json",maximum:2*1048576)
        let manifest = try JSONDecoder().decode(Manifest.self,from:raw)
        guard manifest.schema==1,manifest.protocolName=="SPCM1-persistent-window-credit-v1",
              manifest.providerSourceSHA256==providerSourceSHA256,manifest.serviceSourceSHA256==serviceSourceSHA256,
              manifest.originalRuntimeSHA256==digest(try data(original.runtimeManifestURL.deletingLastPathComponent(),original.runtimeManifestURL.lastPathComponent,maximum:2*1048576)),
              manifest.helpers.count==2,Set(manifest.helpers.map(\.path))==Set(["media-pcm-pts-linear","online-asr-service-linear"]) else{
            throw LiveASRFailure("持续解码工具与原包闭包不匹配")
        }
        var helpers:[String:URL]=[:],hashes:[String:String]=[:]
        for row in manifest.helpers {
            let bytes=try verified(folder,row,maximum:32*1048576)
            guard bytes.count>=32,Array(bytes.prefix(4))==[207,250,237,254] else{throw LiveASRFailure("持续工具不是thin Mach-O")}
            let cpu=bytes[4..<8].enumerated().reduce(UInt32(0)){$0|(UInt32($1.element)<<UInt32($1.offset*8))}
            guard cpu==0x0100000c else{throw LiveASRFailure("持续工具不是arm64")}
            let url=folder.appendingPathComponent(row.path);var info=stat()
            guard lstat(url.path,&info)==0,info.st_mode & mode_t(0o111) != 0 else{throw LiveASRFailure("持续工具不可执行")}
            helpers[row.path]=url;hashes[row.path]=digest(bytes)
        }
        if manifest.verified {
            guard let row=manifest.evidence,row.path=="native-contract-evidence.json" else{throw LiveASRFailure("持续解码实际接受证据缺失")}
            let evidence=try JSONDecoder().decode(Evidence.self,from:verified(folder,row,maximum:4*1048576))
            guard evidence.schema==1,evidence.status=="passed-actual-native-actor-contracts",
                  evidence.providerSourceSHA256==providerSourceSHA256,evidence.serviceSourceSHA256==serviceSourceSHA256,
                  evidence.helperHashes==hashes,evidence.inputsUnchanged,evidence.driverNaturalExitCode==0,!evidence.forcedCleanup,
                  evidence.contracts.count==contractIDs.count,Set(evidence.contracts.map(\.id))==contractIDs,
                  evidence.contracts.allSatisfy({$0.passed && $0.rawReportSHA256.range(of:"^[0-9a-f]{64}$",options:.regularExpression) != nil}) else{
                throw LiveASRFailure("持续解码九项实际契约未完整接受")
            }
        } else {
            guard privateCandidate,manifest.evidence==nil else{throw LiveASRFailure("持续解码仍为未验收候选，默认模式保持原分段后端")}
        }
        guard let pcm=helpers["media-pcm-pts-linear"],let service=helpers["online-asr-service-linear"] else{throw LiveASRFailure("持续工具缺失")}
        return LiveASRToolsConfiguration(pcmDecoderURL:pcm,recognizerServiceURL:service,ffprobeURL:original.ffprobeURL,
            modelDirectory:original.modelDirectory,encoderModelURL:original.encoderModelURL,decoderModelURL:original.decoderModelURL,
            joinerModelURL:original.joinerModelURL,tokensURL:original.tokensURL,runtimeManifestURL:folder.appendingPathComponent("runtime-manifest.json"),
            modelManifestURL:original.modelManifestURL,profileID:original.profileID,pcmHelperSourceSHA256:providerSourceSHA256,
            supportsGracefulInputLimit:false,supportsFirstBlockHold:false,supportsExactSourceRange:false)
    }
    private static func verified(_ root:URL,_ row:Row,maximum:Int)throws->Data {
        let bytes=try data(root,row.path,maximum:maximum)
        guard row.bytes==Int64(bytes.count),digest(bytes)==row.sha256 else{throw LiveASRFailure("持续工具/证据完整字节校验失败")};return bytes
    }
    private static func data(_ root:URL,_ relative:String,maximum:Int)throws->Data {
        guard root.isFileURL,!relative.isEmpty,!relative.hasPrefix("/"),!relative.contains("\0") else{throw LiveASRFailure("持续工具路径无效")}
        let parts=relative.split(separator:"/",omittingEmptySubsequences:false)
        guard parts.allSatisfy({!$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix("._")}) else{throw LiveASRFailure("持续工具路径越界")}
        var cursor=root;var info=stat()
        // Refuse every linked ancestor of the companion directory.
        var ancestor=URL(fileURLWithPath:"/",isDirectory:true)
        for part in root.pathComponents.dropFirst(){
            ancestor.appendPathComponent(part)
            guard !part.hasPrefix("._"),lstat(ancestor.path,&info)==0,
                  info.st_mode & mode_t(S_IFMT)==mode_t(S_IFDIR) else{
                throw LiveASRFailure("持续工具祖先不是物理目录")
            }
        }
        guard lstat(root.path,&info)==0,info.st_mode & mode_t(S_IFMT)==mode_t(S_IFDIR) else{throw LiveASRFailure("持续工具目录缺失或链接")}
        for (index,part) in parts.enumerated(){
            cursor.appendPathComponent(String(part));guard lstat(cursor.path,&info)==0,info.st_mode & mode_t(S_IFMT) != mode_t(S_IFLNK) else{throw LiveASRFailure("持续工具包含链接")}
            if index+1<parts.count{guard info.st_mode & mode_t(S_IFMT)==mode_t(S_IFDIR) else{throw LiveASRFailure("持续工具祖先不是目录")}}
        }
        let fd=Darwin.open(cursor.path,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);guard fd>=0 else{throw LiveASRFailure("持续工具不可读")};defer{Darwin.close(fd)}
        var before=stat(),after=stat();guard fstat(fd,&before)==0,before.st_mode & mode_t(S_IFMT)==mode_t(S_IFREG),before.st_size>0,before.st_size<=maximum else{throw LiveASRFailure("持续工具文件超界")}
        var result=Data();var buffer=[UInt8](repeating:0,count:65536)
        while true{try Task.checkCancellation();let n=read(fd,&buffer,buffer.count);if n<0 && errno==EINTR{continue};guard n>=0 else{throw LiveASRFailure("持续工具读取失败")};if n==0{break};result.append(contentsOf:buffer.prefix(n));guard result.count<=maximum else{throw LiveASRFailure("持续工具读取超界")}}
        guard fstat(fd,&after)==0,before.st_dev==after.st_dev,before.st_ino==after.st_ino,before.st_size==after.st_size,
              before.st_mtimespec.tv_sec==after.st_mtimespec.tv_sec,before.st_mtimespec.tv_nsec==after.st_mtimespec.tv_nsec,
              Int64(result.count)==before.st_size else{throw LiveASRFailure("持续工具读中身份变化")};return result
    }
    private static func digest(_ bytes:Data)->String{SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined()}
}

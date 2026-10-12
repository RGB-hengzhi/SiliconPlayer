import Foundation

public enum UserVideoFilterError: LocalizedError, Equatable {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

public struct UserVideoFilterParameter: Identifiable, Equatable {
    public struct Choice: Equatable {
        public let value: Double
        public let title: String
        public init(_ value: Double, _ title: String) { self.value = value; self.title = title }
    }
    public let id: String
    public let title: String
    public let range: ClosedRange<Double>
    public let defaultValue: Double
    public let step: Double
    public let choices: [Choice]
    public init(_ id: String, _ title: String, _ range: ClosedRange<Double>, _ value: Double,
                step: Double = 0.01, choices: [Choice] = []) {
        self.id = id; self.title = title; self.range = range; defaultValue = value
        self.step = step; self.choices = choices
    }
}

/// Deliberately excludes arbitrary graphs, expressions, file paths and scripts.
/// Parameters below are a bounded subset of FFmpeg's filters through mpv lavfi.
public enum UserVideoFilterKind: String, Codable, CaseIterable, Identifiable {
    case horizontalFlip, verticalFlip, transpose, grayscale, color, unsharp, denoise, blur, crop, downscale
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .horizontalFlip: return "水平镜像"
        case .verticalFlip: return "垂直翻转"
        case .transpose: return "旋转 90°"
        case .grayscale: return "灰度"
        case .color: return "亮度、对比与饱和度"
        case .unsharp: return "锐化 / 柔化"
        case .denoise: return "时空降噪 HQDN3D"
        case .blur: return "高斯模糊"
        case .crop: return "比例裁剪"
        case .downscale: return "缩小画面"
        }
    }
    public var parameters: [UserVideoFilterParameter] {
        switch self {
        case .horizontalFlip, .verticalFlip, .grayscale: return []
        case .transpose:
            return [.init("direction", "方向", 1...2, 1, step: 1,
                          choices: [.init(1, "顺时针"), .init(2, "逆时针")])]
        case .color:
            return [.init("brightness", "亮度", -0.5...0.5, 0), .init("contrast", "对比度", 0.5...2, 1),
                    .init("saturation", "饱和度", 0...3, 1), .init("gamma", "Gamma", 0.5...3, 1)]
        case .unsharp: return [.init("amount", "强度（负数柔化）", -1.5...1.5, 0.5)]
        case .denoise:
            return [.init("lumaSpatial", "亮度空间强度", 0...10, 4, step: 0.1),
                    .init("chromaSpatial", "色度空间强度", 0...10, 3, step: 0.1),
                    .init("lumaTemporal", "亮度时间强度", 0...15, 6, step: 0.1),
                    .init("chromaTemporal", "色度时间强度", 0...15, 4.5, step: 0.1)]
        case .blur: return [.init("sigma", "模糊半径", 0...5, 1, step: 0.1)]
        case .crop:
            return [.init("width", "保留宽度", 0.1...1, 0.9), .init("height", "保留高度", 0.1...1, 0.9),
                    .init("x", "横向位置", 0...1, 0.5), .init("y", "纵向位置", 0...1, 0.5)]
        case .downscale:
            return [.init("factor", "尺寸比例", 0.25...1, 0.5),
                    .init("algorithm", "算法", 0...2, 0, step: 1,
                          choices: [.init(0, "双线性"), .init(1, "双三次"), .init(2, "Lanczos")])]
        }
    }
}

public struct UserVideoFilter: Identifiable, Codable, Equatable {
    public var id: UUID
    public var kind: UserVideoFilterKind
    public var enabled: Bool
    public var values: [String: Double]
    public init(kind: UserVideoFilterKind, id: UUID = UUID(), enabled: Bool = true) {
        self.id = id; self.kind = kind; self.enabled = enabled
        values = Dictionary(uniqueKeysWithValues: kind.parameters.map { ($0.id, $0.defaultValue) })
    }
    public func validated() throws -> Self {
        let parameters = kind.parameters
        guard Set(values.keys) == Set(parameters.map(\.id)) else {
            throw UserVideoFilterError.invalid("\(kind.title)：参数缺失或包含未开放的参数")
        }
        for parameter in parameters {
            guard let value = values[parameter.id], value.isFinite, parameter.range.contains(value),
                  parameter.choices.isEmpty || parameter.choices.contains(where: { $0.value == value }) else {
                throw UserVideoFilterError.invalid("\(kind.title)：\(parameter.title)超出允许范围")
            }
        }
        return self
    }
    /// All syntax is generated from constants and validated numbers. User text
    /// never enters the graph, and this value must be passed to the libmpv API.
    public func lavfiFragment() throws -> String {
        _ = try validated()
        func number(_ key: String) -> String {
            String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), values[key]!)
        }
        switch kind {
        case .horizontalFlip: return "hflip"
        case .verticalFlip: return "vflip"
        case .transpose: return values["direction"] == 1 ? "transpose=dir=clock" : "transpose=dir=cclock"
        case .grayscale: return "hue=s=0"
        case .color:
            return "eq=brightness=\(number("brightness")):contrast=\(number("contrast")):saturation=\(number("saturation")):gamma=\(number("gamma"))"
        case .unsharp:
            return "unsharp=luma_msize_x=5:luma_msize_y=5:luma_amount=\(number("amount")):chroma_amount=0"
        case .denoise:
            return "hqdn3d=luma_spatial=\(number("lumaSpatial")):chroma_spatial=\(number("chromaSpatial")):luma_tmp=\(number("lumaTemporal")):chroma_tmp=\(number("chromaTemporal"))"
        case .blur: return "gblur=sigma=\(number("sigma")):steps=1"
        case .crop:
            // Commas belong only to generated max() expressions, and must be
            // escaped for libavfilter. At least 2 pixels avoids zero-size crops.
            return "crop=w=max(2\\,trunc(iw*\(number("width"))/2)*2):h=max(2\\,trunc(ih*\(number("height"))/2)*2):x=trunc((iw-ow)*\(number("x"))/2)*2:y=trunc((ih-oh)*\(number("y"))/2)*2"
        case .downscale:
            let algorithm = ["bilinear", "bicubic", "lanczos"][Int(values["algorithm"]!)]
            return "scale=w=max(2\\,trunc(iw*\(number("factor"))/2)*2):h=max(2\\,trunc(ih*\(number("factor"))/2)*2):flags=\(algorithm)"
        }
    }
    private enum CodingKeys: String, CodingKey { case id, kind, enabled, values }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(UserVideoFilterKind.self, forKey: .kind)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        values = try container.decode([String: Double].self, forKey: .values)
        _ = try validated()
    }
}

public struct UserVideoFilterChain: Codable, Equatable {
    public static let maximumCount = 12
    public var version: Int
    public var filters: [UserVideoFilter]
    public init(filters: [UserVideoFilter] = [], version: Int = 1) { self.filters = filters; self.version = version }
    public func validated() throws -> Self {
        guard version == 1 else { throw UserVideoFilterError.invalid("不支持的视频滤镜资料版本") }
        guard filters.count <= Self.maximumCount else { throw UserVideoFilterError.invalid("视频滤镜最多允许 12 项") }
        guard Set(filters.map(\.id)).count == filters.count else { throw UserVideoFilterError.invalid("视频滤镜标识重复") }
        for filter in filters { _ = try filter.validated() }
        return self
    }
    public func lavfiFragments() throws -> [String] {
        _ = try validated()
        return try filters.filter(\.enabled).map { try $0.lavfiFragment() }
    }
    public mutating func move(id: UUID, to index: Int) throws {
        guard let original = filters.firstIndex(where: { $0.id == id }), filters.indices.contains(index) else {
            throw UserVideoFilterError.invalid("滤镜排序位置无效")
        }
        let entry = filters.remove(at: original)
        filters.insert(entry, at: index)
    }
    private enum CodingKeys: String, CodingKey { case version, filters }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        filters = try container.decode([UserVideoFilter].self, forKey: .filters)
        _ = try validated()
    }
}

/// Invalid documents are rejected as a whole. Reading never overwrites a bad
/// file; saving validates before writing so rejected edits preserve old bytes.
public final class UserVideoFilterStore {
    public static let maximumBytes = 128 * 1024
    public let fileURL: URL
    public init(fileURL: URL) { self.fileURL = fileURL }
    public func load() throws -> UserVideoFilterChain {
        guard fileURL.isFileURL else { throw UserVideoFilterError.invalid("滤镜设置必须保存在本地文件") }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return UserVideoFilterChain() }
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard size <= Self.maximumBytes else { throw UserVideoFilterError.invalid("滤镜设置文件过大") }
        let data = try Data(contentsOf: fileURL)
        guard data.count <= Self.maximumBytes else { throw UserVideoFilterError.invalid("滤镜设置文件过大") }
        return try JSONDecoder().decode(UserVideoFilterChain.self, from: data).validated()
    }
    public func save(_ chain: UserVideoFilterChain) throws {
        guard fileURL.isFileURL else { throw UserVideoFilterError.invalid("滤镜设置必须保存在本地文件") }
        _ = try chain.validated()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(chain)
        guard data.count <= Self.maximumBytes else { throw UserVideoFilterError.invalid("滤镜设置文件过大") }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }
}

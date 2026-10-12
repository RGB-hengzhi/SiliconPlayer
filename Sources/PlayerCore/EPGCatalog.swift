import Foundation

/// Candidate parsing is transactional. The application adapter must also
/// verify its asynchronous request generation before replacing this catalog.
public struct EPGCatalog {
    public private(set) var document: XMLTVDocument?
    public init() {}
    public mutating func replace(data: Data, sourceURL: URL? = nil, limits: XMLTVLimits = .init(),
                                isCancelled: @escaping () -> Bool = { false }) throws {
        let candidate = try XMLTVDocument.parse(data, sourceURL: sourceURL, limits: limits, isCancelled: isCancelled)
        if isCancelled() { throw XMLTVError.cancelled }
        document = candidate
    }
}

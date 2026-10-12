import Foundation
#if USER_VIDEO_FILTER_STANDALONE
import PlayerCore
#elseif !PLAYER_CORE_STANDALONE
import XCTest
@testable import PlayerCore
#endif

final class UserVideoFiltersTests: XCTestCase {
    private func rejected(_ body: () throws -> Void) {
        var failed = false
        do { try body() } catch { failed = true }
        XCTAssertTrue(failed, "Invalid input must be rejected")
    }
    func testDefaultsAndDisabledEntriesRemainValidated() throws {
        for kind in UserVideoFilterKind.allCases {
            let entry = UserVideoFilter(kind: kind)
            XCTAssertEqual(try entry.validated(), entry)
            let fragment = try entry.lavfiFragment()
            XCTAssertFalse(fragment.isEmpty)
            var disabled = entry; disabled.enabled = false
            XCTAssertEqual(try UserVideoFilterChain(filters: [disabled]).lavfiFragments(), [])
            if let parameter = kind.parameters.first {
                disabled.values[parameter.id] = .nan
                rejected { _ = try UserVideoFilterChain(filters: [disabled]).lavfiFragments() }
            }
        }
    }
    func testRangesNonFiniteAndUnknownParametersAreRejected() throws {
        for kind in UserVideoFilterKind.allCases {
            for parameter in kind.parameters {
                for valid in [parameter.range.lowerBound, parameter.range.upperBound] {
                    var entry = UserVideoFilter(kind: kind); entry.values[parameter.id] = valid
                    XCTAssertEqual(try entry.validated(), entry)
                }
                for invalid in [Double.nan, .infinity, -.infinity, parameter.range.lowerBound - 1, parameter.range.upperBound + 1] {
                    var entry = UserVideoFilter(kind: kind); entry.values[parameter.id] = invalid
                    rejected { _ = try entry.lavfiFragment() }
                }
                var missing = UserVideoFilter(kind: kind); missing.values.removeValue(forKey: parameter.id)
                rejected { _ = try missing.validated() }
                if !parameter.choices.isEmpty {
                    var fractional = UserVideoFilter(kind: kind); fractional.values[parameter.id] = parameter.range.lowerBound + 0.5
                    rejected { _ = try fractional.validated() }
                }
            }
            var injected = UserVideoFilter(kind: kind)
            injected.values["movie=file=/tmp/x,split"] = 1
            rejected { _ = try injected.lavfiFragment() }
        }
    }
    func testChainIdentityVersionAndLengthLimits() throws {
        let entry = UserVideoFilter(kind: .horizontalFlip)
        rejected { _ = try UserVideoFilterChain(filters: [entry, entry]).validated() }
        rejected { _ = try UserVideoFilterChain(version: 2).validated() }
        let maximum = (0..<UserVideoFilterChain.maximumCount).map { _ in UserVideoFilter(kind: .horizontalFlip) }
        XCTAssertEqual(try UserVideoFilterChain(filters: maximum).validated().filters.count, maximum.count)
        rejected { _ = try UserVideoFilterChain(filters: maximum + [entry]).validated() }
    }
    func testOrderMovesAndDisabledRowsPreserveIdentity() throws {
        let crop = UserVideoFilter(kind: .crop)
        var rotate = UserVideoFilter(kind: .transpose); rotate.enabled = false
        let blur = UserVideoFilter(kind: .blur)
        var chain = UserVideoFilterChain(filters: [crop, rotate, blur])
        try chain.move(id: blur.id, to: 0)
        XCTAssertEqual(chain.filters.map(\.id), [blur.id, crop.id, rotate.id])
        XCTAssertEqual(try chain.lavfiFragments(), [try blur.lavfiFragment(), try crop.lavfiFragment()])
        let snapshot = chain
        rejected { try chain.move(id: UUID(), to: 0) }
        rejected { try chain.move(id: blur.id, to: -1) }
        rejected { try chain.move(id: blur.id, to: chain.filters.count) }
        XCTAssertEqual(chain, snapshot)
    }
    func testGeneratedGraphContainsOnlyBoundedSyntax() throws {
        var color = UserVideoFilter(kind: .color); color.values["brightness"] = -0.125
        let graph = try color.lavfiFragment()
        XCTAssertTrue(graph.contains("brightness=-0.125000"))
        XCTAssertFalse(graph.contains("nan")); XCTAssertFalse(graph.contains("inf"))
        for kind in UserVideoFilterKind.allCases {
            let fragment = try UserVideoFilter(kind: kind).lavfiFragment()
            XCTAssertFalse(fragment.contains(";")); XCTAssertFalse(fragment.contains("[")); XCTAssertFalse(fragment.contains("]"))
            XCTAssertFalse(fragment.contains("\n")); XCTAssertFalse(fragment.contains("/" + "tmp"))
        }
        for kind in [UserVideoFilterKind.crop, .downscale] {
            let fragment = try UserVideoFilter(kind: kind).lavfiFragment()
            XCTAssertTrue(fragment.contains("max(2\\,trunc("))
        }
    }
    func testJSONAndAtomicStorePreserveOrderValuesAndOldBytes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UserVideoFilterStore(fileURL: directory.appendingPathComponent("中文 滤镜.json"))
        XCTAssertEqual(try store.load(), UserVideoFilterChain())
        var color = UserVideoFilter(kind: .color); color.values["saturation"] = 1.7
        let disabled = UserVideoFilter(kind: .blur, enabled: false)
        let chain = UserVideoFilterChain(filters: [color, disabled, UserVideoFilter(kind: .crop)])
        try store.save(chain)
        XCTAssertEqual(try store.load(), chain)
        let previous = try Data(contentsOf: store.fileURL)
        var invalid = chain; invalid.filters[0].values["gamma"] = .infinity
        rejected { try store.save(invalid) }
        XCTAssertEqual(try Data(contentsOf: store.fileURL), previous)
        XCTAssertEqual(try JSONDecoder().decode(UserVideoFilterChain.self, from: JSONEncoder().encode(chain)), chain)
        var unknown = try JSONSerialization.jsonObject(with: previous) as! [String: Any]
        var rows = unknown["filters"] as! [[String: Any]]; rows[0]["kind"] = "movie"; unknown["filters"] = rows
        rejected { _ = try JSONDecoder().decode(UserVideoFilterChain.self, from: JSONSerialization.data(withJSONObject: unknown)) }
    }
    func testCorruptOversizeAndWriteErrorsRemainVisibleWithoutReplacingFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("filters.json")
        let corrupt = Data("{broken".utf8); try corrupt.write(to: target)
        let store = UserVideoFilterStore(fileURL: target)
        rejected { _ = try store.load() }
        XCTAssertEqual(try Data(contentsOf: target), corrupt)
        let oversized = Data(repeating: 32, count: UserVideoFilterStore.maximumBytes + 1)
        try oversized.write(to: target); rejected { _ = try store.load() }
        XCTAssertEqual(try Data(contentsOf: target), oversized)
        let blockingFile = directory.appendingPathComponent("blocked"); try Data("keep".utf8).write(to: blockingFile)
        rejected { try UserVideoFilterStore(fileURL: blockingFile.appendingPathComponent("filters.json")).save(UserVideoFilterChain()) }
        XCTAssertEqual(try String(contentsOf: blockingFile), "keep")
        rejected { _ = try UserVideoFilterStore(fileURL: URL(string: "https://example.com/filters.json")!).load() }
    }
}

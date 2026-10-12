// A full Xcode installation supplies XCTest. For Command Line Tools-only Macs,
// compile the core and test sources together with -D PLAYER_CORE_STANDALONE.
#if PLAYER_CORE_STANDALONE
import Foundation

class XCTestCase {
    func setUpWithError() throws {}
    func tearDownWithError() throws {}
}

func XCTAssertEqual<T: Equatable>(
    _ left: @autoclosure () throws -> T,
    _ right: @autoclosure () throws -> T,
    _ message: String = "",
    file: StaticString = #file,
    line: UInt = #line
) {
    do {
        let actual = try left()
        let expected = try right()
        precondition(actual == expected, "Expected \(expected), received \(actual). \(message)", file: file, line: line)
    } catch {
        preconditionFailure("Unexpected error: \(error)", file: file, line: line)
    }
}

func XCTAssertLessThan<T: Comparable>(
    _ left: @autoclosure () -> T,
    _ right: @autoclosure () -> T,
    _ message: String = "",
    file: StaticString = #file,
    line: UInt = #line
) {
    precondition(left() < right(), message, file: file, line: line)
}

func XCTAssertTrue(_ value: @autoclosure () -> Bool, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    precondition(value(), message, file: file, line: line)
}

func XCTAssertFalse(_ value: @autoclosure () -> Bool, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    precondition(!value(), message, file: file, line: line)
}

func XCTAssertNil<T>(_ value: @autoclosure () -> T?, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    precondition(value() == nil, message, file: file, line: line)
}

func XCTAssertNotNil<T>(_ value: @autoclosure () -> T?, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    precondition(value() != nil, message, file: file, line: line)
}

func XCTUnwrap<T>(_ value: T?) throws -> T {
    guard let value else { throw NSError(domain: "PlayerCoreTests", code: 1) }
    return value
}

@main
struct StandaloneRunner {
    static func main() throws {
        let cases: [(String, (PlayerCoreTests) throws -> Void)] = [
            ("media item path and JSON", { try $0.testMediaItemPreservesChineseAndSpacesThroughCoding() }),
            ("playlist normalization and deduplication", { $0.testPlaylistNormalizesAndDeduplicatesWithoutChangingSelection() }),
            ("remove current playlist item", { $0.testPlaylistRemovesCurrentSuccessorThenPredecessorThenClears() }),
            ("remove before selected item", { $0.testRemovingBeforeSelectionKeepsSameItemSelected() }),
            ("playlist navigation boundaries", { $0.testPlaylistBoundariesAndWrapping() }),
            ("single-item navigation", { $0.testSingleItemPlaylistDoesNotAdvanceWithoutWrap() }),
            ("recursive scan with hidden files and symlinks", { try $0.testDirectoryExpansionSortsRecursivelyAndSkipsHiddenFilesAndSymlinks() }),
            ("direct files, streams, and subtitles", { try $0.testExplicitFilesAndStreamsAreKeptAndSubtitlesExcluded() }),
            ("history persistence and completed entries", { try $0.testHistoryRoundTripNormalizesChinesePathsAndStoresCompletedEntries() }),
            ("history resume eligibility", { $0.testHistoryResumeEligibilityAndInvalidUpdates() }),
            ("history errors and recovery", { try $0.testHistoryReportsReadAndWriteFailures() }),
            ("time formatting", { $0.testTimeTextHandlesInvalidValuesAndHours() })
        ]
        for (name, body) in cases {
            let test = PlayerCoreTests()
            try test.setUpWithError()
            do {
                try body(test)
                try test.tearDownWithError()
                print("PASS \(name)")
            } catch {
                try? test.tearDownWithError()
                throw error
            }
        }
        let expanded = ExpandedCoreTests()
        let additional: [(String, () throws -> Void)] = [
            ("settings migration and invalid values", expanded.testSettingsMigrationAndInvalidValues),
            ("library persistence and invalid bookmarks", expanded.testLibraryPersistenceAndInvalidBookmarks),
            ("playlist documents and HLS detection", expanded.testPlaylistDocumentRelativePathsAndHLS),
            ("subtitle round trip and atomic timing", expanded.testSubtitleRoundTripAndAtomicTiming),
            ("VTT, ASS and subtitle overlaps", expanded.testVTTASSAndOverlap),
            ("reorder preserving selected media", expanded.testReorderPreservesPlayingItem),
            ("channel metadata and escaped Chinese paths", expanded.testChannelMetadataAndPercentEncodedPaths)
        ]
        for (name, body) in additional { try body(); print("PASS \(name)") }
        let editing = LibraryEditingTests()
        let libraryEdits: [(String, () throws -> Void)] = [
            ("bookmark editing persistence and stable identity", editing.testBookmarkEditingPersistsWithoutChangingIdentity),
            ("invalid bookmark edit leaves memory and disk unchanged", editing.testInvalidBookmarkEditsLeaveMemoryAndDiskUnchanged),
            ("saved playlist rename preserves media", editing.testSavedPlaylistRenamingPreservesMediaAndRejectsInvalidNames),
            ("library edit write failure rollback and recovery", editing.testEditingWriteFailureRollsBackAndCanRecover),
            ("PLS export Chinese URL and metadata round trip", editing.testPLSExportRoundTripsChineseURLsAndMetadata),
            ("unsafe PLS export preserves existing destination", editing.testUnsafePLSExportDoesNotReplaceExistingFile)
        ]
        for (name, body) in libraryEdits { try body(); print("PASS \(name)") }
        let presets = EqualizerPresetTests()
        let equalizer: [(String, () throws -> Void)] = [
            ("EQ presets valid unique ten-band configurations", presets.testAllPresetsHaveUniqueValidTenBandCurves),
            ("EQ preset matching and custom curves", presets.testMatchingRecognizesPresetsAndRejectsCustomCurves),
            ("EQ malformed and nonfinite configurations", presets.testMatchingRejectsMalformedAndNonFiniteCurves),
            ("EQ settings sanitation preserves unrelated values", presets.testSanitizingPreservesEveryValidPresetAndUnrelatedSettings),
            ("EQ enabled/disabled JSON persistence", presets.testJSONRoundTripPreservesEnabledPresetAndUnrelatedSettings)
        ]
        for (name, body) in equalizer { try body(); print("PASS \(name)") }
        let batch = PlaylistBatchTests()
        let queueBatch: [(String, () throws -> Void)] = [
            ("batch remove stable current identity", batch.testBatchRemoveKeepsCurrentIdentityAndDoesNotUseShiftedIndices),
            ("batch removal 2048 successor and predecessor combinations", batch.testBatchRemovalSuccessorsPredecessorsAndEmptyQueueExhaustively),
            ("noncontiguous drag keeps order and playing identity", batch.testNoncontiguousMoveRetainsRelativeOrderAndCurrentIdentity),
            ("drag insertion boundaries count every removed predecessor", batch.testOriginalInsertionBoundaryCorrectsAllRemovedPrecedingRows),
            ("filtered drop and removal keep hidden rows", batch.testFilteredDropAndRemovalUseIDsAndKeepHiddenRows),
            ("invalid and self drops leave queue unchanged", batch.testRejectedMovesAndSelfDropAreAtomic),
            ("selected anchor and tail drop consolidate noncontiguous selection", batch.testSelectedAnchorAndTailDropConsolidateNoncontiguousSelection),
            ("private drag payload sessions and stale IDs", batch.testDragPayloadRoundTripAndStrictSessionValidation),
            ("malformed payload and ten thousand item boundary", batch.testMalformedEmptyOversizedAndExcessivePayloadsAreRejected)
        ]
        for (name, body) in queueBatch { try body(); print("PASS \(name)") }
        print("\(cases.count + additional.count + libraryEdits.count + equalizer.count + queueBatch.count) core tests passed")
    }
}
#endif

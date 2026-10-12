import Foundation
#if !PLAYER_CORE_STANDALONE
import XCTest
@testable import PlayerCore
#endif

final class SystemPiPLifecycleTests: XCTestCase {
    func testDuplicateEnterAndDuplicateCloseAreRejected() {
        var m = SystemPiPLifecycle(); let first = m.beginEnter()!
        XCTAssertNil(m.beginEnter()); XCTAssertTrue(m.observeStart(first))
        XCTAssertFalse(m.observeStart(first)); XCTAssertTrue(m.close(first)); XCTAssertFalse(m.close(first))
    }
    func testExitDuringStartupRejectsLateStartWithoutLosingCloseTicket() {
        var m = SystemPiPLifecycle(); let first = m.beginEnter()!
        XCTAssertTrue(m.beginExit()); XCTAssertFalse(m.observeStart(first))
        XCTAssertEqual(m.generation, first); XCTAssertEqual(m.state, .exiting)
        XCTAssertTrue(m.close(first)); XCTAssertEqual(m.state, .idle)
    }
    func testOldCloseCannotRestoreNewPresentation() {
        var m = SystemPiPLifecycle(); let first = m.beginEnter()!
        XCTAssertTrue(m.close(first)); let second = m.beginEnter()!
        XCTAssertTrue(first != second); XCTAssertFalse(m.close(first))
        XCTAssertEqual(m.generation, second); XCTAssertEqual(m.state, .entering)
    }
    func testOrdinaryExitPermitsAnotherEntryButTerminalShutdownDoesNot() {
        var m = SystemPiPLifecycle(); let first = m.beginEnter()!
        _ = m.beginExit(); XCTAssertTrue(m.close(first)); XCTAssertNotNil(m.beginEnter())
        let second = m.generation!; m.beginShutdown(); XCTAssertFalse(m.observeStart(second))
        XCTAssertTrue(m.close(second)); XCTAssertNil(m.beginEnter()); XCTAssertFalse(m.resetRegistration())
    }
    func testForcedTeardownInvalidatesCallbacksAndNewRegistrationCanRecover() {
        var m = SystemPiPLifecycle(); let first = m.beginEnter()!
        m.cancelForTeardown(); XCTAssertFalse(m.close(first)); XCTAssertFalse(m.observeStart(first))
        m.disable(); XCTAssertNil(m.beginEnter()); XCTAssertTrue(m.resetRegistration())
        let second = m.beginEnter()!; XCTAssertLessThan(first, second)
    }
    func testCancelledQuitPreservesGenerationAndRequiresSafeClose() {
        var m = SystemPiPLifecycle(); let first = m.beginEnter()!
        m.beginShutdown(); XCTAssertFalse(m.cancelShutdownIfSafe())
        XCTAssertTrue(m.close(first)); XCTAssertTrue(m.cancelShutdownIfSafe())
        let second = m.beginEnter()!; XCTAssertLessThan(first, second)
        XCTAssertFalse(m.close(first)); XCTAssertEqual(m.generation, second)
    }
}

import XCTest
@testable import TouchBarBuddy

/// 状态机归约规则单元测试：覆盖各状态优先级与边界情况。
final class StateMachineTests: XCTestCase {

    private func makeTask(_ id: String,
                          _ status: TaskStatus,
                          unread: Bool = false) -> TaskInfo {
        TaskInfo(id: id, title: "T-\(id)", status: status, unread: unread)
    }

    func testEmptyIsIdle() {
        XCTAssertEqual(TouchBarStateMachine.reduce([]), .idle)
    }

    func testPendingHasHighestPriorityOverWorkingAndUnread() {
        let sessions = [
            makeTask("a", .working),
            makeTask("b", .pending),
            makeTask("c", .completed, unread: true)
        ]
        let state = TouchBarStateMachine.reduce(sessions)
        guard case .pending(let tasks) = state else {
            return XCTFail("应归约为 pending")
        }
        XCTAssertEqual(tasks.map { $0.id }, ["b"])
    }

    func testWorkingHasPriorityOverUnread() {
        let sessions = [
            makeTask("a", .working),
            makeTask("b", .completed, unread: true)
        ]
        let state = TouchBarStateMachine.reduce(sessions)
        guard case .working(let tasks) = state else {
            return XCTFail("应归约为 working")
        }
        XCTAssertEqual(tasks.map { $0.id }, ["a"])
    }

    func testUnreadCompletedWhenNoPendingOrWorking() {
        let sessions = [
            makeTask("a", .completed, unread: true),
            makeTask("b", .completed, unread: false)
        ]
        let state = TouchBarStateMachine.reduce(sessions)
        guard case .unread(let tasks) = state else {
            return XCTFail("应归约为 unread")
        }
        XCTAssertEqual(tasks.map { $0.id }, ["a"])
    }

    func testArchivedIsIgnored() {
        let sessions = [
            makeTask("a", .archived),
            makeTask("b", .archived)
        ]
        XCTAssertEqual(TouchBarStateMachine.reduce(sessions), .idle)
    }

    func testCompletedAndReadFallsToIdle() {
        let sessions = [makeTask("a", .completed, unread: false)]
        XCTAssertEqual(TouchBarStateMachine.reduce(sessions), .idle)
    }

    func testUnknownStatusFallsToIdle() {
        let sessions = [makeTask("a", .unknown)]
        XCTAssertEqual(TouchBarStateMachine.reduce(sessions), .idle)
    }

    func testMultiplePendingCollected() {
        let sessions = [
            makeTask("a", .pending),
            makeTask("b", .pending),
            makeTask("c", .archived)
        ]
        let state = TouchBarStateMachine.reduce(sessions)
        guard case .pending(let tasks) = state else {
            return XCTFail("应归约为 pending")
        }
        XCTAssertEqual(tasks.count, 2)
        XCTAssertEqual(tasks.map { $0.id }, ["a", "b"])
    }

    func testSummaryLabelMatchesState() {
        XCTAssertEqual(TouchBarStateMachine.reduce([]).summaryLabel, "◆ 空闲")
        XCTAssertTrue(TouchBarStateMachine.reduce([]).isIdle)
        let pendingState = TouchBarStateMachine.reduce([makeTask("p", .pending)])
        XCTAssertFalse(pendingState.isIdle)
        XCTAssertEqual(pendingState.summaryLabel, "⏳ 1 待确认")
    }

    // MARK: - active 状态归入 working（2026-11 真机实测新增）

    func testActiveCountsAsWorking() {
        let state = TouchBarStateMachine.reduce([makeTask("a", .active)])
        guard case .working(let tasks) = state else {
            return XCTFail("active 应归入 working")
        }
        XCTAssertEqual(tasks.map { $0.id }, ["a"])
    }

    func testActiveAndWorkingMixedCount() {
        let sessions = [makeTask("w", .working), makeTask("a", .active)]
        let state = TouchBarStateMachine.reduce(sessions)
        guard case .working(let tasks) = state else {
            return XCTFail("working/active 应归入 working")
        }
        XCTAssertEqual(tasks.count, 2)
        XCTAssertEqual(Set(tasks.map { $0.id }), Set(["w", "a"]))
    }
}

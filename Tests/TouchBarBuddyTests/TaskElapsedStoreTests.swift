import Foundation
import XCTest
@testable import TouchBarBuddy

/// 「本次任务起点」持久化的单测。
///
/// 用户明确报过两次时间归零：第一次是有输出就重置，第二次是切到待确认态 / 重启 App 后重置。
/// 这里把「起点一旦记下就不动」钉死。
final class TaskElapsedStoreTests: XCTestCase {

    func testStartIsSticky() {
        let store = TaskElapsedStore(defaults: nil)
        let t0 = Date(timeIntervalSince1970: 1000)
        let t1 = Date(timeIntervalSince1970: 2000)
        XCTAssertEqual(store.start(for: "a", now: t0), t0)
        XCTAssertEqual(store.start(for: "a", now: t1), t0, "起点被刷新了 —— 时长会归零")
    }

    func testReadDoesNotCreate() {
        let store = TaskElapsedStore(defaults: nil)
        XCTAssertNil(store.startedDate(for: "a"))
        XCTAssertNil(store.startedDate(for: "a"), "只读不该副作用创建起点")
    }

    func testClearAllowsRestart() {
        let store = TaskElapsedStore(defaults: nil)
        let t0 = Date(timeIntervalSince1970: 1000)
        let t1 = Date(timeIntervalSince1970: 2000)
        XCTAssertEqual(store.start(for: "a", now: t0), t0)
        store.clear("a")
        XCTAssertNil(store.startedDate(for: "a"))
        XCTAssertEqual(store.start(for: "a", now: t1), t1)
    }

    /// 跨实例（等价于 App 重启）仍要拿到同一个起点。
    func testStartSurvivesNewStoreInstance() {
        let suite = "tb-elapsed-test-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return XCTFail("无法建立测试用 UserDefaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let t0 = Date(timeIntervalSince1970: 1000)
        let t1 = Date(timeIntervalSince1970: 9999)
        XCTAssertEqual(TaskElapsedStore(defaults: defaults).start(for: "a", now: t0), t0)
        XCTAssertEqual(TaskElapsedStore(defaults: defaults).start(for: "a", now: t1), t0,
                       "App 重启后起点丢了")
    }
}

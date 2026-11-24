import Foundation
import XCTest
@testable import TouchBarBuddy

/// 「任务运行时常驻」的策略单测。
///
/// 为什么这条必须钉：常驻的本质是**阻止屏幕休眠**，代价是耗电与屏幕不熄。
/// 策略一旦写错（比如漏判开关、或没有任务也常亮），用户会遇到
/// 「电脑莫名其妙一直亮着」这种很难归因的问题 —— 而它只是两个布尔值的组合，
/// 用纯函数把真值表钉死成本极低。
final class KeepAwakePolicyTests: XCTestCase {

    /// 开关开 + 有任务 → 常驻。
    func testHoldsWhenEnabledAndTasksRunning() {
        XCTAssertTrue(KeepAwakePolicy.shouldHold(enabled: true, hasActiveTasks: true))
    }

    /// 开关开但没任务 → 不常驻（任务结束就该恢复系统熄屏）。
    func testReleasesWhenNoActiveTasks() {
        XCTAssertFalse(KeepAwakePolicy.shouldHold(enabled: true, hasActiveTasks: false))
    }

    /// 开关关 → 即使有任务也不常驻（不能无视用户选择）。
    func testNeverHoldsWhenDisabled() {
        XCTAssertFalse(KeepAwakePolicy.shouldHold(enabled: false, hasActiveTasks: true))
        XCTAssertFalse(KeepAwakePolicy.shouldHold(enabled: false, hasActiveTasks: false))
    }

    /// 真值表全量覆盖：只有 (true, true) 一个组合为真。
    func testTruthTable() {
        var truthy: [(Bool, Bool)] = []
        for enabled in [true, false] {
            for hasTasks in [true, false] where KeepAwakePolicy.shouldHold(enabled: enabled,
                                                                          hasActiveTasks: hasTasks) {
                truthy.append((enabled, hasTasks))
            }
        }
        XCTAssertEqual(truthy.count, 1)
        XCTAssertTrue(truthy.first!.0)
        XCTAssertTrue(truthy.first!.1)
    }
}

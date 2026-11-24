import Foundation
import XCTest
@testable import TouchBarBuddy

/// V8「一瞥型极简」的布局开关单测。
///
/// 为什么钉这里：极简模式**只该少 item，不该改语义**。
/// 一旦有人手滑把 `.choice` 也一起精简，用户就会在必须做选择时看不到选项，
/// 整个流程卡住 —— 这是最难靠肉眼发现的失效（bar 看起来「正常」，只是少了按钮）。
final class MinimalModeTests: XCTestCase {

    private func kinds(_ state: TouchBarState, minimal: Bool) -> [String] {
        TouchBarItemFactory.identifiers(
            for: state,
            generation: 1,
            notice: nil,
            idleStats: IdleStats(todayCompleted: 3, todayCredits: 1.5, totalCredits: 0),
            minimalMode: minimal,
            layoutOrder: Settings.defaultLayoutOrder
        ).compactMap { TouchBarItemFactory.kind(of: $0) }
    }

    /// 工作态：极简只留 summary + voice。
    func testWorkingMinimalHidesTaskStrip() {
        let task = TaskInfo(id: "t", title: "任务", status: .working)
        let state = TouchBarState.working(tasks: [task])

        XCTAssertEqual(kinds(state, minimal: true), ["summary", "voice"])
        XCTAssertEqual(kinds(state, minimal: false), ["summary", "task", "voice"])
    }

    /// 空闲态：极简连今日统计也隐藏（一瞥型只要「一个数字 + 一个状态」）。
    func testIdleMinimalHidesStats() {
        XCTAssertEqual(kinds(.idle, minimal: true), ["summary", "voice"])
        XCTAssertEqual(kinds(.idle, minimal: false), ["summary", "stats", "voice"])
    }

    /// 待确认态同样精简（数量已经在 summary 里）。
    func testPendingMinimalHidesTaskStrip() {
        let task = TaskInfo(id: "p", title: "待确认", status: .pending)
        XCTAssertEqual(kinds(.pending(tasks: [task]), minimal: true), ["summary", "voice"])
    }

    /// **回归守卫**：`.choice` 态绝不能被极简模式精简。
    ///
    /// 选项是用户此刻唯一能做的事，少一个就等于让 WorkBuddy 卡在半路。
    func testChoiceStateIgnoresMinimalMode() {
        let state = TouchBarState.choice(title: "是否继续", options: ["继续", "取消"])
        let normal = kinds(state, minimal: false)
        let minimal = kinds(state, minimal: true)

        XCTAssertEqual(minimal, normal, "极简模式改动了 choice 态布局")
        XCTAssertTrue(minimal.contains("voice"))
        XCTAssertTrue(minimal.contains("dtitle"))
    }

    /// 瞬时提示位在极简模式下仍要保留（失败红字不能因为极简就消失）。
    func testMinimalModeKeepsNoticeItem() {
        let ids = TouchBarItemFactory.identifiers(
            for: .idle,
            generation: 1,
            notice: TransientNotice(text: "出错了", style: .error),
            idleStats: .empty,
            minimalMode: true,
            layoutOrder: Settings.defaultLayoutOrder
        ).compactMap { TouchBarItemFactory.kind(of: $0) }

        XCTAssertEqual(ids.first, "error", "极简模式吞掉了错误提示位")
        XCTAssertTrue(ids.contains("voice"))
    }
}

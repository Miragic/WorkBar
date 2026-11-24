import XCTest
@testable import TouchBarBuddy

/// 空闲态统计文案单元测试。
///
/// 注意：本机 `swift test` 不可用（SwiftPM manifest 链接失败），此测试仅作逻辑覆盖，靠外部编译校验。
final class IdleStatsTests: XCTestCase {

    func testLabelFormatsCreditsWithTwoDecimals() {
        let stats = IdleStats(todayCompleted: 3, todayCredits: 2605.79, totalCredits: 6938.29)
        XCTAssertEqual(stats.label, "今日3完成 · 消耗2605.79")
    }

    func testEmptyLabel() {
        XCTAssertEqual(IdleStats.empty.label, "今日0完成 · 消耗0.00")
    }

    func testIntegerCreditsPadsTwoDecimals() {
        let stats = IdleStats(todayCompleted: 1, todayCredits: 5, totalCredits: 5)
        XCTAssertEqual(stats.label, "今日1完成 · 消耗5.00")
    }

    // MARK: - 只展示本地可算的数据

    /// 余额已不再展示：文案里绝不能出现「余额」二字。
    ///
    /// 余额曾经靠按压 WorkBuddy 头像弹窗读界面文本获得，会在用户眼前弹面板、抢焦点，
    /// 已按「割裂体验需先确认」的要求整体移除。真要做到无感，只能等后台接口。
    func testLabelNeverMentionsBalance() {
        let stats = IdleStats(todayCompleted: 4, todayCredits: 2730.31, totalCredits: 7100.0)
        XCTAssertFalse(stats.label.contains("余额"))
        XCTAssertEqual(stats.label, "今日4完成 · 消耗2730.31")
    }
}

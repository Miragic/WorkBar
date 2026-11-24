import XCTest
@testable import TouchBarBuddy

/// WorkBuddy 轮次耗时文案的解析单测。
///
/// 格式必须和界面红框里的 `已处理 1m8s` / `已完成 15m42s` 对齐；
/// 解析错会让 Touch Bar 显示一个和 WorkBuddy 不一致的数，正是用户这次反馈的问题。
final class TurnDurationTests: XCTestCase {

    func testParseSecondsOnly() {
        XCTAssertEqual(TurnDurationReader.parse("42s"), 42)
        XCTAssertEqual(TurnDurationReader.parse("0s"), 0)
    }

    func testParseMinutesAndSeconds() {
        XCTAssertEqual(TurnDurationReader.parse("1m8s"), 68)
        XCTAssertEqual(TurnDurationReader.parse("15m42s"), 942)
    }

    func testParseHours() {
        XCTAssertEqual(TurnDurationReader.parse("1h2m3s"), 3723)
        XCTAssertEqual(TurnDurationReader.parse("2h0m5s"), 7205)
    }

    /// 带 `已处理 ` / `已完成 ` 前缀的整句也能解析（AX 读到的是整句）。
    func testParseFullLabel() {
        XCTAssertEqual(TurnDurationReader.parse("已处理 1m8s"), 68)
        XCTAssertEqual(TurnDurationReader.parse("已完成 15m42s"), 942)
    }

    func testParseRejectsGarbage() {
        XCTAssertNil(TurnDurationReader.parse(""))
        XCTAssertNil(TurnDurationReader.parse("耗时未知"))
        // 没有秒单位就不认 —— 避免把「3m」误当成 3 秒或 180 秒。
        XCTAssertNil(TurnDurationReader.parse("已完成 3m"))
    }

    /// 解析出来的秒数格式化回去必须与原文案一致，否则 Touch Bar 会和 WorkBuddy 对不上。
    func testRoundTripMatchesWorkBuddy() {
        for text in ["42s", "1m8s", "15m42s", "1h2m3s"] {
            let seconds = TurnDurationReader.parse(text)
            XCTAssertTrue(seconds != nil, "解析失败：\(text)")
            XCTAssertEqual(ActivityAge.formatActivityAge(seconds), text)
        }
    }

    // MARK: - 积分文案

    /// 时长必须取**第一个**「已处理」（当前轮），不能取最后的（历史轮）。
    /// 真机 2026-11-20 bug：AX 里「已处理 25s」在前、「已处理 8m34s」在后，
    /// 取最后导致显示 8m34s，而实际才 39s。
    func testCurrentTurnSecondsPicksFirstCandidate() {
        let candidates = ["已处理 39s", "已处理 8m34s", "已处理 1m2s"]
        XCTAssertEqual(TurnDurationReader.currentTurnSeconds(from: candidates), 39)
        // 顺序反过来也要取第一个，证明与「取最小/取最大」无关，纯粹按遍历顺序。
        XCTAssertEqual(TurnDurationReader.currentTurnSeconds(from: ["已处理 5s", "已处理 2m"]), 5)
        XCTAssertTrue(TurnDurationReader.currentTurnSeconds(from: []) == nil)
        XCTAssertTrue(TurnDurationReader.currentTurnSeconds(from: ["已完成 15m42s"]) == nil,
                      "只认「已处理」，不认历史轮的「已完成」")
    }

    /// 与 WorkBuddy 界面一致：菱形 + 保留 2 位小数。
    func testCreditsFormat() {
        XCTAssertEqual(TurnDurationReader.formatCredits(10.56), "◇ 10.56")
        XCTAssertEqual(TurnDurationReader.formatCredits(252.49), "◇ 252.49")
        XCTAssertEqual(TurnDurationReader.formatCredits(1), "◇ 1.00")
    }

    /// 0 / nil / 非法值不显示 —— 「◇ 0.00」是噪音，不如留空。
    func testCreditsHiddenForInvalidValues() {
        XCTAssertNil(TurnDurationReader.formatCredits(nil))
        XCTAssertNil(TurnDurationReader.formatCredits(0))
        XCTAssertNil(TurnDurationReader.formatCredits(-3))
        XCTAssertNil(TurnDurationReader.formatCredits(.nan))
        XCTAssertNil(TurnDurationReader.formatCredits(.infinity))
    }
}

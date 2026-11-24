import Foundation
import XCTest
@testable import TouchBarBuddy

/// 空闲统计「今日各轮之和 / 本轮消耗」两种口径的单元测试。
///
/// 根因回归：旧实现按 `sessions.updated_at` 是否今天来过滤，再用 `json_each` 把整个
/// `credit_json` 全量求和，把用了 11 天的会话 73 条 request（22835.98）当成今日消耗。
/// 这里验证按 UUIDv7 时间戳逐条按本地日期过滤的修正。
final class IdleCreditsTests: XCTestCase {

    /// 造一个 UUIDv7 风格的 key：前 12 位 hex 为毫秒时间戳，其余固定。
    private func key(for date: Date) -> String {
        let millis = Int64(date.timeIntervalSince1970 * 1000)
        return String(format: "%012llx", millis) + "7d16b772190cc2ce3f4f"
    }

    /// 固定「今天」为 2026-11-23 12:00 本地时间，避免测试随真实日期漂移。
    private func fixedNow() -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 23,
                                                    hour: 12, minute: 0, second: 0))!
    }

    // MARK: - UUIDv7 解码

    func testUUIDv7DateDecodesKnownKey() {
        guard let date = SQLiteSessionReader.uuidV7Date(
            forKey: "01a1cda8258e7d16b772190cc2ce3f4f") else {
            return XCTFail("已知 UUIDv7 key 应能解码")
        }
        // 0x01a1cda8258e ms → 2026-11-12 10:48:31（本地 UTC+8）；
        // 用 epoch 秒断言，避免测试机时区不同导致断言失败。
        let expected = Double(0x01a1cda8258e) / 1000.0
        XCTAssertTrue(abs(date.timeIntervalSince1970 - expected) < 0.001,
                      "解码时间戳应为 \(expected)，实际 \(date.timeIntervalSince1970)")
    }

    func testUUIDv7DateAcceptsDashedUUIDAndRejectsJunk() {
        let dashed = "01a1cda8-258e-7d16-b772-190cc2ce3f4f"
        guard let date = SQLiteSessionReader.uuidV7Date(forKey: dashed) else {
            return XCTFail("带横线的标准 UUIDv7 也应能解码")
        }
        let expected = Double(0x01a1cda8258e) / 1000.0
        XCTAssertTrue(abs(date.timeIntervalSince1970 - expected) < 0.001)

        XCTAssertNil(SQLiteSessionReader.uuidV7Date(forKey: ""), "空 key 应跳过")
        XCTAssertNil(SQLiteSessionReader.uuidV7Date(forKey: "123"), "过短 key 应跳过")
        XCTAssertNil(SQLiteSessionReader.uuidV7Date(forKey: "not-a-uuid"), "非 hex 应跳过")
        // 全 f → 解成公元一万多年，旧格式必须被年份范围挡掉。
        XCTAssertNil(SQLiteSessionReader.uuidV7Date(
            forKey: "ffffffffffffffffffffffffffffffff"), "年份超范围应跳过")
    }

    // MARK: - 口径 A：今日各轮之和

    func testCreditsTodaySumsOnlyTodaysEntries() {
        let now = fixedNow()
        let todayAM = Calendar.current.date(byAdding: .hour, value: -2, to: now)!
        let todayPM = Calendar.current.date(byAdding: .minute, value: 30, to: now)!
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!

        // 今天 2 条（1.20 + 2.30）+ 昨天 1 条（9.99）+ 旧格式 1 条（500）。
        let json = """
        {"\(key(for: yesterday))": 9.99,
         "\(key(for: todayAM))": 1.20,
         "legacy-key-no-timestamp": 500,
         "\(key(for: todayPM))": 2.30}
        """
        let result = SQLiteSessionReader.creditsToday(from: json, now: now)
        XCTAssertTrue(abs(result - 3.50) < 0.001,
                      "只应累加今天的 2 条 = 3.50，实际 \(result)")
    }

    // MARK: - 口径 B：本轮消耗

    func testLatestCreditUsesTimestampNotDictionaryOrder() {
        let now = fixedNow()
        let older = Calendar.current.date(byAdding: .day, value: -3, to: now)!
        let newest = Calendar.current.date(byAdding: .minute, value: -5, to: now)!

        // 故意把「最新」的条目写在最前、旧的写在最后，验证按时间而非字典顺序取值。
        let json = """
        {"\(key(for: newest))": 7.77,
         "\(key(for: older))": 1.11,
         "legacy-key": 9999}
        """
        let result = SQLiteSessionReader.latestCredit(from: json)
        XCTAssertTrue(abs(result - 7.77) < 0.001,
                      "应取时间最新一条 = 7.77，实际 \(result)")
    }

    // MARK: - 容错

    func testMalformedJSONReturnsZero() {
        let now = fixedNow()
        XCTAssertEqual(SQLiteSessionReader.creditsToday(from: nil, now: now), 0)
        XCTAssertEqual(SQLiteSessionReader.creditsToday(from: "not json", now: now), 0)
        XCTAssertEqual(SQLiteSessionReader.creditsToday(from: "[]", now: now), 0)
        XCTAssertEqual(SQLiteSessionReader.creditsToday(from: "{}", now: now), 0)
        XCTAssertEqual(SQLiteSessionReader.latestCredit(from: nil), 0)
        XCTAssertEqual(SQLiteSessionReader.latestCredit(from: "{\"legacy-key\": 12.5}"), 0)
    }

    // MARK: - label 随口径变化

    func testIdleStatsLabelFollowsMode() {
        let stats = IdleStats(todayCompleted: 3, todayCredits: 2605.79,
                              totalCredits: 0, latestCredit: 0.95)
        XCTAssertEqual(stats.label(mode: .todayTotal), "今日3完成 · 消耗2605.79")
        XCTAssertEqual(stats.label(mode: .latest), "今日3完成 · 本轮0.95")
        // 默认 label 仍保持原口径，兼容既有展示与测试。
        XCTAssertEqual(stats.label, "今日3完成 · 消耗2605.79")
        XCTAssertEqual(IdleStats.empty.latestCredit, 0)
    }
}

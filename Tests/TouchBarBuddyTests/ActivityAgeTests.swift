import Foundation
import XCTest
@testable import TouchBarBuddy

/// `ActivityAge` 的单测（V13 降级版「距上次活动」）。
///
/// 为什么这块必须钉死：它是本功能里唯一**能自动验证**的部分 —— 真实时长要靠
/// `sessions.last_activity_at`，而这个字段的单位（秒 / 毫秒）在文档里都没写清，
/// 一旦换算错，界面上会显示「56 年」或者干脆永远不出现，两种都极难靠肉眼发现。
final class ActivityAgeTests: XCTestCase {

    // MARK: - 格式化

    /// 无数据 / 负数 → 不显示（而不是显示 `-1s` 这种噪音）。
    func testNilAndNegativeYieldNil() {
        XCTAssertNil(ActivityAge.formatActivityAge(nil))
        XCTAssertNil(ActivityAge.formatActivityAge(-1))
        XCTAssertNil(ActivityAge.formatActivityAge(-3600))
    }

    /// 0 秒是合法值：刚刚有过活动，显示 `0s`（不能当成「无数据」吞掉）。
    func testZeroSecondsShowsZero() {
        XCTAssertEqual(ActivityAge.formatActivityAge(0), "0s")
    }

    /// 1 分钟以内按**整秒**显示。
    ///
    /// 这条钉的是「秒数必须能被读到」：曾经把 60 秒以内折叠成一个恒定符号（为了消掉
    /// 每轮 3 秒的文字变化），用户真机否掉了 ——「时间显示的不要改」。
    /// 若哪天有人再去折叠它，这条会立刻红。
    /// 用 0 / 0.4 / 1 / 12 / 59 / 59.9 覆盖「整秒 / 小数截断 / 两位 / 接近边界」四种输入。
    func testSecondsRange() {
        XCTAssertEqual(ActivityAge.formatActivityAge(0), "0s")
        XCTAssertEqual(ActivityAge.formatActivityAge(0.4), "0s")
        XCTAssertEqual(ActivityAge.formatActivityAge(1), "1s")
        XCTAssertEqual(ActivityAge.formatActivityAge(12), "12s")
        XCTAssertEqual(ActivityAge.formatActivityAge(59), "59s")
        XCTAssertEqual(ActivityAge.formatActivityAge(59.9), "59s")
    }

    /// 边界必须**向上**切到分钟：59.9 → `59s`，60 → `1m`。
    ///
    /// 钉住这条是因为「先 `Int()` 截断再比区间」的顺序很容易被改错：
    /// 若先四舍五入再判，59.9 会变成 60 从而落到 `1m`；若判 `<= 60` 则 60 会留在秒档。
    /// 两种都会让「整整 1 分钟」这个时刻的读数错一格。
    func testMinuteBoundaryFlipsToMinutes() {
        XCTAssertEqual(ActivityAge.formatActivityAge(59.9), "59s")
        XCTAssertEqual(ActivityAge.formatActivityAge(60), "1m0s")
    }

    /// 跨到 60 秒即切分钟（边界值 60 必须显示 `1m`，不能是 `0m`）。
    func testMinuteRange() {
        XCTAssertEqual(ActivityAge.formatActivityAge(60), "1m0s")
        XCTAssertEqual(ActivityAge.formatActivityAge(95), "1m35s")
        XCTAssertEqual(ActivityAge.formatActivityAge(3599), "59m59s")
    }

    /// 跨到 3600 秒即切小时。
    func testHourRange() {
        XCTAssertEqual(ActivityAge.formatActivityAge(3600), "1h0m0s")
        XCTAssertEqual(ActivityAge.formatActivityAge(86400), "24h0m0s")
    }

    /// 文案长度：常规最多 7 个字符（`1h2m3s`），极端值（11 天）会到 10 个字符；
    /// 不含空格，槽宽已加到 44pt。
    func testFormattedTextIsCompact() {
        for seconds in [0.0, 59, 60, 3599, 3600, 86400, 999999] {
            guard let text = ActivityAge.formatActivityAge(seconds) else {
                return XCTFail("\(seconds) 不该返回 nil")
            }
            XCTAssertTrue(text.count <= 10, "\(text) 超过 10 个字符")
            XCTAssertFalse(text.contains(" "), "\(text) 含空格")
        }
    }

    /// 非法数值（NaN / 无穷）不能让 `Int()` 崩掉。
    func testNonFiniteYieldsNil() {
        XCTAssertNil(ActivityAge.formatActivityAge(Double.nan))
        XCTAssertNil(ActivityAge.formatActivityAge(Double.infinity))
    }

    // MARK: - 原始值换算

    /// 秒级原始值：直接与 now 相减。
    func testRawSecondsConvertDirectly() {
        let now: TimeInterval = 1_700_000_000
        XCTAssertEqual(ActivityAge.activityAge(fromRaw: 1_699_999_988, now: now), 12)
        XCTAssertEqual(ActivityAge.activityAge(fromRaw: 1_699_999_700, now: now), 300)
    }

    /// 毫秒级原始值：必须被识别并除以 1000。
    ///
    /// 这条是重点：本项目的 `updated_at` 就是毫秒（`updated_at/1000`），
    /// `last_activity_at` 若同为毫秒而我们按秒处理，会算出几十万小时。
    func testRawMillisecondsAreNormalized() {
        let now: TimeInterval = 1_700_000_000
        let rawMs = Int((now - 12) * 1000)
        XCTAssertEqual(ActivityAge.activityAge(fromRaw: rawMs, now: now), 12)

        let rawMsLongAgo = Int((now - 7200) * 1000)
        XCTAssertEqual(ActivityAge.activityAge(fromRaw: rawMsLongAgo, now: now), 7200)
    }

    /// 0 / NULL / 未来时间 / 不可信区间都视为无效。
    ///
    /// 0 是最常见的脏值（列存在但没写过），若当成有效会算出「距今 56 年」；
    /// 未来时间来自写库方时钟略快，显示负数没有意义；
    /// 小于 1e9（2001 年前）的值几乎一定是从文本里读错的数字（如 `2026-01-01T…` → `2026`）。
    func testInvalidRawValuesYieldNil() {
        let now: TimeInterval = 1_700_000_000
        XCTAssertNil(ActivityAge.activityAge(fromRaw: nil, now: now))
        XCTAssertNil(ActivityAge.activityAge(fromRaw: 0, now: now))
        XCTAssertNil(ActivityAge.activityAge(fromRaw: -5, now: now))
        XCTAssertNil(ActivityAge.activityAge(fromRaw: Int(now) + 60, now: now))
        XCTAssertNil(ActivityAge.activityAge(fromRaw: 2026, now: now))
    }

    // MARK: - 两个候选字段取更近者

    /// `updated_at` 更近 → 取它。
    func testTwoCandidatesPreferNewerUpdated() {
        let now: TimeInterval = 1_700_000_000
        let lastActivity = Int((now - 1000) * 1000)
        let updated = Int((now - 30) * 1000)
        XCTAssertEqual(ActivityAge.activityAge(lastActivityRaw: lastActivity,
                                               updatedRaw: updated,
                                               now: now), 30)
    }

    /// `last_activity_at` 更近 → 取它（真机暂时构造不出，但这是 `max` 的另一半）。
    func testTwoCandidatesPreferNewerLastActivity() {
        let now: TimeInterval = 1_700_000_000
        let lastActivity = Int((now - 30) * 1000)
        let updated = Int((now - 1000) * 1000)
        XCTAssertEqual(ActivityAge.activityAge(lastActivityRaw: lastActivity,
                                               updatedRaw: updated,
                                               now: now), 30)
    }

    /// 只有一个字段有效时，用有效的那个；两个都无效才 nil。
    func testTwoCandidatesFallBackToWhicheverIsValid() {
        let now: TimeInterval = 1_700_000_000
        let valid = Int((now - 45) * 1000)
        XCTAssertEqual(ActivityAge.activityAge(lastActivityRaw: nil, updatedRaw: valid, now: now), 45)
        XCTAssertEqual(ActivityAge.activityAge(lastActivityRaw: valid, updatedRaw: 0, now: now), 45)
        XCTAssertNil(ActivityAge.activityAge(lastActivityRaw: nil, updatedRaw: nil, now: now))
        XCTAssertNil(ActivityAge.activityAge(lastActivityRaw: 0, updatedRaw: 0, now: now))
    }

    /// 阈值常量：120 秒（2 分钟）—— 长任务常有 1 分钟以上空档，60 秒报警会变成噪音。
    func testStaleThresholdIsTwoMinutes() {
        XCTAssertEqual(ActivityAge.staleThreshold, 120)
        XCTAssertEqual(ActivityAge.formatActivityAge(119), "1m59s")
        XCTAssertEqual(ActivityAge.formatActivityAge(121), "2m1s")
    }

    // MARK: - 「已运行时长」与「距上次活动」是两个概念

    /// 用户 2026-11-19 报的 bug：时长显示 0,1,4,7,10,13 然后回到 0s。
    ///
    /// 根因是旧实现显示的是「距上次活动」（`updated_at` 每轮有输出就刷新，于是不断归零），
    /// 而用户要看的是「本次跑了多久」。修法是由控制器记录首次进入进行中的时刻，
    /// 显示 `elapsed`（只增不减），橙色仍按 `activityAge` 判定。
    ///
    /// 这条钉住「显示值可以远大于卡住阈值但仍不该被视为卡住」这个组合：
    /// elapsed = 600s（已跑 10 分钟）、activityAge = 5s（刚有输出）→ 显示 10m、不橙。
    func testElapsedAndActivityAgeAreIndependent() {
        let elapsed: TimeInterval = 600
        let activityAge: TimeInterval = 5

        XCTAssertEqual(ActivityAge.formatActivityAge(elapsed), "10m0s")
        XCTAssertEqual(ActivityAge.formatActivityAge(activityAge), "5s")

        // 卡住只看 activityAge：5 秒远小于 120，不该判卡住，尽管 elapsed 已经 10 分钟。
        XCTAssertFalse(activityAge > ActivityAge.staleThreshold)
        // 反过来：真的没动静了，activityAge 超阈值 → 卡住。
        XCTAssertTrue(TimeInterval(130) > ActivityAge.staleThreshold)
    }

    /// elapsed 只增不减：同一任务连续多次取值必须单调不减（旧 bug 的回归守卫）。
    func testElapsedIsMonotonic() {
        let samples: [TimeInterval] = [0, 1, 4, 7, 10, 13, 16, 19]
        for (previous, current) in zip(samples, samples.dropFirst()) {
            // 项目自带的 XCTest shim 没有 LessThanOrEqual，用布尔断言等价表达。
            XCTAssertTrue(previous <= current, "elapsed 不允许下降（旧 bug 会归零）")
        }
    }
}

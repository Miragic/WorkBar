import XCTest

/// 上下文占用（`session_usage.used/size` → 详情第二行 `◑ 53.3%`）的纯函数单测。
///
/// 这里钉三件事：**比例怎么算**（含脏数据夹紧）、**文案怎么截断**（不是四舍五入）、
/// **什么时候算「快满了」**（阈值边界含等号）。这些规则错一样，界面上就会显示
/// 一个「看起来很像真的、但其实是错的」数字 —— 那比不显示更糟。
final class ContextUsageTests: XCTestCase {

    // MARK: - ratio(used:size:)

    /// 真实数据：当前会话 44609 / 600000 ≈ 7.4%，不该报警。
    ///
    /// 这组数字来自 2026-11 真机 `~/.workbuddy/workbuddy.db`，是最常见的形态：
    /// 比例很小、应当完全安静。
    func testRatioForCurrentSessionSample() {
        guard let ratio = ContextUsage.ratio(used: 44609, size: 600000) else {
            return XCTFail("44609/600000 应该能算出比例")
        }
        XCTAssertTrue(abs(ratio - 0.0743) < 0.0001, "ratio=\(ratio) 应约为 0.0743")
        XCTAssertFalse(ContextUsage.isTight(ratio), "7.4% 不该报警")
    }

    /// 历史峰值 158494 / 300000 ≈ 52.8%：同样不该报警，但文案要显示 52%。
    func testRatioForHistoricalPeakSample() {
        guard let ratio = ContextUsage.ratio(used: 158494, size: 300000) else {
            return XCTFail("158494/300000 应该能算出比例")
        }
        XCTAssertTrue(abs(ratio - 0.5283) < 0.0001, "ratio=\(ratio) 应约为 0.5283")
        XCTAssertFalse(ContextUsage.isTight(ratio), "52.8% 不该报警")
        XCTAssertEqual(ContextUsage.format(ratio), "◒ 52.8%")
    }

    /// `size <= 0` → nil。size 为 0 时做除法会得到 inf/NaN，必须先拦。
    func testRatioIsNilForNonPositiveSize() {
        XCTAssertNil(ContextUsage.ratio(used: 100, size: 0))
        XCTAssertNil(ContextUsage.ratio(used: 100, size: -1))
    }

    /// `used < 0` / `used == 0` → nil（0 是「还没开始用」的噪音，不显示）。
    func testRatioIsNilForNonPositiveUsed() {
        XCTAssertNil(ContextUsage.ratio(used: -1, size: 600000))
        XCTAssertNil(ContextUsage.ratio(used: 0, size: 600000))
    }

    /// 任一输入为 nil → nil（列缺失 / 该会话没有 usage 行）。
    func testRatioIsNilWhenAnyInputMissing() {
        XCTAssertNil(ContextUsage.ratio(used: nil, size: 600000))
        XCTAssertNil(ContextUsage.ratio(used: 100, size: nil))
        XCTAssertNil(ContextUsage.ratio(used: nil, size: nil))
    }

    /// 脏数据 `used > size` → 夹到 1.0，绝不显示 >100%。
    func testRatioClampsDirtyDataToOne() {
        XCTAssertEqual(ContextUsage.ratio(used: 700, size: 600), 1.0)
        // 恰好等于窗口大小也算「满了」，走同一条分支。
        XCTAssertEqual(ContextUsage.ratio(used: 600, size: 600), 1.0)
    }

    // MARK: - format(_:)

    /// 百分比**截断**而非四舍五入（保留 1 位小数）：0.999 必须是 99.9%，不能是 100.0%。
    ///
    /// 「显示满了但其实没满」会让人以为已经压缩了上下文，
    /// 而「显示 99.9%」才是诚实的（还差一点）。
    func testFormatTruncatesInsteadOfRounding() {
        XCTAssertEqual(ContextUsage.format(0.999), "● 99.9%")
        XCTAssertEqual(ContextUsage.format(0.533), "◒ 53.3%")
        // 0.29 在 Double 里是 0.28999999999999998，直接截断会掉一个刻度 → 28.9%。
        // 这条就是「epsilon 补偿」的守卫。
        XCTAssertEqual(ContextUsage.format(0.29), "◑ 29.0%")
        // 整百分比也必须带 `.0`，不能有时写 53% 有时写 53.3% —— 位数固定才不会左右跳。
        XCTAssertEqual(ContextUsage.format(0.53), "◒ 53.0%")
    }

    /// 满量程与非法输入。
    func testFormatBoundaries() {
        XCTAssertEqual(ContextUsage.format(1.0), "● 100.0%")
        // 脏数据 > 1 也要夹到 100%，不能出现「● 117%」。
        XCTAssertEqual(ContextUsage.format(1.17), "● 100.0%")
        XCTAssertNil(ContextUsage.format(nil))
        XCTAssertNil(ContextUsage.format(0))
        XCTAssertNil(ContextUsage.format(-0.2))
    }

    // MARK: - isTight(_:)

    /// 阈值边界必须**含等号**：0.749 不报，0.75 报。
    ///
    /// 写成 `>` 会让恰好 75% 那一格静默地不报警 —— 而那正是「留 25% 余量」的定义点。
    func testIsTightThresholdBoundary() {
        XCTAssertFalse(ContextUsage.isTight(0.749))
        XCTAssertTrue(ContextUsage.isTight(0.75), "0.75 必须含在阈值内")
        XCTAssertTrue(ContextUsage.isTight(1.0))
        XCTAssertFalse(ContextUsage.isTight(nil))
    }

    /// 阈值常量本身：0.75（不是 0.9）。改这个数字等于改产品语义，必须显式确认。
    func testTightThresholdValue() {
        XCTAssertEqual(ContextUsage.tightThreshold, 0.75)
    }

    // MARK: - 与 TaskInfo 的接线

    /// `TaskInfo.isContextTight` 必须完全跟随 `ContextUsage.isTight`（单一真源）。
    func testTaskInfoExposesTightFlag() {
        let loose = TaskInfo(id: "a", title: "甲", status: .working, contextUsage: 0.5)
        let tight = TaskInfo(id: "b", title: "乙", status: .working, contextUsage: 0.8)
        let missing = TaskInfo(id: "c", title: "丙", status: .working)
        XCTAssertFalse(loose.isContextTight)
        XCTAssertTrue(tight.isContextTight)
        XCTAssertFalse(missing.isContextTight, "没有数据时不该报警")
        XCTAssertNil(missing.contextUsage, "默认值必须是 nil，否则所有构造点都要改")
    }

    /// 环形符号分档边界必须精确：24.9% 还是 1/4 环，25% 才是半环。
    /// 用「不到边界」而不是四舍五入 —— 49% 不该提前显示成 3/4 环。
    func testRingGlyphBoundaries() {
        XCTAssertEqual(ContextUsage.ringGlyph(for: 0.01), "◔")
        XCTAssertEqual(ContextUsage.ringGlyph(for: 0.249), "◔")
        XCTAssertEqual(ContextUsage.ringGlyph(for: 0.25), "◑")
        XCTAssertEqual(ContextUsage.ringGlyph(for: 0.499), "◑")
        XCTAssertEqual(ContextUsage.ringGlyph(for: 0.50), "◒")
        XCTAssertEqual(ContextUsage.ringGlyph(for: 0.749), "◒")
        XCTAssertEqual(ContextUsage.ringGlyph(for: 0.75), "●")
        XCTAssertEqual(ContextUsage.ringGlyph(for: 1.0), "●")
    }

    /// 符号与百分比必须同档，否则会出现「半环 + 74.9%」这种自相矛盾的读数。
    func testRingGlyphMatchesPercentage() {
        XCTAssertEqual(ContextUsage.format(0.198), "◔ 19.8%")
        XCTAssertEqual(ContextUsage.format(0.53), "◒ 53.0%")
        XCTAssertEqual(ContextUsage.format(0.80), "● 80.0%")
    }
}

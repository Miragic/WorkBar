import XCTest
@testable import TouchBarBuddy

/// `PermissionParser` 的单测。
///
/// 这是 V17 里**唯一能自动验证**的部分：真实「允许完全访问」弹窗只有在 WorkBuddy
/// 真的请求文件 / 终端 / 网络权限时才出现，无法在测试里复现。所以识别规则、裁剪规则
/// 必须在这里钉死，AX 那一侧只留薄胶水。
final class PermissionParserTests: XCTestCase {

    // MARK: - 识别

    /// 三项齐全 → 解析成功，且**保持界面原始顺序**（顺序错了用户会勾错权限）。
    func testParsesThreeItemsInOriginalOrder() {
        let request = PermissionParser.parse(
            title: "允许完全访问",
            checkboxes: [
                (label: "文件操作", granted: true),
                (label: "终端命令", granted: false),
                (label: "访问互联网", granted: true)
            ],
            fallbackTitle: "兜底"
        )
        XCTAssertEqual(request?.title, "允许完全访问")
        XCTAssertEqual(request?.items.count, 3)
        XCTAssertEqual(request?.items[0], PermissionItem(label: "文件操作", granted: true))
        XCTAssertEqual(request?.items[1], PermissionItem(label: "终端命令", granted: false))
        XCTAssertEqual(request?.items[2], PermissionItem(label: "访问互联网", granted: true))
    }

    /// 只有一个 checkbox → 不认。
    ///
    /// 这是最重要的保守规则：普通页面里单个勾选框到处都是，
    /// 误判会让 Touch Bar 在无风险时刻变出「允许 / 取消」，误触即授权。
    func testSingleCheckboxIsNotAPermissionRequest() {
        let request = PermissionParser.parse(
            title: "记住我的选择",
            checkboxes: [(label: "不再提示", granted: true)],
            fallbackTitle: "允许完全访问"
        )
        XCTAssertNil(request)
    }

    /// 两个 checkbox 就认（宽预算允许，且比单项明显更像权限确认）。
    func testTwoCheckboxesAreAccepted() {
        let request = PermissionParser.parse(
            title: "允许完全访问",
            checkboxes: [
                (label: "文件操作", granted: true),
                (label: "终端命令", granted: false)
            ],
            fallbackTitle: "允许完全访问"
        )
        XCTAssertEqual(request?.items.count, 2)
    }

    /// 五项 → 只取前三（Touch Bar 宽度只够 3 个）。
    func testMoreThanThreeItemsKeepsFirstThree() {
        let request = PermissionParser.parse(
            title: "允许完全访问",
            checkboxes: [
                (label: "文件操作", granted: true),
                (label: "终端命令", granted: false),
                (label: "访问互联网", granted: true),
                (label: "剪贴板", granted: false),
                (label: "通知", granted: false)
            ],
            fallbackTitle: "允许完全访问"
        )
        XCTAssertEqual(request?.items.count, 3)
        XCTAssertEqual(request?.items.map { $0.label }, ["文件操作", "终端命令", "访问互联网"])
    }

    /// 空白标签被丢弃；丢弃后还剩两项 → 仍然成立。
    func testBlankLabelsAreDroppedButRequestSurvives() {
        let request = PermissionParser.parse(
            title: "允许完全访问",
            checkboxes: [
                (label: "文件操作", granted: true),
                (label: "   ", granted: false),
                (label: "", granted: false),
                (label: "终端命令", granted: false)
            ],
            fallbackTitle: "允许完全访问"
        )
        XCTAssertEqual(request?.items.count, 2)
        XCTAssertEqual(request?.items.map { $0.label }, ["文件操作", "终端命令"])
    }

    /// 空白标签被丢弃后不足两项 → nil（不能靠空白项凑够「≥2」的门槛）。
    func testBlankLabelsLeavingLessThanTwoYieldsNil() {
        let request = PermissionParser.parse(
            title: "允许完全访问",
            checkboxes: [
                (label: "文件操作", granted: true),
                (label: "  ", granted: false),
                (label: "\n", granted: false)
            ],
            fallbackTitle: "允许完全访问"
        )
        XCTAssertNil(request)
    }

    /// 没有 checkbox（普通弹层）→ nil。
    func testNoCheckboxesYieldsNil() {
        let request = PermissionParser.parse(title: "成长计划",
                                             checkboxes: [],
                                             fallbackTitle: "允许完全访问")
        XCTAssertNil(request)
    }

    /// 标题为空 / 纯空白 → 用 `fallbackTitle`。
    func testEmptyTitleFallsBack() {
        let items = [(label: "文件操作", granted: true), (label: "终端命令", granted: false)]
        XCTAssertEqual(PermissionParser.parse(title: nil,
                                              checkboxes: items,
                                              fallbackTitle: "允许完全访问")?.title,
                       "允许完全访问")
        XCTAssertEqual(PermissionParser.parse(title: "   ",
                                              checkboxes: items,
                                              fallbackTitle: "允许完全访问")?.title,
                       "允许完全访问")
    }

    /// 兜底文案本身也是空白时，退回常量 —— 标题为空会在 Touch Bar 上留一块空白按钮。
    func testBlankFallbackTitleFallsBackToConstant() {
        let items = [(label: "文件操作", granted: true), (label: "终端命令", granted: false)]
        let request = PermissionParser.parse(title: "", checkboxes: items, fallbackTitle: "  ")
        XCTAssertEqual(request?.title, PermissionParser.fallbackTitle)
    }

    // MARK: - 按钮文案

    /// 勾选态与未勾选态的前缀。
    func testItemTitleMarksGrantedState() {
        XCTAssertEqual(PermissionParser.itemTitle(PermissionItem(label: "文件操作", granted: true)),
                       "✅ 文件操作")
        XCTAssertEqual(PermissionParser.itemTitle(PermissionItem(label: "终端命令", granted: false)),
                       "☐ 终端命令")
    }

    /// 超长标签截断成 5 字 + 单个 `…`。
    func testItemTitleTruncatesLongLabel() {
        let item = PermissionItem(label: "访问互联网和文件系统", granted: true)
        XCTAssertEqual(PermissionParser.itemTitle(item), "✅ 访问互联网…")
        // 恰好 5 字不截断。
        XCTAssertEqual(PermissionParser.itemTitle(PermissionItem(label: "访问互联网", granted: false)),
                       "☐ 访问互联网")
    }

    /// `truncate` 的边界：不超长原样返回、`limit <= 0` 不截断。
    func testTruncateBoundaries() {
        XCTAssertEqual(PermissionParser.truncate("文件操作", limit: 5), "文件操作")
        XCTAssertEqual(PermissionParser.truncate("文件操作", limit: 2), "文件…")
        XCTAssertEqual(PermissionParser.truncate(" 文件操作 ", limit: 5), "文件操作")
        XCTAssertEqual(PermissionParser.truncate("文件操作", limit: 0), "文件操作")
    }

    // MARK: - 按钮文本匹配

    /// 精确匹配优先，其次包含 —— 容忍真实界面上的装饰（「允许 ✓」）。
    func testMatchOptionExactThenContains() {
        XCTAssertEqual(PermissionParser.matchOption("允许", in: ["取消", "允许"]), "允许")
        XCTAssertEqual(PermissionParser.matchOption("允许", in: ["取消", "允许 ✓"]), "允许 ✓")
        XCTAssertEqual(PermissionParser.matchOption("取消", in: ["取消 (Esc)"]), "取消 (Esc)")
        XCTAssertNil(PermissionParser.matchOption("允许", in: ["关闭", "奖品"]))
    }

    /// 语义标签为空 → 不做匹配（避免空串 `contains` 命中第一个按钮，误按）。
    func testMatchOptionRejectsEmptyTarget() {
        XCTAssertNil(PermissionParser.matchOption("", in: ["允许"]))
        XCTAssertNil(PermissionParser.matchOption("   ", in: ["允许"]))
    }
}

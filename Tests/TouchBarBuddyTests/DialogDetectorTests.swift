import XCTest
@testable import TouchBarBuddy

/// `DialogDetector` 与「弹层优先」状态机的单元测试。
///
/// 真实的弹层检测需要 WorkBuddy 处于某个弹层打开状态 + 辅助功能授权，无法在单测里稳定复现；
/// 但「把 title + 按钮文本列表变成一个快照」以及「弹层是否压过任务状态」都是纯函数，
/// 可以完整覆盖 —— 这两处正是「把 `<退出登录>` 铺到电容触摸的 Touch Bar 上」这类事故的关口。
final class DialogDetectorTests: XCTestCase {

    // MARK: - 快照构建：正常路径

    /// 真机「成长计划」弹层的原始数据（options 必须三个都齐全且保序）。
    func testNormalDialogCollectsAllThreeOptions() {
        let snapshot = DialogDetector.buildSnapshot(
            title: "成长计划",
            buttons: ["关闭", "奖品", "抽奖(0)"]
        )
        XCTAssertEqual(snapshot?.title, "成长计划")
        XCTAssertEqual(snapshot?.options, ["关闭", "奖品", "抽奖(0)"])
    }

    /// 超过 3 个按钮只取前 3 个（Touch Bar 宽度不够铺更多）。
    /// 这里用 4 个按钮：正好是阈值上限，能被接受再截断成 3 个。
    func testMoreThanThreeButtonsTruncated() {
        let snapshot = DialogDetector.buildSnapshot(
            title: "确认",
            buttons: ["A1", "B2", "C3", "D4"]
        )
        XCTAssertEqual(snapshot?.options, ["A1", "B2", "C3"])
    }

    /// 空 / 纯空白按钮文本必须过滤（AX 里大量按钮只有描述没有文本）。
    func testEmptyButtonTextIsFiltered() {
        let snapshot = DialogDetector.buildSnapshot(
            title: "成长计划",
            buttons: ["", "   ", "关闭", "\n", "奖品"]
        )
        XCTAssertEqual(snapshot?.options, ["关闭", "奖品"])
    }

    /// 重复文本只保留第一次出现（Chromium 同一个按钮会同时挂在 AXChildren 与 AXVisibleChildren 下）。
    func testDuplicateButtonTextIsDeduplicated() {
        let snapshot = DialogDetector.buildSnapshot(
            title: "成长计划",
            buttons: ["关闭", "奖品", "关闭", "抽奖(0)"]
        )
        XCTAssertEqual(snapshot?.options, ["关闭", "奖品", "抽奖(0)"])
    }

    /// 去重发生在截断之前：重复项不能占掉有效名额。
    func testDedupHappensBeforeTruncation() {
        let snapshot = DialogDetector.buildSnapshot(
            title: "x",
            buttons: ["关闭", "关闭", "关闭", "奖品"]
        )
        XCTAssertEqual(snapshot?.options, ["关闭", "奖品"])
    }

    // MARK: - 快照构建：拒绝路径

    /// 核心安全回归：含「退出登录」的弹层整个不铺。
    func testDangerOptionRejectsWholeDialog() {
        XCTAssertNil(DialogDetector.buildSnapshot(
            title: "账号",
            buttons: ["退出登录", "取消"]
        ))
    }

    /// 黑名单按「包含」判定：真实文案常带修饰词。
    func testDangerDetectionIsSubstringBased() {
        XCTAssertNil(DialogDetector.buildSnapshot(
            title: "账号",
            buttons: ["确认退出登录", "取消"]
        ))
        XCTAssertNil(DialogDetector.buildSnapshot(
            title: "系统",
            buttons: ["立即注销", "取消"]
        ))
    }

    /// 黑名单必须对**全部**按钮生效，不能只看会铺出去的前 3 个。
    func testBlacklistAppliesToFourthButtonToo() {
        XCTAssertNil(DialogDetector.buildSnapshot(
            title: "账号",
            buttons: ["一", "二", "三", "退出登录"]
        ))
    }

    /// 一个有效按钮都没有 => 不是可点弹层，返回 nil。
    func testNoButtonsYieldsNil() {
        XCTAssertNil(DialogDetector.buildSnapshot(title: "成长计划", buttons: []))
        XCTAssertNil(DialogDetector.buildSnapshot(title: "成长计划", buttons: ["", "  "]))
    }

    /// 标题缺失时用兜底文案，不能崩、不能出现空标题 item。
    func testMissingTitleFallsBackAndDoesNotCrash() {
        XCTAssertEqual(DialogDetector.buildSnapshot(title: nil, buttons: ["关闭"])?.title,
                       DialogDetector.fallbackTitle)
        XCTAssertEqual(DialogDetector.buildSnapshot(title: "", buttons: ["关闭"])?.title,
                       DialogDetector.fallbackTitle)
        XCTAssertEqual(DialogDetector.buildSnapshot(title: "   ", buttons: ["关闭"])?.title,
                       DialogDetector.fallbackTitle)
    }

    // MARK: - 按钮数阈值（内容页 vs 真实选择框）

    /// 核心判据：按钮数 5 > 阈值 4 => 视为内容页，整个弹层不铺。
    func testDialogWithTooManyButtonsIsRejected() {
        XCTAssertNil(DialogDetector.buildSnapshot(
            title: "成长计划",
            buttons: ["关闭", "奖品", "查看活动规则", "兑换奖励", "全年活跃记录"]
        ))
    }

    /// 正好 4 个（阈值上限）=> 仍然是合法的选择框。
    func testDialogAtThresholdIsAccepted() {
        let snapshot = DialogDetector.buildSnapshot(
            title: "确认操作",
            buttons: ["取消", "确定", "查看详情", "复制"]
        )
        XCTAssertEqual(snapshot?.options, ["取消", "确定", "查看详情"])
    }

    /// 阈值可被环境变量覆盖（真机在内容页上验证链路时用）。
    func testThresholdEnvOverrideIsParsed() {
        XCTAssertEqual(DialogDetector.parsedMaxChoiceButtons("20"), 20)
        XCTAssertEqual(DialogDetector.parsedMaxChoiceButtons("abc"), 4)
        XCTAssertEqual(DialogDetector.parsedMaxChoiceButtons(""), 4)
        XCTAssertEqual(DialogDetector.parsedMaxChoiceButtons(nil), 4)
        // 非法值不能让阈值变成 0 / 负数，否则任何弹层都会被拒。
        XCTAssertEqual(DialogDetector.parsedMaxChoiceButtons("0"), 4)
        XCTAssertEqual(DialogDetector.parsedMaxChoiceButtons("-3"), 4)
    }

    /// 生产默认阈值就是 4（没设环境变量时）。
    func testDefaultThresholdConstant() {
        XCTAssertEqual(DialogDetector.defaultMaxChoiceButtons, 4)
    }

    // MARK: - 占位按钮过滤

    /// 纯数字按钮（抽奖格子编号）全部被滤掉，一个都不该铺出去。
    func testPureNumberButtonIsFiltered() {
        XCTAssertTrue(DialogDetector.isPlaceholderOption("15"))
        XCTAssertTrue(DialogDetector.isPlaceholderOption("14"))
        XCTAssertTrue(DialogDetector.isPlaceholderOption("9"))
        XCTAssertTrue(DialogDetector.isPlaceholderOption(" 7 "))
        // 有文字的不算占位。
        XCTAssertFalse(DialogDetector.isPlaceholderOption("抽奖(0)"))
        XCTAssertFalse(DialogDetector.isPlaceholderOption("任务徽章 4"))
    }

    /// 超长整句（说明性长文案）被滤掉，不占用选项名额。
    func testLongTextButtonIsFiltered() {
        let long = "查看本次活动规则以及奖励发放说明与常见问题"
        XCTAssertTrue(long.count > DialogDetector.optionTextMaxLength)
        XCTAssertTrue(DialogDetector.isPlaceholderOption(long))
        XCTAssertEqual(DialogDetector.buildSnapshot(title: "活动", buttons: [long, "关闭"])?.options,
                       ["关闭"])
    }

    /// 只有占位按钮的弹层 => 过滤后 0 个有效选项 => nil。
    func testDialogWithOnlyPlaceholderButtonsIsRejected() {
        XCTAssertNil(DialogDetector.buildSnapshot(title: "抽奖", buttons: ["15", "14", "9", "8"]))
    }

    /// 空壳弹层（弹层关掉后 Chromium 留下的 0 按钮 dialog）必须返回 nil，
    /// 绝不能因为「0 ≤ 阈值」就被当成合法选择框。
    func testEmptyShellDialogWithZeroButtonsYieldsNil() {
        XCTAssertNil(DialogDetector.buildSnapshot(title: "成长计划", buttons: []))
    }

    // MARK: - 标题上屏

    /// 标题超过 8 个字符截断加 `…`（Touch Bar 放不下长标题）。
    func testDisplayTitleTruncatesLongTitle() {
        XCTAssertEqual(DialogDetector.displayTitle("成长计划"), "成长计划")
        XCTAssertEqual(DialogDetector.displayTitle("十二三四五六七八九十"), "十二三四五六七八…")
    }

    /// 空标题上屏时用兜底文案（不允许出现 `❓` 后面什么都没有）。
    func testDisplayTitleFallsBackWhenEmpty() {
        XCTAssertEqual(DialogDetector.displayTitle(""), DialogDetector.fallbackTitle)
        XCTAssertEqual(DialogDetector.displayTitle("   "), DialogDetector.fallbackTitle)
    }

    // MARK: - 状态机：弹层优先

    /// 弹层存在时直接进入 `.choice`，哪怕库里还有 pending 任务。
    func testStateMachinePrefersChoiceOverPending() {
        let pending = TaskInfo(id: "p1", title: "待确认的任务", status: .pending)
        let dialog = DialogSnapshot(title: "成长计划", options: ["关闭", "奖品", "抽奖(0)"])
        let state = TouchBarStateMachine.reduce([pending], dialog: dialog)
        XCTAssertEqual(state, .choice(title: "成长计划", options: ["关闭", "奖品", "抽奖(0)"]))
        XCTAssertTrue(state.tasks.isEmpty)
        XCTAssertFalse(state.isIdle)
    }

    /// 弹层 + 进行中任务：弹层仍然赢。
    func testStateMachinePrefersChoiceOverWorking() {
        let working = TaskInfo(id: "w1", title: "正在跑的会话", status: .working)
        let dialog = DialogSnapshot(title: "抽奖", options: ["抽奖(0)"])
        XCTAssertEqual(TouchBarStateMachine.reduce([working], dialog: dialog),
                       .choice(title: "抽奖", options: ["抽奖(0)"]))
    }

    /// 回归：`dialog: nil` 时行为与改造前完全一致。
    func testStateMachineWithoutDialogIsUnchanged() {
        let pending = TaskInfo(id: "p1", title: "待确认", status: .pending)
        let working = TaskInfo(id: "w1", title: "进行中", status: .working)
        XCTAssertEqual(TouchBarStateMachine.reduce([]), .idle)
        XCTAssertEqual(TouchBarStateMachine.reduce([pending], dialog: nil), .pending(tasks: [pending]))
        XCTAssertEqual(TouchBarStateMachine.reduce([working], dialog: nil), .working(tasks: [working]))
    }

    /// `.choice` 态的概要文案与其他派生属性。
    func testChoiceStateDerivedProperties() {
        let state = TouchBarState.choice(title: "成长计划", options: ["关闭", "奖品"])
        XCTAssertEqual(state.choice?.title, "成长计划")
        XCTAssertEqual(state.choice?.options, ["关闭", "奖品"])
        XCTAssertTrue(state.tasks.isEmpty)
        XCTAssertFalse(state.isIdle)
        XCTAssertTrue(state.summaryLabel.contains("待选择"))
    }

    /// 非 choice 态下 `choice` 必须为 nil（否则 Touch Bar 会误判要铺选项）。
    func testNonChoiceStatesHaveNilChoice() {
        XCTAssertNil(TouchBarState.idle.choice)
        XCTAssertNil(TouchBarState.pending(tasks: []).choice)
    }

    // MARK: - 黑名单常量

    /// 黑名单内容必须钉死：删掉任何一项都等于放开了一个高危操作。
    func testDangerListContents() {
        for word in ["退出登录", "关机", "重新启动", "强制退出", "删除账号", "注销"] {
            XCTAssertTrue(DialogDetector.dangerOptions.contains(word), "黑名单缺少 \(word)")
        }
        XCTAssertTrue(DialogDetector.containsDanger("确认退出登录"))
        XCTAssertFalse(DialogDetector.containsDanger("取消"))
        XCTAssertFalse(DialogDetector.containsDanger("关闭"))
    }

    /// 只认三种弹层容器 —— 常量被改了等于把普通页面误判成弹层。
    func testDialogContainerConstants() {
        XCTAssertEqual(DialogDetector.dialogSubrole, "AXApplicationDialog")
        XCTAssertEqual(DialogDetector.dialogRoles, ["AXSheet", "AXDialog"])
        XCTAssertEqual(DialogDetector.optionLimit, 3)
    }

    /// V9 前置采样：权限弹窗的原文必须在任何过滤之前就能拿到，且解析结果不受采样影响。
    func testPermissionSnapshotKeepsRawTextForV9Sampling() {
        let snapshot = DialogDetector.buildSnapshot(
            title: "允许完全访问",
            buttons: ["允许", "取消"],
            checkboxes: [("文件操作", false), ("终端命令", true)]
        )
        XCTAssertEqual(snapshot?.title, "允许完全访问")
        XCTAssertEqual(snapshot?.permissions?.items.count, 2)
        XCTAssertEqual(snapshot?.permissions?.items.first?.label, "文件操作")
    }
}

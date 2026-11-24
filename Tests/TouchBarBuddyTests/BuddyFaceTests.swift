import XCTest
import AppKit
@testable import TouchBarBuddy

/// `BuddyFace` 的纯函数部分单测：状态→脸映射、失败覆盖、过渡选择、摘要文案裁剪。
///
/// 为什么这些必须钉死：
/// - 映射漏一个状态，那张脸就永远不出现（且编译期不会报错，`switch` 里 default 兜住了）；
/// - 「失败覆盖」判反了，出错的瞬间用户看到的是「还有 2 个任务进行中」，等于没提示；
/// - 摘要文案裁错了（比如把状态词当图标删掉），Touch Bar 上会只剩一个数字。
final class BuddyFaceTests: XCTestCase {

    /// 五个状态各自映射到唯一的脸，且 `.failed` 不由状态产生。
    func testBuddyFaceMapsEveryState() {
        XCTAssertEqual(TouchBarState.idle.buddyFace, BuddyFace.idle)
        XCTAssertEqual(TouchBarState.working(tasks: []).buddyFace, BuddyFace.running)
        XCTAssertEqual(TouchBarState.pending(tasks: []).buddyFace, BuddyFace.waiting)
        XCTAssertEqual(TouchBarState.unread(tasks: []).buddyFace, BuddyFace.done)
    }

    /// `.choice`（弹层正等我点选项）归到 `waiting` —— 用户视角与「待确认」是同一件事。
    func testChoiceMapsToWaiting() {
        let state = TouchBarState.choice(title: "是否继续", options: ["继续", "取消"])
        XCTAssertEqual(state.buddyFace, BuddyFace.waiting)
        XCTAssertEqual(state.buddyFace, TouchBarState.pending(tasks: []).buddyFace)
    }

    /// 五张脸都有 emoji，且互不重复（重复等于两种情绪长得一样）。
    func testEveryFaceHasDistinctEmoji() {
        XCTAssertEqual(BuddyFace.allCases.count, 5)
        let emojis = BuddyFace.allCases.map { $0.emoji }
        XCTAssertEqual(Set(emojis).count, 5)
        for emoji in emojis {
            XCTAssertFalse(emoji.isEmpty)
        }
    }

    /// 有失败提示时，脸固定为 `.failed`，压过状态脸（出错这 2 秒比「还有几个任务」更该被看见）。
    func testFailureOverridesStateFace() {
        XCTAssertEqual(BuddyFace.resolve(state: .idle, hasFailure: true), BuddyFace.failed)
        XCTAssertEqual(BuddyFace.resolve(state: .working(tasks: []), hasFailure: true),
                       BuddyFace.failed)
        XCTAssertEqual(BuddyFace.resolve(state: .working(tasks: []), hasFailure: false),
                       BuddyFace.running)
    }

    /// 只有「完成」和「失败」值得播动效，其它切换返回 nil（否则每几秒抽一下）。
    func testTransitionOnlyForDoneAndFailed() {
        XCTAssertEqual(BuddyFace.done.transition(from: .running), BuddyFaceTransition.celebrate)
        XCTAssertEqual(BuddyFace.failed.transition(from: .running), BuddyFaceTransition.console)
        XCTAssertNil(BuddyFace.running.transition(from: .idle))
        XCTAssertNil(BuddyFace.waiting.transition(from: .running))
        XCTAssertNil(BuddyFace.idle.transition(from: .done))
    }

    /// 脸没变化时不播动效（这是「每 3 秒重建一次却不抖」的关键）。
    func testNoTransitionWhenFaceUnchanged() {
        XCTAssertNil(BuddyFace.done.transition(from: .done))
        XCTAssertNil(BuddyFace.failed.transition(from: .failed))
        XCTAssertNil(BuddyFace.idle.transition(from: .idle))
    }

    /// 「点击确认」是独立的一种过渡，不能和庆祝 / 失败混淆。
    ///
    /// 三条互斥很重要：庆祝是缩放、失败是红字、确认是青绿字 ——
    /// 若 `acknowledge` 比较时等于其中任何一个，`rebuildTouchBar()` 里的覆盖判断
    /// 和 delegate 的「消费后清 flag」都会认错，表现为该播的不播、不该播的连播。
    func testAcknowledgeTransitionIsDistinct() {
        XCTAssertEqual(BuddyFaceTransition.acknowledge, BuddyFaceTransition.acknowledge)
        XCTAssertTrue(BuddyFaceTransition.acknowledge != BuddyFaceTransition.celebrate)
        XCTAssertTrue(BuddyFaceTransition.acknowledge != BuddyFaceTransition.console)
        XCTAssertTrue(BuddyFaceTransition.celebrate != BuddyFaceTransition.console)
    }

    /// 确认动效**只能**由点击成功排队，绝不由「脸变了」自动产生。
    ///
    /// 钉住这条是因为两种动效的入口完全不同：庆祝/失败走 `transition(from:)`，
    /// 确认走 `queueAcknowledgement()`。若哪天有人顺手把它加进 `transition(from:)`，
    /// 每次切状态都会绿一下，用户会以为按钮被自己按了。
    func testAcknowledgeNeverProducedByFaceChange() {
        for current in BuddyFace.allCases {
            for previous in BuddyFace.allCases {
                XCTAssertTrue(current.transition(from: previous) != .acknowledge,
                              "\(current) ← \(previous) 不该产生确认动效")
            }
        }
    }

    /// 摘要文案去掉开头的状态 emoji（情绪脸已经表达了同一件事，且 emoji 吃掉约 18pt）。
    func testSummaryTitleStripsLeadingStatusEmoji() {
        XCTAssertEqual(TouchBarItemFactory.summaryTitle(for: .idle), "空闲")
        XCTAssertEqual(TouchBarItemFactory.summaryTitle(for: .working(tasks: [])), "0 进行中")
        XCTAssertEqual(TouchBarItemFactory.summaryTitle(for: .choice(title: "是否继续",
                                                                    options: ["继续", "取消"])),
                       "待选择 是否继续(2)")
    }

    /// 裁剪只删图标，**状态词必须留下**（`.pending` / `.unread` 的图标也是单字符）。
    func testSummaryTitleKeepsStateWordAfterIcon() {
        XCTAssertEqual(TouchBarItemFactory.summaryTitle(for: .unread(tasks: [])), "0 待读")
        XCTAssertEqual(TouchBarItemFactory.summaryTitle(for: .pending(tasks: [])), "0 待确认")
    }

    // MARK: - V25 卡住状态可读化

    /// 「超过阈值」才换文案：121 秒写「疑似卡住」，119 / 无数据保持「进行中」。
    ///
    /// 这条同时验证了新文案走的是同一条「去 leading emoji」路径：
    /// 「⚠️ N 疑似卡住」被裁成「N 疑似卡住」，不会把 ⚠️ 留在 Touch Bar 上占宽度。
    func testSummaryTitleShowsStaleForFocusedTask() {
        let stale = TaskInfo(id: "s", title: "S", status: .working, activityAge: 121)
        let fresh = TaskInfo(id: "f", title: "F", status: .working, activityAge: 119)
        let noData = TaskInfo(id: "n", title: "N", status: .working, activityAge: nil)

        XCTAssertEqual(TouchBarItemFactory.summaryTitle(for: .working(tasks: [stale])), "1 疑似卡住")
        XCTAssertEqual(TouchBarItemFactory.summaryTitle(for: .working(tasks: [fresh])), "1 进行中")
        XCTAssertEqual(TouchBarItemFactory.summaryTitle(for: .working(tasks: [noData])), "1 进行中")
    }

    /// 阈值边界：严格 `>`，120 秒不算卡住（和橙色判据 `seconds > 120` 一致）。
    ///
    /// 两处判据必须一致，否则会出现「时长已经橙了、摘要还写进行中」这种自相矛盾的界面。
    func testTaskInfoIsStaleBoundary() {
        XCTAssertFalse(TaskInfo(id: "a", title: "A", status: .working, activityAge: nil).isStale)
        XCTAssertFalse(TaskInfo(id: "b", title: "B", status: .working, activityAge: 119).isStale)
        XCTAssertFalse(TaskInfo(id: "c", title: "C", status: .working, activityAge: 120).isStale)
        XCTAssertTrue(TaskInfo(id: "d", title: "D", status: .working, activityAge: 121).isStale)
    }

    /// 看的是**聚焦的那一条**，不是「随便哪条卡住」；下标要 clamp 到合法范围。
    func testSummaryTitleUsesClampedFocusedIndex() {
        let fresh = TaskInfo(id: "f", title: "F", status: .working, activityAge: 5)
        let stale = TaskInfo(id: "s", title: "S", status: .working, activityAge: 300)
        let state = TouchBarState.working(tasks: [fresh, stale])

        XCTAssertEqual(TouchBarItemFactory.summaryTitle(for: state, focusedIndex: 0), "2 进行中")
        XCTAssertEqual(TouchBarItemFactory.summaryTitle(for: state, focusedIndex: 1), "2 疑似卡住")
        // 越界下标按 `min(max(i, 0), count-1)` 收敛，不能崩、也不能误判成另一条。
        XCTAssertEqual(TouchBarItemFactory.summaryTitle(for: state, focusedIndex: 99), "2 疑似卡住")
        XCTAssertEqual(TouchBarItemFactory.summaryTitle(for: state, focusedIndex: -3), "2 进行中")
    }

    /// 这次只改摘要文案，时长显示保持用户要的秒级可读版本，不能被顺手改掉。
    func testAgeTextFormatUnchangedByStaleWork() {
        XCTAssertEqual(ActivityAge.formatActivityAge(12), "12s")
        XCTAssertEqual(ActivityAge.formatActivityAge(0), "0s")
        XCTAssertEqual(ActivityAge.formatActivityAge(60), "1m0s")
    }

    /// 新文案比「N 进行中」多两个字，必须实测确认没有越过 100pt 预算。
    ///
    /// 用真正的 `SummaryBarView` 量，而不是照字体手算 —— 内边距、间隙、
    /// `lineBreakMode` 都参与最终 intrinsic 宽度，手算容易漏。
    func testStaleSummaryTitleFitsWidthBudget() {
        let stale = TaskInfo(id: "s", title: "S", status: .working, activityAge: 121)
        let title = TouchBarItemFactory.summaryTitle(for: .working(tasks: [stale]))
        let view = SummaryBarView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
        view.update(title: title, face: .running)

        XCTAssertEqual(title, "1 疑似卡住")
        XCTAssertTrue(view.intrinsicContentSize.width <= SummaryBarView.maxWidth,
                      "摘要宽 \(view.intrinsicContentSize.width) 超过 \(SummaryBarView.maxWidth)pt")
    }
}

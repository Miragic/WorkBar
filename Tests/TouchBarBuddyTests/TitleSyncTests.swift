import XCTest
import AppKit
@testable import TouchBarBuddy

/// 多任务轮询时「标题」必须与「详情」来自同一个 focusedIndex（用户 2026-11-20 bug）：
/// 详情每 3 秒就地刷新会切到新任务，而标题只在 rebuildTouchBar 时设置，于是卡在旧任务。
final class TitleSyncTests: XCTestCase {

    private func makeTasks() -> [TaskInfo] {
        [
            TaskInfo(id: "t0", title: "任务甲", status: .working,
                     model: "m0", activityAge: 12, contextUsage: 0.11),
            TaskInfo(id: "t1", title: "任务乙", status: .pending,
                     model: "m1", activityAge: 12, contextUsage: 0.22),
            TaskInfo(id: "t2", title: "任务丙", status: .working,
                     model: "m2", activityAge: 12, contextUsage: 0.33),
        ]
    }

    /// 展开态：focusedIndex 0→1→2，每次 updateTitle 后标题含对应任务与正确序号，
    /// 且详情渲染来自同一 index（含本任务独有百分比，不含其它任务的）。
    func testTitleAndDetailShareFocusedIndex() {
        let tasks = makeTasks()
        let view = TaskStripView(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        view.update(title: "", activityAge: 12, elapsed: nil, expanded: true, meta: nil)

        for (i, task) in tasks.enumerated() {
            // 与 makeTaskItem / refreshActivityAgeInPlace 完全相同的生成路径。
            view.updateTitle(TouchBarItemFactory.taskText(task: task, index: i, total: tasks.count))
            let meta = TouchBarItemFactory.taskMetaRendering(
                task: task, elapsed: nil, maxWidth: nil, graphicRing: false)
            view.updateExpandedMeta(meta.attributed, rendering: meta)

            XCTAssertTrue(view.label.stringValue.contains(task.title),
                          "第 \(i) 项标题应含 \(task.title)，实际 \(view.label.stringValue)")
            XCTAssertTrue(view.label.stringValue.contains("(\(i + 1)/\(tasks.count))"),
                          "第 \(i) 项序号应为 (\(i + 1)/\(tasks.count))，实际 \(view.label.stringValue)")

            let detail = view.metaLabel.attributedStringValue.string
            let mine = ContextUsage.format(task.contextUsage, graphic: false)!
            XCTAssertTrue(detail.contains(mine),
                          "详情应含该任务上下文 \(mine)，实际 \(detail)")
            for (j, other) in tasks.enumerated() where j != i {
                let otherPct = ContextUsage.format(other.contextUsage, graphic: false)!
                XCTAssertFalse(detail.contains(otherPct),
                               "详情不应残留任务 \(j) 的 \(otherPct)，实际 \(detail)")
            }
        }
    }

    /// 紧凑态：即便未展开详情，标题也必须随 focusedIndex 切换（updateTitle 不包在展开判断里）。
    func testTitleSyncsInCompactModeWithoutDetail() {
        let tasks = makeTasks()
        let view = TaskStripView(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        view.update(title: "", activityAge: 12, expanded: false)

        for (i, task) in tasks.enumerated() {
            view.updateTitle(TouchBarItemFactory.taskText(task: task, index: i, total: tasks.count))
            XCTAssertTrue(view.label.stringValue.contains(task.title),
                          "紧凑态第 \(i) 项标题应含 \(task.title)，实际 \(view.label.stringValue)")
            XCTAssertTrue(view.label.stringValue.contains("(\(i + 1)/\(tasks.count))"))
            XCTAssertTrue(view.metaLabel.isHidden, "紧凑态不该显示详情第二行")
            XCTAssertTrue(abs(view.label.font!.pointSize - 13) < 0.01, "紧凑标题应是 13pt")
            XCTAssertTrue(view.label.alignment == .center, "紧凑标题应居中")
        }
    }
}

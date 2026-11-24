import XCTest
import AppKit
@testable import TouchBarBuddy

/// V13 步骤进度条：夹紧、宽度预算、开关、与圆环不重叠、就地刷新。
/// 只测可由离屏 frame / 纯函数验证的部分；真机视觉由 team-lead 验证。
final class StepProgressTests: XCTestCase {

    private func makeTask(model: String? = "hy4std",
                          step: TaskStepProgress?,
                          context: Double = 0.53) -> TaskInfo {
        TaskInfo(id: "t", title: "T", status: .working, model: model,
                 activityAge: 12, contextUsage: context, stepProgress: step)
    }

    private func rendering(_ task: TaskInfo,
                           maxWidth: CGFloat? = 196,
                           graphic: Bool = true,
                           showStep: Bool = true) -> TouchBarItemFactory.TaskMetaRendering {
        TouchBarItemFactory.taskMetaRendering(task: task, elapsed: 12,
                                              maxWidth: maxWidth, graphicRing: graphic,
                                              showTaskStep: showStep)
    }

    private func strip() -> TaskStripView {
        TaskStripView(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
    }

    /// 进度比例夹紧：0 / 0.5 / 1 / 超上界 / 超下界。
    func testProgressClamps() {
        let view = StepProgressView(frame: NSRect(x: 0, y: 0,
                                                  width: StepProgressView.barWidth,
                                                  height: StepProgressView.barHeight))
        XCTAssertFalse(view.isOpaque)
        for (input, expected) in [(0.0, 0.0), (0.5, 0.5), (1.0, 1.0),
                                  (1.4, 1.0), (-0.2, 0.0)] {
            view.progress = input
            XCTAssertTrue(abs(view.progress - expected) < 1e-9,
                          "\(input) 应夹到 \(expected)，实际 \(view.progress)")
        }
    }

    /// TaskStep.progress 与 segmentText 同源：步数不足返回 nil，done 越界被夹紧。
    func testTaskStepProgressSharesValidityRule() {
        XCTAssertNil(TaskStep.progress(nil))
        XCTAssertNil(TaskStep.progress(TaskStepProgress(total: 1, done: 1, current: nil)))
        XCTAssertTrue(abs(TaskStep.progress(TaskStepProgress(total: 8, done: 3, current: nil))! - 0.375) < 1e-9)
        XCTAssertTrue(abs(TaskStep.progress(TaskStepProgress(total: 8, done: 99, current: nil))! - 1.0) < 1e-9)
        XCTAssertTrue(abs(TaskStep.progress(TaskStepProgress(total: 8, done: -1, current: nil))! - 0.0) < 1e-9)
    }

    /// 进度条的真实宽度计入裁剪预算：图形模式下 prefix + ring + gap + bar + gap + suffix ≤ 196。
    func testProgressBarIsInWidthBudget() {
        let step = TaskStepProgress(total: 37, done: 12, current: "核实粉丝数")
        let task = makeTask(model: String(repeating: "W", count: 40), step: step)
        let meta = rendering(task, maxWidth: 196)
        guard let prefix = meta.prefix, let suffix = meta.suffix else {
            return XCTFail("图形模式应切出 prefix / suffix")
        }
        let total = TaskStripView.metaFieldWidth(prefix)
            + ContextRingView.side + TaskStripView.contextRingGap
            + StepProgressView.barWidth + TaskStripView.contextRingGap
            + TaskStripView.metaFieldWidth(suffix)
        XCTAssertTrue(total <= 196, "含进度条的总宽应 ≤ 196，实际 \(total)")
        XCTAssertTrue(abs((meta.stepProgressRatio ?? -1) - 12.0 / 37.0) < 1e-9)
        XCTAssertTrue(meta.stepProgressOffsetX != nil, "渲染结果应携带进度条偏移")
        XCTAssertTrue(meta.stepProgressOffsetX! >= (meta.ringOffsetX ?? 0),
                      "进度条排在圆环之后，偏移不小于圆环偏移")
    }

    /// showTaskStep 关闭（或任务无步骤）→ 不显示进度条，也不显示步骤文案。
    func testShowTaskStepOffHidesProgress() {
        let step = TaskStepProgress(total: 8, done: 3, current: "核实粉丝数")
        for meta in [rendering(makeTask(step: step), showStep: false),
                     rendering(makeTask(step: nil))] {
            XCTAssertNil(meta.stepProgressRatio)
            XCTAssertFalse(meta.attributed.string.contains("3/8"))
            let view = strip()
            view.update(title: "T", activityAge: 12, elapsed: 12,
                        expanded: true, rendering: meta)
            view.layoutSubtreeIfNeeded()
            XCTAssertTrue(view.stepProgressView.isHidden)
        }
    }

    /// 进度条与圆环、文字不重叠，且三段都在容器内。
    func testProgressBarDoesNotOverlapRingOrText() {
        // 长模型会在裁剪时被丢掉，步骤段（带进度）保留 —— 正好验证「丢模型不丢进度条」。
        let step = TaskStepProgress(total: 37, done: 35, current: "核实粉丝数")
        let task = makeTask(model: "deepseek-v4.1-flash", step: step, context: 0.8)
        let meta = rendering(task, maxWidth: 196)
        let view = strip()
        view.update(title: "T", activityAge: 12, elapsed: 12,
                    expanded: true, rendering: meta)
        view.layoutSubtreeIfNeeded()

        XCTAssertFalse(view.ringView.isHidden)
        XCTAssertFalse(view.stepProgressView.isHidden)
        XCTAssertTrue(view.metaPrefixLabel.frame.maxX <= view.ringView.frame.minX)
        XCTAssertTrue(view.ringView.frame.maxX <= view.stepProgressView.frame.minX)
        let rightEdge = max(view.ringView.frame.maxX, view.stepProgressView.frame.maxX)
        XCTAssertTrue(view.metaSuffixLabel.frame.minX >= rightEdge + TaskStripView.contextRingGap)
        XCTAssertTrue(view.metaPrefixLabel.frame.minX >= view.bounds.minX)
        XCTAssertTrue(view.metaSuffixLabel.frame.maxX <= view.bounds.maxX)
        XCTAssertTrue(view.stepProgressView.frame.maxX <= view.bounds.maxX)
        XCTAssertEqual(view.stepProgressView.frame.width, StepProgressView.barWidth)
        XCTAssertEqual(view.stepProgressView.frame.height, StepProgressView.barHeight)
    }

    /// 反复就地刷新：比例跟着走，后缀始终让开进度条（积分 / 百分比跨位也不重叠）。
    func testRepeatedInPlaceRefreshUpdatesProgress() {
        let view = strip()
        let initial = rendering(makeTask(step: TaskStepProgress(total: 8, done: 0, current: nil)))
        view.update(title: "T", activityAge: 12, elapsed: 12,
                    expanded: true, rendering: initial)
        for done in [0, 1, 3, 7, 8] {
            let meta = rendering(makeTask(step: TaskStepProgress(total: 8, done: done, current: "x")))
            view.updateExpandedMeta(meta.attributed, rendering: meta)
            view.layoutSubtreeIfNeeded()
            XCTAssertFalse(view.stepProgressView.isHidden)
            XCTAssertTrue(abs(view.stepProgressView.progress - Double(done) / 8.0) < 1e-9)
            XCTAssertTrue(view.metaSuffixLabel.frame.minX >= view.stepProgressView.frame.maxX + 3)
            XCTAssertTrue(view.stepProgressView.frame.maxX <= view.bounds.maxX)
        }
    }

    /// 字符模式（无圆环）进度条仍显示，排在整行文字之后且不越界。
    func testCharacterModeShowsProgressAfterText() {
        let meta = rendering(makeTask(step: TaskStepProgress(total: 8, done: 3, current: nil)),
                             graphic: false)
        let view = strip()
        view.update(title: "T", activityAge: 12, elapsed: 12,
                    expanded: true, rendering: meta)
        view.layoutSubtreeIfNeeded()
        XCTAssertTrue(view.ringView.isHidden)
        XCTAssertFalse(view.metaLabel.isHidden)
        XCTAssertFalse(view.stepProgressView.isHidden)
        XCTAssertTrue(view.stepProgressView.frame.minX >= view.metaLabel.frame.minX)
        XCTAssertTrue(view.stepProgressView.frame.maxX <= view.bounds.maxX)
    }
}

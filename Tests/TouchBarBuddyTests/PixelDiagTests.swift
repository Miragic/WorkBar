import XCTest
import AppKit
@testable import TouchBarBuddy

/// 真实视图 frame 回归，不创建窗口、不生成诊断图片。
final class PixelDiagTests: XCTestCase {
    private func rendering(credits: Double, ratio: Double = 0.328,
                           graphic: Bool = true) -> TouchBarItemFactory.TaskMetaRendering {
        let task = TaskInfo(id: "t1", title: "T", status: .working,
                            model: "custom-local:deepseek-v4.1-flash",
                            modelDisplayName: "非常长的模型名称 DeepSeek V4.1 Flash",
                            activityAge: 12, contextUsage: ratio, stepProgress: nil)
        return TouchBarItemFactory.taskMetaRendering(task: task, elapsed: 3780,
            maxWidth: 196, graphicRing: graphic, credits: credits)
    }

    private func assertSeparated(_ view: TaskStripView) {
        view.layoutSubtreeIfNeeded()
        XCTAssertFalse(view.ringView.isHidden)
        XCTAssertTrue(view.metaLabel.isHidden, "图形模式不能叠在整行文字上")
        XCTAssertFalse(view.metaPrefixLabel.isHidden)
        XCTAssertFalse(view.metaSuffixLabel.isHidden)
        XCTAssertTrue(view.metaPrefixLabel.superview === view)
        XCTAssertTrue(view.metaSuffixLabel.superview === view)
        XCTAssertTrue(view.ringView.superview === view)
        XCTAssertEqual(view.ringView.frame.width, 10)
        XCTAssertEqual(view.ringView.frame.height, 10)
        XCTAssertTrue(view.metaPrefixLabel.frame.maxX <= view.ringView.frame.minX)
        XCTAssertTrue(view.metaSuffixLabel.frame.minX >= view.ringView.frame.maxX + 3)
        XCTAssertTrue(view.metaSuffixLabel.frame.maxX <= view.bounds.maxX - 2)
        let cellBounds = view.metaSuffixLabel.cell!.drawingRect(forBounds: view.metaSuffixLabel.bounds)
        let actualTextBounds = view.metaSuffixLabel.convert(cellBounds, to: view)
        XCTAssertTrue(actualTextBounds.minX >= view.ringView.frame.maxX + 3)
        XCTAssertTrue(view.metaSuffixLabel.frame.width >= TaskStripView.metaFieldWidth(view.metaSuffixLabel.attributedStringValue))
    }

    func testLongCreditsAndMultiDigitPercentHaveSeparateFrames() {
        for credits in [9.99, 99.99, 999.99, 161421.00, 1614210.00] {
            for ratio in [0.032, 0.328, 0.999, 1.0] {
                let meta = rendering(credits: credits, ratio: ratio)
                let view = TaskStripView(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
                view.update(title: "T", activityAge: 12, expanded: true, rendering: meta)
                assertSeparated(view)
                XCTAssertTrue(view.metaSuffixLabel.stringValue.hasPrefix(ContextUsage.format(ratio, graphic: true)!))
                let total = TaskStripView.metaFieldWidth(meta.prefix!) + 13 + TaskStripView.metaFieldWidth(meta.suffix!)
                XCTAssertTrue(total <= 196, "裁剪预算必须包含真实文本框尺寸与圆环")
            }
        }
    }

    func testRepeatedRefreshCreditDigitChangesAndModeSwitches() {
        let view = TaskStripView(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        view.update(title: "T", activityAge: 12, expanded: true, rendering: rendering(credits: 9.99))
        for credits in [99.99, 999.99, 161421.00, 9.99, 1614210.00] {
            let meta = rendering(credits: credits)
            view.updateExpandedMeta(meta.attributed, rendering: meta)
            assertSeparated(view)
            let character = rendering(credits: credits, graphic: false)
            view.updateExpandedMeta(character.attributed, rendering: character)
            XCTAssertTrue(view.ringView.isHidden)
            XCTAssertTrue(view.metaPrefixLabel.isHidden)
            XCTAssertTrue(view.metaSuffixLabel.isHidden)
            XCTAssertFalse(view.metaLabel.isHidden)
            XCTAssertEqual(view.metaLabel.stringValue, character.attributed.string)
            view.updateExpandedMeta(meta.attributed, rendering: meta)
            assertSeparated(view)
        }
        let warning = rendering(credits: 161421, ratio: 0.8)
        view.updateExpandedMeta(warning.attributed, ringTint: .systemOrange, rendering: warning)
        assertSeparated(view)
        XCTAssertEqual(view.ringView.ratio, 0.8)
        XCTAssertTrue(view.ringView.tint.isEqual(NSColor.systemOrange))
        let color = view.metaSuffixLabel.attributedStringValue.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertTrue(color?.isEqual(NSColor.systemOrange) == true)
        view.setFrameSize(NSSize(width: 130, height: 30))
        view.needsLayout = true
        assertSeparated(view)
        view.update(title: "T", activityAge: nil, expanded: false)
        XCTAssertTrue(view.ringView.isHidden)
        XCTAssertTrue(view.metaPrefixLabel.isHidden)
        XCTAssertTrue(view.metaSuffixLabel.isHidden)
    }
}

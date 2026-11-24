import XCTest
import AppKit
@testable import TouchBarBuddy

/// 「任务详情展开/收起」（PRD P1-2）的纯函数与布局高度单测。
///
/// 只测两件**能被自动化验证**的事：第二行文案怎么拼、两行加起来会不会超过 30pt。
/// 「点一下是否真的切换」依赖 Touch Bar 触摸，只能真机验证。
final class TaskDetailTests: XCTestCase {

    private func makeTask(status: TaskStatus = .working,
                          model: String? = "hy4std",
                          modelDisplayName: String? = nil,
                          activityAge: TimeInterval? = 12,
                          contextUsage: Double? = nil,
                          stepProgress: TaskStepProgress? = nil) -> TaskInfo {
        TaskInfo(id: "t1",
                 title: "写一个 Touch Bar 工具",
                 status: status,
                 model: model,
                 modelDisplayName: modelDisplayName,
                 activityAge: activityAge,
                 contextUsage: contextUsage,
                 stepProgress: stepProgress)
    }

    /// 三段齐全：`状态 · 模型名 · 时长`。
    func testTaskMetaTextWithAllSegments() {
        let task = makeTask()
        XCTAssertEqual(TouchBarItemFactory.taskMetaText(task: task, elapsed: 12),
                       "进行中 · 混元 4 · 12s")
    }

    /// 模型为空 → 整段省略，不留 `进行中 ·  · 12s` 这种空段。
    func testTaskMetaTextSkipsEmptyModel() {
        let task = makeTask(model: nil)
        XCTAssertEqual(TouchBarItemFactory.taskMetaText(task: task, elapsed: 12), "进行中 · 12s")
    }

    /// 时长未知（elapsed 为 nil 且没有 activityAge）→ 省略时长段。
    func testTaskMetaTextSkipsMissingElapsed() {
        let task = makeTask()
        XCTAssertEqual(TouchBarItemFactory.taskMetaText(task: task, elapsed: nil),
                       "进行中 · 混元 4")
    }

    /// 无任务 → 空串，第二行留空（不显示「未知 · …」这种噪音）。
    func testTaskMetaTextWithoutTaskIsEmpty() {
        XCTAssertEqual(TouchBarItemFactory.taskMetaText(task: nil, elapsed: 12), "")
    }

    /// 五种状态的中文短名，且 `active` 与 `working` 同义（都是「进行中」）。
    func testTaskMetaStatusText() {
        XCTAssertEqual(TouchBarItemFactory.statusText(.working), "进行中")
        XCTAssertEqual(TouchBarItemFactory.statusText(.active), "进行中")
        XCTAssertEqual(TouchBarItemFactory.statusText(.pending), "待确认")
        XCTAssertEqual(TouchBarItemFactory.statusText(.completed), "已完成")
        XCTAssertEqual(TouchBarItemFactory.statusText(.archived), "已归档")
        XCTAssertEqual(TouchBarItemFactory.statusText(.unknown), "未知")
    }

    /// 两行高度之和必须 ≤ 容器高度，否则第二行会被 Touch Bar 切掉。
    ///
    /// 同时覆盖几个非常规高度（视图被系统拉伸时可能不是 30），保证函数不会算出负数。
    func testExpandedRowHeightsFitInContainer() {
        for height in [CGFloat(24), 30, 32] {
            let rows = TaskStripView.expandedRowHeights(boundsHeight: height)
            XCTAssertTrue(rows.title > 0, "\(height)pt 下标题行高度必须为正")
            XCTAssertTrue(rows.meta > 0, "\(height)pt 下第二行高度必须为正")
            XCTAssertTrue(rows.title + rows.meta <= height,
                          "\(height)pt 下两行合计 \(rows.title + rows.meta) 超出容器")
        }
    }

    /// 紧凑视图的行高也不能超过容器（含 emoji 余量 8pt）。
    func testCompactTitleHeightStaysInsideContainer() {
        let barHeight: CGFloat = 30
        let line = TouchBarTextMetrics.textHeight(
            for: .systemFont(ofSize: TaskStripView.compactTitleFontSize)
        )
        let height = min(barHeight, line + TaskStripView.verticalSlack)
        XCTAssertTrue(height <= barHeight)
        XCTAssertTrue(height > 0)
    }

    /// 真·两行布局：两行 frame 都必须在 30pt 容器内，且互不重叠。
    ///
    /// 这是唯一能自动化发现「第二行跑到容器外被切掉」的方式 —— 纯高度函数对了，
    /// 但 y 算错（例如忘了减 title 高度）照样会重叠，只有断言 frame 才抓得到。
    func testExpandedLayoutKeepsRowsInsideBounds() {
        let barHeight: CGFloat = 30
        let view = TaskStripView(frame: NSRect(x: 0, y: 0, width: 200, height: barHeight))
        view.update(title: "🟢 一个挺长的任务标题用来验证截断",
                    activityAge: 12,
                    elapsed: 12,
                    expanded: true,
                    meta: NSAttributedString(string: "进行中 · 混元 4 · 12s"))

        XCTAssertTrue(view.isExpanded)

        let title = view.label.frame
        let meta = view.metaLabel.frame
        XCTAssertTrue(title.minY >= 0, "标题行跑出容器底部：\(title)")
        XCTAssertTrue(title.maxY <= barHeight + 0.5, "标题行超出容器顶部：\(title)")
        XCTAssertTrue(meta.minY >= 0, "第二行跑出容器底部：\(meta)")
        XCTAssertTrue(meta.maxY <= title.minY + 0.5, "两行重叠：meta=\(meta) title=\(title)")
        XCTAssertEqual(view.metaLabel.stringValue, "进行中 · 混元 4 · 12s")
    }

    // MARK: - 垂直居中几何（无边框 NSTextField 是顶部对齐绘制）

    /// 紧凑态：文字的**视觉中心**必须落在容器中心，而不是「框居中」。
    ///
    /// 用户反馈「文字和图标太靠上」。根因是旧实现 `y = (bounds - height)/2` 让框居中，
    /// 但文字画在框顶，视觉中心比容器中心高 4pt。这条用几何断言钉死。
    func testCompactTextVisualCenterMatchesContainerCenter() {
        let barHeight: CGFloat = 30
        let line = TouchBarTextMetrics.textHeight(for: .systemFont(ofSize: 13))
        let frame = TaskStripView.topAlignedTextFrame(bandCenter: barHeight / 2,
                                                            textHeight: line,
                                                            slack: 8,
                                                            boundsHeight: barHeight)
        // 顶部对齐：文字占据框顶的 line 高度，视觉中心 = 框顶 - line/2。
        let visualCenter = frame.y + frame.height - line / 2
        XCTAssertTrue(abs(visualCenter - barHeight / 2) < 0.01,
                      "视觉中心 \(visualCenter) 偏离容器中心 \(barHeight / 2)")
    }

    /// 详情态第一行：文字顶部不能贴到容器顶（贴顶就是「被切掉」）。
    func testExpandedTitleLeavesRoomAtTop() {
        let barHeight: CGFloat = 30
        let line = TouchBarTextMetrics.textHeight(for: .systemFont(ofSize: 12))
        let frame = TaskStripView.topAlignedTextFrame(bandCenter: barHeight * 0.66,
                                                            textHeight: line,
                                                            slack: 3,
                                                            boundsHeight: barHeight)
        let textTop = frame.y + frame.height
        XCTAssertTrue(textTop <= barHeight,
                      "第一行文字顶部 \(textTop) 超出容器 \(barHeight)")
        XCTAssertTrue(barHeight - textTop >= 2,
                      "第一行贴顶（仅剩 \(barHeight - textTop)pt），emoji 上沿会被切")
    }

    /// 任何文字行高下，返回的框都不得越界、不得出现负高度。
    func testTopAlignedFrameNeverExceedsContainer() {
        let barHeight: CGFloat = 30
        // line > barHeight 的输入不可能放进容器（例如 40pt 行高塞 30pt），
        // 那种情况本就无解，跳过 —— 这里钉的是「可容纳的输入不得越界」。
        for line: CGFloat in [10, 12, 13, 15, 16, 20, 28] {
            for ratio: CGFloat in [0.1, 0.25, 0.5, 0.66, 0.9] {
                let frame = TaskStripView.topAlignedTextFrame(
                    bandCenter: barHeight * ratio,
                    textHeight: line,
                    slack: 8,
                    boundsHeight: barHeight)
                XCTAssertTrue(frame.height > 0, "line=\(line) ratio=\(ratio) 高度为 0")
                XCTAssertTrue(frame.y >= 0, "line=\(line) ratio=\(ratio) y=\(frame.y) < 0")
                XCTAssertTrue(frame.y + frame.height <= barHeight + 0.01,
                              "line=\(line) ratio=\(ratio) 框顶 \(frame.y + frame.height) 越界")
            }
        }
    }

    // MARK: - 上下文占用（拼在第二行里）

    /// 取某段文字在富文本里的前景色；找不到该文本返回 nil。
    private func foregroundColor(of needle: String,
                                 in attributed: NSAttributedString) -> NSColor? {
        let range = (attributed.string as NSString).range(of: needle)
        guard range.location != NSNotFound else { return nil }
        return attributed.attribute(.foregroundColor,
                                    at: range.location,
                                    effectiveRange: nil) as? NSColor
    }

    /// 顺序必须是 `状态 · 模型 · 上下文 · 时长`：上下文排在时长之前，
    /// 否则尾部一截断就把它吃掉（它是这次新加的唯一信息）。
    func testTaskMetaIncludesContextUsageInOrder() {
        let task = makeTask(contextUsage: 0.53)
        let text = TouchBarItemFactory.taskMetaText(task: task, elapsed: 12)
        XCTAssertEqual(text, "进行中 · 混元 4 · ◒ 53.0% · 12s")
        XCTAssertTrue(text.hasSuffix("12s"), "时长必须仍在最后：\(text)")
    }

    /// 超 75% → 该段用 `.systemOrange`（警告色），且**只有**该段变色。
    func testTaskMetaContextUsesWarningColorWhenTight() {
        let task = makeTask(contextUsage: 0.80)
        let attributed = TouchBarItemFactory.taskMetaAttributedText(task: task,
                                                                   elapsed: 12,
                                                                   maxWidth: nil)
        // 环形符号是纯文本，`.string` 里完整保留。
        XCTAssertTrue(attributed.string.contains("80.0%"),
                      "警告态也要显示比例：\(attributed.string)")
        guard let color = foregroundColor(of: "80.0%", in: attributed) else {
            return XCTFail("找不到上下文段：\(attributed.string)")
        }
        XCTAssertTrue(color.isEqual(NSColor.systemOrange),
                      "超过阈值应为 systemOrange，实际为 \(color)")
        // 状态段仍是次要色 —— 整行变橙会让「橙色 = 卡住了」这个既有含义失效。
        guard let statusColor = foregroundColor(of: "进行中", in: attributed) else {
            return XCTFail("找不到状态段：\(attributed.string)")
        }
        XCTAssertFalse(statusColor.isEqual(NSColor.systemOrange),
                       "只有上下文段可以变橙，状态段不该变橙")
    }

    /// 未达阈值（53%）→ 上下文段**不**是警告色（正常情况它是安静的）。
    func testTaskMetaContextIsQuietBelowThreshold() {
        let task = makeTask(contextUsage: 0.53)
        let attributed = TouchBarItemFactory.taskMetaAttributedText(task: task,
                                                                   elapsed: 12,
                                                                   maxWidth: nil)
        guard let color = foregroundColor(of: "53.0%", in: attributed) else {
            return XCTFail("找不到上下文段：\(attributed.string)")
        }
        XCTAssertFalse(color.isEqual(NSColor.systemOrange),
                       "53% 不该用警告色，实际为 \(color)")
        XCTAssertTrue(color.isEqual(NSColor.secondaryLabelColor),
                      "常态应为 secondaryLabelColor，实际为 \(color)")
    }

    /// 宽度不够时**先缩短模型名**，而不是整段丢掉。
    ///
    /// 真机回归（2026-11-19）：`DeepSeek V4.1 Flash` 那一行实测 197.1pt、预算 196pt，
    /// 只超 1.1pt。旧逻辑直接丢整段模型，于是用户看到「运行时模型一会儿有一会儿没」。
    /// 现在应缩短成 `DeepSeek V4.1 …` 之类，仍然认得出是哪个模型。
    ///
    /// - Note: 换成圆环图标后这一行降到约 180.6pt，正常预算 196pt 已经放得下 ——
    ///   这正是换图标的额外收益。这里刻意把预算压到 175pt，继续守住「缩短而非丢弃」这条规则。
    func testTaskMetaShortensModelWhenTooNarrow() {
        let task = makeTask(model: "deepseek-v4.1-flash",
                            modelDisplayName: "DeepSeek V4.1 Flash",
                            contextUsage: 0.198)
        let attributed = TouchBarItemFactory.taskMetaAttributedText(task: task,
                                                                   elapsed: 12,
                                                                   maxWidth: 175)
        let text = attributed.string
        XCTAssertTrue(text.contains("DeepSeek"), "模型不该整段消失：\(text)")
        XCTAssertTrue(text.contains("…"), "被缩短的模型应带省略号：\(text)")
        XCTAssertFalse(text.contains("DeepSeek V4.1 Flash"), "应缩短而不是原样溢出：\(text)")
        XCTAssertTrue(text.contains("19.8%"), "上下文段永不裁剪：\(text)")
        XCTAssertTrue(text.contains("12s"), "时长应仍在：\(text)")
        XCTAssertTrue(text.contains("进行中"), "状态段永不裁剪：\(text)")
    }

    /// 缩短到 4 字仍放不下时才整段丢模型；上下文与状态必须保留。
    func testTaskMetaDropsModelOnlyWhenShorteningImpossible() {
        let longModel = String(repeating: "W", count: 60)
        let step = TaskStepProgress(total: 8,
                                    done: 3,
                                    current: "核实待核实档博主的精确粉丝数")
        let task = makeTask(model: longModel, contextUsage: 0.53, stepProgress: step)
        let text = TouchBarItemFactory.taskMetaAttributedText(task: task,
                                                              elapsed: 12,
                                                              maxWidth: 196).string
        XCTAssertFalse(text.contains(longModel), "放不下时应丢掉模型段：\(text)")
        XCTAssertTrue(text.contains("53.0%"), "上下文段永不裁剪：\(text)")
        XCTAssertTrue(text.contains("进行中"), "状态段永不裁剪：\(text)")
    }

    /// 步骤段紧跟状态，在模型之前；开启后宽度不够先牺牲模型。
    func testTaskStepSegmentOrder() {
        let step = TaskStepProgress(total: 8, done: 3, current: "核实粉丝数")
        let task = makeTask(model: "hy4std", contextUsage: 0.198, stepProgress: step)
        let text = TouchBarItemFactory.taskMetaText(task: task, elapsed: 12)
        XCTAssertEqual(text, "进行中 · 3/8 核实粉丝数 · 混元 4 · ◔ 19.8% · 12s")
    }

    /// 积分段顺序必须严格是 `状态 · 模型 · 积分 · 上下文 · 时长`（用户指定的顺序）。
    func testTaskMetaCreditOrder() {
        let task = makeTask(model: "hy4std", contextUsage: 0.198)
        let text = TouchBarItemFactory.taskMetaText(task: task, elapsed: 12, credits: 10.56)
        XCTAssertEqual(text, "进行中 · 混元 4 · ◇ 10.56 · ◔ 19.8% · 12s")
    }

    /// 宽度充足时不裁剪（maxWidth 传 nil 与传一个很大的值，结果应一致）。
    func testTaskMetaKeepsAllSegmentsWhenWideEnough() {
        let task = makeTask(contextUsage: 0.53)
        let wide = TouchBarItemFactory.taskMetaAttributedText(task: task,
                                                              elapsed: 12,
                                                              maxWidth: 196)
        XCTAssertEqual(wide.string, "进行中 · 混元 4 · ◒ 53.0% · 12s")
    }

    /// 「上下文三个字」换成环形符号后，富文本里必须**没有图片附件**。
    ///
    /// 真机回归（2026-11-19）：用 NSTextAttachment 画真圆环时，图标只在任务开始那一帧出现，
    /// 之后就地刷新就不再绘制（日志里附件始终在，只是 Touch Bar 不画）。
    /// 这条钉死「改用纯字符」这个决定，防止以后有人再换回附件。
    func testContextUsesPlainGlyphNotAttachment() {
        let task = makeTask(contextUsage: 0.53)
        let attributed = TouchBarItemFactory.taskMetaAttributedText(task: task,
                                                                   elapsed: 12,
                                                                   maxWidth: nil)
        XCTAssertTrue(attributed.string.contains("◒ 53.0%"))
        XCTAssertFalse(attributed.string.contains("上下文"), "三个字不该再出现在详情行")

        var attachments = 0
        attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length),
                                      options: []) { value, _, _ in
            if value != nil { attachments += 1 }
        }
        XCTAssertEqual(attachments, 0, "字符模式下不能用图片附件 —— Touch Bar 的 NSTextField 渲染不稳定")
    }

    /// 图形模式：富文本里**没有附件**，圆环改由独立子视图 `ContextRingView` 绘制。
    ///
    /// 真机回归（2026-11-20）：上一版把圆环做成 `NSTextAttachment` + 自定义 cell，
    /// 首帧能画出来，但详情第二行每 3 秒重写一次富文本，Touch Bar 的 `NSTextFieldCell`
    /// 之后就再也不画附件了 —— 用户看到「圆环显示一会儿就消失」。
    /// 这条钉死「圆环不许回到富文本里」这个决定。
    func testGraphicRingRenderingHasNoAttachment() {
        let task = makeTask(contextUsage: 0.53)
        let rendering = TouchBarItemFactory.taskMetaRendering(task: task,
                                                              elapsed: 12,
                                                              maxWidth: nil,
                                                              graphicRing: true)
        // 字符环必须消失（位置让给绘制的圆环）。
        XCTAssertFalse(rendering.attributed.string.contains("◒ 53.0%"),
                       "图形模式不该再带字符环：\(rendering.attributed.string)")
        XCTAssertTrue(rendering.attributed.string.contains("53.0%"))

        var attachments = 0
        rendering.attributed.enumerateAttribute(.attachment,
                                                in: NSRange(location: 0,
                                                            length: rendering.attributed.length),
                                                options: []) { value, _, _ in
            if value != nil { attachments += 1 }
        }
        XCTAssertEqual(attachments, 0,
                       "富文本里不许有附件 —— Touch Bar 上它只画首帧，圆环必须走独立子视图")
    }

    /// 图形模式必须把「圆环画在哪」和「画多少」算出来交给视图。
    func testGraphicRingRenderingExposesOffsetAndRatio() {
        let task = makeTask(contextUsage: 0.53)
        let rendering = TouchBarItemFactory.taskMetaRendering(task: task,
                                                              elapsed: 12,
                                                              maxWidth: nil,
                                                              graphicRing: true)
        guard let offset = rendering.ringOffsetX else {
            return XCTFail("图形模式必须给出圆环偏移")
        }
        XCTAssertTrue(offset > 0, "圆环在上下文段之前，偏移应大于 0，实际 \(offset)")
        XCTAssertTrue(abs((rendering.ringRatio ?? -1) - 0.53) < 1e-9,
                      "ringRatio 应为 0.53，实际 \(String(describing: rendering.ringRatio))")

        // 偏移必须真的等于「上下文段之前那部分文字」的宽度（含分隔符）：
        // 前缀 `进行中 · 混元 4 · ` 的宽度就是圆环左边缘的位置。
        let font = NSFont.systemFont(ofSize: TaskStripView.expandedMetaFontSize)
        let prefix = "进行中" + TouchBarItemFactory.metaSeparator
            + "混元 4" + TouchBarItemFactory.metaSeparator
        XCTAssertTrue(abs(offset - TouchBarTextMetrics.textWidth(prefix, font: font)) < 0.01,
                      "圆环偏移应等于前缀宽度：offset=\(offset)")

        XCTAssertEqual(rendering.prefix?.string, prefix)
        XCTAssertTrue(rendering.suffix?.string.hasPrefix("53.0%") == true)
        XCTAssertFalse(rendering.attributed.string.contains("  "), "图形模式不再使用空格占位")
    }

    /// 字符模式（设置里关掉图形图标）：不给圆环参数，文本仍是 `◒ 53.0%`。
    func testCharacterModeRenderingHasNoRing() {
        let task = makeTask(contextUsage: 0.53)
        let rendering = TouchBarItemFactory.taskMetaRendering(task: task,
                                                              elapsed: 12,
                                                              maxWidth: nil,
                                                              graphicRing: false)
        XCTAssertNil(rendering.ringOffsetX, "字符模式不该有独立圆环")
        XCTAssertNil(rendering.ringRatio)
        XCTAssertTrue(rendering.attributed.string.contains("◒ 53.0%"),
                      "字符模式必须保留字符环：\(rendering.attributed.string)")
    }

    /// 没有上下文数据（nil）时，图形模式也不该显示圆环。
    func testGraphicRingAbsentWhenContextUsageMissing() {
        let task = makeTask(contextUsage: nil)
        let rendering = TouchBarItemFactory.taskMetaRendering(task: task,
                                                             elapsed: 12,
                                                             maxWidth: nil,
                                                             graphicRing: true)
        XCTAssertNil(rendering.ringOffsetX)
        XCTAssertNil(rendering.ringRatio)
    }

    /// 圆环颜色必须与百分比文字同源：≥75% 两者都转橙，否则都安静。
    func testRingTintFollowsContextTightness() {
        XCTAssertTrue(TouchBarItemFactory.ringTint(for: makeTask(contextUsage: 0.80))
            .isEqual(NSColor.systemOrange))
        XCTAssertFalse(TouchBarItemFactory.ringTint(for: makeTask(contextUsage: 0.53))
            .isEqual(NSColor.systemOrange))
        XCTAssertTrue(TouchBarItemFactory.ringTint(for: nil)
            .isEqual(NSColor.secondaryLabelColor))
    }

    /// `ContextRingView` 自己的默认值与夹紧规则。
    func testContextRingViewClampsRatio() {
        let view = ContextRingView(frame: NSRect(x: 0, y: 0,
                                                 width: ContextRingView.side,
                                                 height: ContextRingView.side))
        XCTAssertFalse(view.isOpaque, "Touch Bar 背景很深，圆环底必须透明")
        XCTAssertEqual(view.ratio, 0)
        view.ratio = 1.4
        XCTAssertEqual(view.ratio, 1.0, "比例必须夹到 1")
        view.ratio = -0.3
        XCTAssertEqual(view.ratio, 0.0, "比例不能为负")
        XCTAssertTrue(TaskStripView.contextRingGap >= 3)
    }
}

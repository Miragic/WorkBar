import AppKit

/// Touch Bar DIY 布局的实时预览（**不是**真实 Touch Bar 渲染）。
///
/// ## 它的边界
/// 只回答三个问题：哪些 item 开着、顺序是什么、idle / work 下 task 与 stats 谁出现。
/// 每个 item 用真机上的**真实文案 / 图标 / 结构**做微缩绘制，但宽度只是固定示意
/// （按预览区等比缩放），**不代表真实 Touch Bar 宽度** —— 真机上 task 仍固定 200pt、
/// voice 固定 70pt，宽度不放开。
///
/// ## 为什么用固定浅色而不是系统动态色
/// 预览模拟的是**深色 Touch Bar 条**（背景 fixed 深灰）。若文字跟随系统外观，
/// 浅色外观下 labelColor 变黑、secondaryLabelColor 变深灰，画在深底上几乎看不见。
/// 所以这里所有前景 / 图形色都是**固定浅色**，与系统外观无关；只有几何与文案与真机同源。
final class LayoutPreviewView: NSView {

    /// 预览专用固定色板（不引入 Palette 令牌，也不用系统动态色）。
    private enum PreviewColor {
        /// 近白：概要文案、Buddy 脸、任务标题、语音按钮文字。
        static let primary = NSColor(calibratedWhite: 0.95, alpha: 1)
        /// 浅灰：模型名、积分、状态圆点、圆环、统计文案。
        static let secondary = NSColor(calibratedWhite: 0.70, alpha: 1)
        /// 亮橙：卡住时长（`12s`），深底上醒目。≈ #E8A33D。
        static let warning = NSColor(srgbRed: 0xE8 / 255,
                                     green: 0xA3 / 255,
                                     blue: 0x3D / 255, alpha: 1)
        /// 亮绿：进度条填充。≈ #3DDC97。
        static let accent = NSColor(srgbRed: 0x3D / 255,
                                    green: 0xDC / 255,
                                    blue: 0x97 / 255, alpha: 1)
        /// 语音按钮底：深灰系统圆角按钮（比模拟条背景 0.10 稍亮），不是蓝色块。
        static let buttonFill = NSColor(calibratedWhite: 0.26, alpha: 1)
        /// 语音按钮细边框：浅灰描边，模拟系统圆角按钮的高光边。
        static let buttonBorder = NSColor(calibratedWhite: 0.45, alpha: 1)
    }

    /// 一个已渲染色块（供单测断言，不用依赖像素）。
    ///
    /// - Note: 保持原有四个字段与等值语义不变，绘制细节在 `draw` 里按 `id` 现算。
    struct Block: Equatable {
        let id: String
        let name: String
        let x: CGFloat
        let width: CGFloat
    }

    /// 固定示意宽度（pt）；`renderedBlocks` 会按视图实际宽度等比缩放。
    private static let nominalWidths: [String: CGFloat] = [
        "summary": 90, "task": 150, "stats": 90, "voice": 55
    ]
    private static let names: [String: String] = [
        "summary": "摘要", "task": "任务", "stats": "统计", "voice": "语音"
    ]

    var layout: [Settings.LayoutItem] = Settings.defaultLayoutOrder {
        didSet { needsDisplay = true }
    }
    /// true = 空闲态（显示「统计」，隐藏「任务」）；false = 工作态（相反）。
    var isIdle: Bool = false {
        didSet { needsDisplay = true }
    }

    // MARK: - 跟随设置面板的开关（都有默认值，老调用方无需传）

    /// 极简模式：只画摘要 + 语音，忽略 layoutOrder 里的任务条 / 统计。
    var minimalMode: Bool = false {
        didSet { needsDisplay = true }
    }
    /// 默认详情模式：true 任务条画两行，false 只画一行标题（真机紧凑态）。
    var detailExpanded: Bool = false {
        didSet { needsDisplay = true }
    }
    /// 任务步骤：true 时任务条第二行画进度条 + `3/8`，false 不画。
    var showTaskStep: Bool = false {
        didSet { needsDisplay = true }
    }
    /// 图形上下文图标：true 画自绘小圆环，false 画字符 `◒`。
    var graphicContextIcon: Bool = true {
        didSet { needsDisplay = true }
    }

    /// 当前可见的 item（启用 + 模式过滤），`renderedBlocks` 与 `draw` 共用，避免两处规则走岔。
    private var visibleItems: [Settings.LayoutItem] {
        layout.filter { item in
            // 极简模式恒显示「摘要 + 语音」，与 identifiers(for:) 一致：真机不看 enabled，预览也不能看。
            if minimalMode { return item.id == "summary" || item.id == "voice" }
            guard item.enabled else { return false }
            if item.id == "task" { return !isIdle }
            if item.id == "stats" { return isIdle }
            return true
        }
    }

    /// 任务条第二行将绘制的段（供单测断言，不依赖像素）。
    ///
    /// - Note: `drawTask` 也读它，保证「测试看到的」与「实际画的」是同一份数据。
    var taskSecondLineSegments: [String] {
        guard detailExpanded else { return [] }
        var segments = ["statusDot", "model"]
        if showTaskStep { segments += ["stepCount", "progressBar"] }
        segments.append(graphicContextIcon ? "ring" : "ringGlyph")
        segments += ["credit", "age"]
        return segments
    }

    /// 当前应画出的色块，按显示顺序排列，x 已缩放到本视图宽度内。
    ///
    /// - Note: 单测断言这个属性即可，不必真的渲染像素。
    var renderedBlocks: [Block] {
        let visible = visibleItems
        let total = visible.reduce(CGFloat(0)) { $0 + (Self.nominalWidths[$1.id] ?? 0) }
        guard total > 0 else { return [] }
        let scale = min(1, bounds.width / total)
        var x: CGFloat = 0
        return visible.compactMap { item in
            guard let nominal = Self.nominalWidths[item.id] else { return nil }
            let width = nominal * scale
            let block = Block(id: item.id,
                              name: Self.names[item.id] ?? item.id,
                              x: x, width: width)
            x += width
            return block
        }
    }

    override var isOpaque: Bool { false }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        // 深色模拟条背景。
        NSColor(calibratedWhite: 0.10, alpha: 1).setFill()
        bounds.fill()

        let total = visibleItems.reduce(CGFloat(0)) {
            $0 + (Self.nominalWidths[$1.id] ?? 0)
        }
        let scale = total > 0 ? min(1, bounds.width / total) : 1

        for block in renderedBlocks {
            let rect = NSRect(x: bounds.minX + block.x,
                              y: bounds.minY + 3,
                              width: max(0, block.width - 3),
                              height: max(0, bounds.height - 6))
            guard rect.width > 2, rect.height > 2 else { continue }
            // 每个 item 裁在自己的框里，文字 / 图形绝不会溢到相邻块。
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).addClip()
            drawItem(id: block.id, in: rect, scale: scale)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// 一个 item 的底色 + 内容。
    private func drawItem(id: String, in rect: NSRect, scale: CGFloat) {
        NSColor(calibratedWhite: 0.17, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()

        switch id {
        case "summary": drawSummary(in: rect)
        case "task": drawTask(in: rect, scale: scale)
        case "stats": drawStats(in: rect)
        case "voice": drawVoice(in: rect)
        default: break
        }
    }

    /// summary：左侧 Buddy 脸，右侧真实概要文案（取自 `TouchBarState.summaryLabel`）。
    private func drawSummary(in rect: NSRect) {
        let face = isIdle ? BuddyFace.idle.emoji : BuddyFace.running.emoji
        let text: String
        if isIdle {
            text = TouchBarState.idle.summaryLabel
        } else {
            let tasks = [TaskInfo(id: "a", title: "任务 A", status: .working),
                         TaskInfo(id: "b", title: "任务 B", status: .working)]
            text = TouchBarState.working(tasks: tasks).summaryLabel
        }
        let faceFont = NSFont.systemFont(ofSize: 13)
        let textFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
        let gap: CGFloat = 6
        let faceWidth: CGFloat = 18
        let textW = min(rect.width - faceWidth - gap - 6,
                        NSString(string: text).size(withAttributes: [.font: textFont]).width)
        let groupWidth = faceWidth + gap + max(0, textW)
        // 脸+文字成组居中：真机摘要是「表情 后跟文案」整体居中，不是把脸钉在最左。
        var groupX = rect.midX - groupWidth / 2
        groupX = max(rect.minX + 3, groupX)

        let faceRect = NSRect(x: groupX, y: rect.minY,
                              width: faceWidth, height: rect.height)
        drawCentered(face, in: faceRect, font: faceFont, color: PreviewColor.primary)
        let textRect = NSRect(x: faceRect.maxX + gap, y: rect.minY,
                              width: max(0, textW), height: rect.height)
        drawText(text, in: textRect, font: textFont, color: PreviewColor.primary)
    }

    /// task：详情模式两行微缩卡片，紧凑模式只画一行标题（与真机一致）。
    private func drawTask(in rect: NSRect, scale: CGFloat) {
        let task = TaskInfo(id: "t", title: "任务标题", status: .working)
        let title = TouchBarItemFactory.taskText(task: task, index: 0, total: 2)
        let font = NSFont.systemFont(ofSize: 9, weight: .semibold)

        guard detailExpanded else {
            // 紧凑态：标题独占整格并垂直居中。
            drawText(title, in: rect, font: font, color: PreviewColor.primary)
            return
        }

        let topLine = NSRect(x: rect.minX + 4, y: rect.midY + 1,
                             width: max(0, rect.width - 8),
                             height: max(0, rect.height / 2 - 1))
        // 详情态真机标题左对齐（TaskStripView 展开态 label.alignment = .left）。
        drawText(title, in: topLine, font: font, color: PreviewColor.primary, alignment: .left)

        let segments = taskSecondLineSegments
        guard !segments.isEmpty else { return }
        let lineY = rect.minY + 2
        let lineH = max(0, rect.height / 2 - 2)
        let right = rect.maxX - 3
        var x = rect.minX + 4

        for segment in segments {
            switch segment {
            case "statusDot":
                let dotSide: CGFloat = 4
                PreviewColor.secondary.setFill()
                NSBezierPath(ovalIn: NSRect(x: x, y: lineY + (lineH - dotSide) / 2,
                                            width: dotSide, height: dotSide)).fill()
                x += dotSide + 4
            case "model":
                x = drawTrailing("混元 4", at: x, y: lineY, height: lineH,
                                 font: .systemFont(ofSize: 7),
                                 color: PreviewColor.secondary, right: right)
            case "stepCount":
                x = drawTrailing("3/8", at: x, y: lineY, height: lineH,
                                 font: .systemFont(ofSize: 7),
                                 color: PreviewColor.secondary, right: right)
            case "progressBar":
                let barWidth = max(8, 28 * scale)
                let barHeight = max(2, 3 * scale)
                let barRect = NSRect(x: x, y: lineY + (lineH - barHeight) / 2,
                                     width: barWidth, height: barHeight)
                drawMiniBar(in: barRect, fill: 3.0 / 8.0)
                x = barRect.maxX + 4
            case "ring":
                let ringSide = max(7, 10 * scale)
                let ringRect = NSRect(x: x, y: lineY + (lineH - ringSide) / 2,
                                      width: ringSide, height: ringSide)
                drawMiniRing(in: ringRect, ratio: 0.30)
                x = ringRect.maxX + 4
            case "ringGlyph":
                x = drawTrailing("◒", at: x, y: lineY, height: lineH,
                                 font: .systemFont(ofSize: 9),
                                 color: PreviewColor.secondary, right: right)
            case "credit":
                x = drawTrailing("◇ 12.34", at: x, y: lineY, height: lineH,
                                 font: .systemFont(ofSize: 7),
                                 color: PreviewColor.secondary, right: right)
            case "age":
                _ = drawTrailing(ActivityAge.formatActivityAge(12) ?? "12s",
                                 at: x, y: lineY, height: lineH,
                                 font: .systemFont(ofSize: 7),
                                 color: PreviewColor.warning, right: right)
            default:
                break
            }
        }
    }

    /// stats：直接用 `IdleStats.label`，文案与真机逐字一致。
    private func drawStats(in rect: NSRect) {
        let text = IdleStats(todayCompleted: 3, todayCredits: 12.34,
                             totalCredits: 0).label
        drawText(text, in: rect,
                 font: .systemFont(ofSize: 9),
                 color: PreviewColor.secondary, alignment: .center)
    }

    /// voice：模拟真机 `makeTouchBarButton` 的系统圆角按钮（深灰底 + 浅灰细边 + 白字）。
    private func drawVoice(in rect: NSRect) {
        let button = rect.insetBy(dx: 1, dy: 5)
        let path = NSBezierPath(roundedRect: button, xRadius: 4, yRadius: 4)
        PreviewColor.buttonFill.setFill()
        path.fill()
        PreviewColor.buttonBorder.setStroke()
        path.lineWidth = 1
        path.stroke()
        drawText("🎙️ 语音", in: button,
                 font: .systemFont(ofSize: 10, weight: .medium),
                 color: PreviewColor.primary, alignment: .center)
    }

    // MARK: - 绘制小工具

    /// 细进度条：底环 + 填充，颜色与真机一致（accent 填充、25% 透明底）。
    private func drawMiniBar(in rect: NSRect, fill: Double) {
        guard rect.width > 0, rect.height > 0 else { return }
        let radius = rect.height / 2
        PreviewColor.accent.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        let filled = NSRect(x: rect.minX, y: rect.minY,
                            width: rect.width * CGFloat(min(max(fill, 0), 1)),
                            height: rect.height)
        guard filled.width > 0 else { return }
        PreviewColor.accent.setFill()
        NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius).fill()
    }

    /// 小圆环：灰色底环 + 按比例的弧（与 `ContextRingView` 同一套画法）。
    private func drawMiniRing(in rect: NSRect, ratio: Double) {
        let radius = max(0, min(rect.width, rect.height) / 2 - 1)
        guard radius > 0 else { return }
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let track = NSBezierPath(ovalIn: NSRect(x: center.x - radius,
                                                y: center.y - radius,
                                                width: radius * 2,
                                                height: radius * 2))
        track.lineWidth = 1
        PreviewColor.secondary.withAlphaComponent(0.28).setStroke()
        track.stroke()

        let clamped = min(max(ratio, 0), 1)
        guard clamped > 0 else { return }
        let arc = NSBezierPath()
        arc.lineWidth = 1.2
        arc.lineCapStyle = .round
        arc.appendArc(withCenter: center, radius: radius,
                      startAngle: 90, endAngle: 90 - 360 * CGFloat(clamped),
                      clockwise: true)
        PreviewColor.secondary.setStroke()
        arc.stroke()
    }

    /// 左对齐文字，放不下按 `byTruncatingTail` 省略，绝不溢出给定宽度。
    @discardableResult
    private func drawTrailing(_ text: String,
                              at x: CGFloat,
                              y: CGFloat,
                              height: CGFloat,
                              font: NSFont,
                              color: NSColor,
                              right: CGFloat) -> CGFloat {
        let available = max(0, right - x)
        guard available > 0, height > 0 else { return x }
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = NSString(string: text).boundingRect(
            with: NSSize(width: available, height: height),
            options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin],
            attributes: attributes).size
        let width = min(max(0, size.width), available)
        if width > 0 {
            NSString(string: text).draw(
                in: NSRect(x: x, y: y + (height - size.height) / 2,
                           width: width, height: size.height),
                withAttributes: attributes)
        }
        return x + width + 4
    }

    /// 在给定框内绘制文字（居中 / 左对齐均可，超宽截断）。
    private func drawText(_ text: String,
                          in rect: NSRect,
                          font: NSFont,
                          color: NSColor,
                          // 真机 item（summary / stats / voice / 紧凑态标题）文字居中；
                          // 需要左对齐的调用点（详情态任务标题、第二行分段）显式传 .left。
                          alignment: NSTextAlignment = .center) {
        guard rect.width > 0, rect.height > 0 else { return }
        let style = NSMutableParagraphStyle()
        // 段落内一律左对齐：居中由下面手动算 origin 完成，不依赖 draw(in:) 的
        // 段落对齐 —— `NSString.draw(in:)` 在框里是**顶部对齐**，段落 .center 只管水平，
        // 结果是水平居中了但垂直贴顶，看起来「不在居中位置」。
        style.alignment = .left
        style.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color, .paragraphStyle: style
        ]
        // 实际绘制尺寸（含尾部截断），用它算中点才准 —— 直接用 rect 宽会把被截断的文字
        // 按原宽度居中，视觉上偏左。
        let drawnSize = NSString(string: text).boundingRect(
            with: NSSize(width: rect.width, height: rect.height),
            options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin],
            attributes: attributes).size
        let drawWidth = min(max(0, drawnSize.width), rect.width)
        let drawHeight = min(max(0, drawnSize.height), rect.height)
        let originX: CGFloat
        switch alignment {
        case .center: originX = rect.midX - drawWidth / 2
        case .right:  originX = rect.maxX - drawWidth
        default:      originX = rect.minX
        }
        let originY = rect.midY - drawHeight / 2
        NSString(string: text).draw(
            in: NSRect(x: originX, y: originY, width: drawWidth, height: drawHeight),
            withAttributes: attributes)
    }

    /// 在框内水平 / 垂直居中绘制（用于 emoji）。
    private func drawCentered(_ text: String, in rect: NSRect,
                              font: NSFont, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = NSString(string: text).size(withAttributes: attributes)
        let origin = NSPoint(x: rect.midX - size.width / 2,
                             y: rect.midY - size.height / 2)
        NSString(string: text).draw(at: origin, withAttributes: attributes)
    }
}

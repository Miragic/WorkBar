import AppKit

/// 上下文用量圆环（自绘独立视图，**不进富文本**）。
///
/// ## 为什么必须是独立子视图
/// 之前的实现是 `NSTextAttachment` + `NSTextAttachmentCell`，靠富文本挂在 `NSTextField` 上。
/// 真机现象：圆环只显示一会儿就消失。根因是详情第二行每 3 秒重写一次
/// （`metaLabel.attributedStringValue = 新的富文本`），而 Touch Bar 上的 `NSTextFieldCell`
/// 对 `NSTextAttachment` 的绘制**只在首次有效**，后续反复赋值就不再画附件。
/// 两种载体都试过（`attachment.image` 放 NSImage、自定义 cell 直接画），都失效。
///
/// 所以现在把圆环从富文本里摘出来，做成 `TaskStripView` 的普通子视图：
/// 富文本只负责文字，圆环自己随 `ratio` 变而在原地重绘。这条路径不依赖
/// `NSTextFieldCell` 的附件绘制，反复刷新也稳定。
///
/// - Note: 尺寸固定 10×10pt；与后缀文本框保持至少 3pt 独立间距。
final class ContextRingView: NSView {

    /// 圆环所在的边长（pt）。宽度计算与绘制都以它为基准。
    static let side: CGFloat = 10

    /// 占用比（0…1）。超出范围会被夹紧；`0` 表示只画底环。
    var ratio: Double = 0 {
        didSet {
            let clamped = min(max(ratio, 0), 1)
            if clamped != ratio { ratio = clamped }
            needsDisplay = true
        }
    }

    /// 圆环颜色（进度弧用它，底环用它的 28% 透明度）。
    var tint: NSColor = .secondaryLabelColor {
        didSet { needsDisplay = true }
    }

    /// 透明底：Touch Bar 背景是深色的，不能有白底方块。
    override var isOpaque: Bool { false }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.side, height: Self.side)
    }

    override func draw(_ dirtyRect: NSRect) {
        // 底环：整圈，浅一点，告诉用户「这里有个环」。
        let box = NSRect(x: bounds.minX + 0.6,
                         y: bounds.minY + 0.6,
                         width: max(0, bounds.width - 1.2),
                         height: max(0, bounds.height - 1.2))
        guard box.width > 0, box.height > 0 else { return }

        tint.withAlphaComponent(0.28).setStroke()
        let track = NSBezierPath(ovalIn: box)
        track.lineWidth = 1
        track.stroke()

        // 进度弧：从 90°（正上方）顺时针走 360 × ratio。
        guard ratio > 0 else { return }
        tint.setStroke()
        let arc = NSBezierPath()
        arc.lineWidth = 1.4
        arc.lineCapStyle = .round
        arc.appendArc(withCenter: NSPoint(x: box.midX, y: box.midY),
                      radius: max(0, min(bounds.width, bounds.height) / 2 - arc.lineWidth / 2),
                      startAngle: 90,
                      endAngle: 90 - 360 * CGFloat(ratio),
                      clockwise: true)
        arc.stroke()
    }
}

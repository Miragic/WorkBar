import AppKit
import QuartzCore

/// V13 步骤进度条：一条细进度条，独立于富文本自绘。
///
/// ## 为什么是独立视图（不进富文本）
/// 和 `ContextRingView` 同理：详情第二行每 3 秒重写一次富文本，Touch Bar 的
/// `NSTextFieldCell` 对 `NSTextAttachment` 只在首次绘制有效。进度条做成普通
/// `NSView` 子视图，靠 `progress` 变化原地重绘 + 动画，反复刷新也稳定。
///
/// ## 尺寸为什么这么小
/// 真机 Touch Bar 任务条只有 200pt，详情第二行可用 196pt，且已挤入
/// 状态 / 模型 / 积分 / 上下文环 / 时长。设计稿 V13 画的 180pt 大条无法落地，
/// 这里压成 **28×3pt** 的细条：足够表达「还剩几步」，又不挤掉状态与上下文环。
///
/// - Note: 用 CAShapeLayer 画「圆头线段」而不是矩形圆角 —— 一条 stroke 线
///   天然带两端圆角，且能通过 `strokeEnd` 做 200ms ease-out 的宽度动画，
///   不需要自己插值 frame。
final class StepProgressView: NSView {

    /// 固定宽度（pt）。`TaskStripView` / 工厂的宽度裁剪都以它为预算。
    static let barWidth: CGFloat = 28
    /// 固定高度（pt）。3pt，足够在 Touch Bar 上辨识又不占行高。
    static let barHeight: CGFloat = 3

    /// 进度（0...1），超出夹紧；`0` 只画底条。
    var progress: Double = 0 {
        didSet {
            let clamped = min(max(progress, 0), 1)
            if clamped != progress { progress = clamped }
            applyProgress(animated: true)
        }
    }

    /// 填充色（accent 语义色；100% 时由 `tint(for:)` 给出强调色）。
    var tint: NSColor = StepProgressView.tint(for: 0) {
        didSet { applyColors() }
    }

    /// 底条颜色（accent 的 25% 透明）。
    var trackColor: NSColor = StepProgressView.tint(for: 0).withAlphaComponent(0.25) {
        didSet { applyColors() }
    }

    override var isOpaque: Bool { false }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.barWidth, height: Self.barHeight)
    }

    /// 常态 accent；满了用绿色强调，让「做完」一眼可读。
    static func tint(for progress: Double) -> NSColor {
        progress >= 1 ? .systemGreen : .controlAccentColor
    }

    private let trackLayer = CAShapeLayer()
    private let fillLayer = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        guard let root = layer else { return }
        for layer in [trackLayer, fillLayer] {
            layer.lineWidth = Self.barHeight
            layer.lineCap = .round
            layer.fillColor = nil
            root.addSublayer(layer)
        }
        trackLayer.strokeColor = trackColor.cgColor
        fillLayer.strokeColor = tint.cgColor
        fillLayer.strokeEnd = 0
        rebuildPaths()
        applyColors()
    }

    override func layout() {
        super.layout()
        rebuildPaths()
    }

    /// 一条从左边圆头到右边圆头的水平线 —— stroke 出来就是两端圆角的细条。
    private func rebuildPaths() {
        let radius = Self.barHeight / 2
        let y = bounds.midY
        let path = CGMutablePath()
        path.move(to: CGPoint(x: bounds.minX + radius, y: y))
        path.addLine(to: CGPoint(x: max(bounds.minX + radius, bounds.maxX - radius), y: y))
        trackLayer.path = path
        fillLayer.path = path
        trackLayer.frame = bounds
        fillLayer.frame = bounds
    }

    private func applyColors() {
        trackLayer.strokeColor = trackColor.cgColor
        fillLayer.strokeColor = tint.cgColor
    }

    private func applyProgress(animated: Bool) {
        let value = min(max(progress, 0), 1)
        fillLayer.isHidden = value <= 0
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        if animated {
            CATransaction.setAnimationDuration(0.2)
            CATransaction.setAnimationTimingFunction(
                CAMediaTimingFunction(name: .easeOut))
        }
        fillLayer.strokeEnd = CGFloat(value)
        CATransaction.commit()
    }
}

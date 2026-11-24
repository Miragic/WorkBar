import AppKit

/// 摘要区容器：左侧「情绪脸」+ 右侧文字，整块可点（点击跳转 WorkBuddy）。
///
/// ## 为什么从 `NSButton` 换成 `NSView` 容器
/// 起因是「让进行中的眼睛动起来」：`NSButton` 只能通过 `.image` 显示静态位图，
/// 装不下一个需要持续重绘的子视图。容器结构保留了下来，因为它是无害的（见下），
/// 但**会眨眼的自绘眼睛已经撤回**（用户真机看过效果不满意，见
/// `archive/2026-11-18-blinking-eyes/README.md`）。现在五张脸统一是
/// `NSImageView` + emoji 位图，`animates = true` 已就位，等用户提供 GIF 后直接接上。
///
/// - Important: 这次**只换承载方式，不换信息结构** —— 还是「22pt 图标 + 12pt 文字 + 点击跳转」。
///   三处回归点照原样保留：
///   1. 点击 → `onClick`（= 控制器的 `handlers.onJump`）；
///   2. 整块宽度 ≤ 100pt（`maxWidth`，见其说明）；
///   3. celebrate 的缩放动画仍然作用在本视图的 `layer` 上（`playFaceTransition`）。
///
/// - Note: 之所以没把整条 summary 做成「自定义视图 + 自己处理高亮」的完整按钮，
///   是因为 `NSButton` 的按下态高亮、语音辅助（VoiceOver）都被系统免费提供，
///   自绘容器要重建这些成本不小。
final class SummaryBarView: NSView {

    /// 高度与 emoji 图、`TaskStripView` 一致（Touch Bar 内容区约 30pt）。
    static let barHeight: CGFloat = 30

    /// 左侧脸的边长（与 `BuddyFace.image` 的 22×22 一致，换脸时文字不左右跳）。
    static let faceSide: CGFloat = 22

    /// 文字字号。
    ///
    /// - Note: 12pt 而不是 13pt，是之前加 22pt 图标时从文字里省回宽度定下的，
    ///   这次不跟着改 —— 改字号会同时改变三个状态的宽度，属于无必要的连锁。
    static let fontSize: CGFloat = 12

    /// 图标与文字之间的间隙。
    static let gap: CGFloat = 3

    /// 左右内边距（比 `NSButton` 自带的约 10pt/侧窄一半，省下的正是宽度预算）。
    static let horizontalPadding: CGFloat = 5

    /// 文字宽度的安全余量。
    ///
    /// 为什么必须有：`NSString.size(withAttributes:)` 算出的宽度是**理想值**，
    /// 而 `NSTextField` 实际绘制还要算上字形抗锯齿的外扩与字距微调。
    /// 之前「空闲」算出来 23.8pt、label 可用宽度恰好 24pt，真机上就贴边截成了「空..」。
    /// 多给 6pt 后 label 比文字宽一圈，任何状态都不会再被 `byTruncatingTail` 截断。
    static let textWidthSlack: CGFloat = 6

    /// 整块最大宽度。
    ///
    /// 原值 100pt，2026-11-19 按用户反馈放宽：摘要曾被系统挤到只剩「1..」，
    /// 根因是 `visibilityPriority` 与任务条同为 0（已提到 .high），但即便如此，
    /// 100pt 对最长文案「12 疑似卡住」(整块 99pt) 几乎贴边，一旦字体度量略有差异就会截断。
    /// 放宽到 140pt 给足余量，让**所有状态文案都完整显示**（用户明确要求「刚好展示」）；
    /// 实际宽度仍按文字实测自适应（`fittedSize`），空闲态依然是 59pt，不会无故变宽。
    /// 实测文字宽度（12pt 系统字体，`NSString.size(withAttributes:)`）：
    /// 空闲 23.8 → 59pt、进行中 44.7 → 80pt、待读 32.8 → 68pt、疑似卡住 56.6 → 92pt、
    /// 最长「12 疑似卡住」63.9 → 99pt。140pt 上限只为防极端长文案，日常都到不了。
    static let maxWidth: CGFloat = 140

    /// 背景圆角半径，对齐语音按钮 `NSButton` 的 rounded bezel。
    static let cornerRadius: CGFloat = 6

    /// 整块被点一下（跳转 WorkBuddy）。
    var onClick: (() -> Void)?

    /// 右侧文字。
    private let titleLabel = NSTextField(labelWithString: "")

    /// 左侧表情视图（五张脸统一是 `NSImageView`）。
    private var faceView: NSImageView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    /// 内容尺寸（宽度按文字实测宽度算，高度固定）。
    ///
    /// - Important: 必须实现，而不是只给 `frame`：`NSCustomTouchBarItem` 用
    ///   `intrinsicContentSize` 决定 item 占多宽，`NSView` 的默认实现返回
    ///   `(-1, -1)`（"无固有尺寸"），Touch Bar 会退化成按 frame 猜或直接不给宽度。
    ///   顺带的好处是 `TB_DEBUG=1` 的 `item=summary ... intrinsic=` 日志能直接读到真实宽度。
    override var intrinsicContentSize: NSSize {
        fittedSize()
    }

    private func setup() {
        // 灰色圆角底，与语音按钮的系统 bezel 观感一致。用 layer 绘制而不是塞一个
        // NSButton 进来：保留现在的点击手势与 celebrate 缩放（缩放仍作用在本视图 layer）。
        // 颜色取系统「 tertiaryLabelColor 的极低透明度」不合适（太淡看不出边界），
        // 改用与 Touch Bar 系统按钮同族的 controlColor，深浅色模式自动跟随。
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.masksToBounds = true
        applyBackgroundColor()

        titleLabel.font = .systemFont(ofSize: Self.fontSize)
        titleLabel.textColor = .labelColor
        // 左对齐 + 直接裁切：绝不让 AppKit 插入「..」省略号。
        // 用户看到「空..」的根因就是 byTruncatingTail —— 即便 label 宽度已够（真机诊断
        // labelW=30pt、need=23.8pt），Touch Bar 挂载时的二次布局仍可能触发它。
        // 改成 byClipping 后，即使真被压缩也只是右侧少一点，绝不会把「闲」替换成「..」。
        titleLabel.alignment = .left
        titleLabel.lineBreakMode = .byClipping
        titleLabel.maximumNumberOfLines = 1
        titleLabel.isBordered = false
        titleLabel.isEditable = false
        titleLabel.isSelectable = false
        titleLabel.drawsBackground = false
        addSubview(titleLabel)

        // 整块可点。`allowedTouchTypes = .direct` 与 `TaskStripView` 的横滑手势一致
        // （Touch Bar 是直接触摸屏，不限定的话收不到触摸，见 docs/FEASIBILITY.md §1 #4）。
        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
        click.allowedTouchTypes = .direct
        addGestureRecognizer(click)
    }

    /// 更新文字与表情。
    ///
    /// - Parameters:
    ///   - title: 已去掉状态 emoji 的文案（`TouchBarItemFactory.summaryTitle(for:)`）。
    ///   - face: 当前情绪脸（五张脸统一走 `BuddyFace.image(for:)`，无特殊分支）。
    func update(title: String, face: BuddyFace) {
        titleLabel.stringValue = title
        installFace(face)
        setFrameSize(fittedSize())
        needsLayout = true
        layoutContent()
    }

    /// 换脸。
    ///
    /// - Note: 每次重建都是新的 `SummaryBarView`，这里只需处理「换脸」而非「复用」，
    ///   所以直接移除旧视图新建，不做原地替换 —— 少一条状态路径就少一类 bug。
    /// - Note: 五张脸**统一**用 `NSImageView` + `BuddyFace.image(for:)`。曾经给 `.running`
    ///   单独做过一版自绘 + 定时眨眼的视图（`BuddyEyesView`），用户真机看过效果后否掉了
    ///   （22pt 里手绘的眼睛不如 emoji 好看），已归档到 `archive/2026-11-18-blinking-eyes/`。
    ///   后续若要动图，接缝在这里：把 `image(for:)` 换成能返回多帧 `NSImage` 的实现，
    ///   `animates = true` 已经就位，其它代码一行都不用改。
    private func installFace(_ face: BuddyFace) {
        faceView?.removeFromSuperview()

        let imageView = NSImageView(frame: NSRect(x: 0, y: 0, width: Self.faceSide, height: Self.faceSide))
        imageView.image = BuddyFace.image(for: face)
        imageView.imageScaling = .scaleProportionallyDown
        // 为**后续 GIF / 多帧动图**预留：多帧 NSImage 在 `animates = true` 时会自动播放。
        // 当前 `BuddyFace.image(for:)` 返回的是单帧位图，对静态图这个开关没有任何副作用
        // （不会动、不多耗电），所以现在就可以打开，将来只需换产出图片的那个函数。
        imageView.animates = true
        addSubview(imageView)
        faceView = imageView
    }

    /// 按文字实测宽度算出整块应占的尺寸（不超过 `maxWidth`）。
    private func fittedSize() -> NSSize {
        let font = titleLabel.font ?? NSFont.systemFont(ofSize: Self.fontSize)
        let textWidth = TouchBarTextMetrics.textWidth(titleLabel.stringValue, font: font)
        let raw = Self.horizontalPadding * 2 + Self.faceSide + Self.gap
            + ceil(textWidth + Self.textWidthSlack)
        return NSSize(width: min(Self.maxWidth, raw), height: Self.barHeight)
    }

    /// 手工排版：左侧脸 + 右侧文字，两者垂直居中。
    ///
    /// - Note: 不用 Auto Layout，理由与 `TaskStripView` 相同 —— Touch Bar 会在挂载后
    ///   再改一次尺寸，约束没满足时「谁被压缩」不确定，手工算 frame 是确定的。
    private func layoutContent() {
        let faceHeight = min(Self.faceSide, bounds.height)
        faceView?.frame = NSRect(x: Self.horizontalPadding,
                                 y: floor((bounds.height - faceHeight) / 2),
                                 width: Self.faceSide,
                                 height: faceHeight)

        let font = titleLabel.font ?? NSFont.systemFont(ofSize: Self.fontSize)
        let textX = Self.horizontalPadding + Self.faceSide + Self.gap
        let textWidth = max(0, bounds.width - textX - Self.horizontalPadding)
        let textHeight = TouchBarTextMetrics.textHeight(for: font)
        titleLabel.frame = NSRect(x: textX,
                                  y: floor((bounds.height - textHeight) / 2),
                                  width: textWidth,
                                  height: textHeight)
    }

    override func layout() {
        super.layout()
        layoutContent()
    }

    /// 把背景色按**当前外观**解析后写入 layer。
    ///
    /// - Important: 不能用 `NSColor.controlColor.cgColor` 直接取 —— `cgColor` 是在取值那一刻
    ///   按「当时的外观」解析出来的固定值，之后用户切换深/浅色时它**不会跟着变**，
    ///   会留下一个和背景撞色的方框。必须显式 `resolvedColor(with:)`，并在外观变化时重算。
    private func applyBackgroundColor() {
        // 在「当前外观」的绘图上下文里取 cgColor，才会拿到该外观解析后的值。
        // `NSColor.controlColor.cgColor` 直接取会用「系统默认外观」，切换后不刷新。
        var resolved: CGColor = NSColor.controlColor.cgColor
        if #available(macOS 11.0, *) {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                resolved = NSColor.controlColor.cgColor
            }
        }
        layer?.backgroundColor = resolved
    }

    /// 外观（深/浅色）变化时重算背景色。AppKit 在视图的外观变化后自动调用。
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBackgroundColor()
    }

    /// 改文字颜色（失败态的「红字」用它，200ms 后由调用方恢复成 `labelColor`）。
    func setTitleColor(_ color: NSColor) {
        titleLabel.textColor = color
    }

    @objc private func handleClick() {
        onClick?()
    }
}

/// Touch Bar 上的单行文字度量。
///
/// 抽出来的唯一理由：`SummaryBarView` 与 `TaskStripView` 都要「把文字垂直居中」，
/// 各写一遍必然会有一处先改、另一处忘了改。
enum TouchBarTextMetrics {

    /// 单行文字在 Touch Bar 上的实际高度。
    ///
    /// - Important: 不要用 `intrinsicContentSize.height`。无边框的 `NSTextField`
    ///   （`labelWithString:` 造出来的那种）在某些 AppKit 版本上对它返回 `-1`，
    ///   表示「无固有尺寸」；拿 `-1` 去算 `y = (bounds.height - (-1)) / 2`
    ///   会把文字推到框外面，表现得像「文字消失」。
    ///   字体度量是纯计算、恒定可用，且正好等于文字真正占用的行高。
    ///
    /// - Parameter font: 目标字体。
    /// - Returns: 行高（向上取整，避免 0.5pt 的亚像素裁切）。
    static func textHeight(for font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }

    /// 单行文字的渲染宽度（用于算 Touch Bar item 的宽度预算）。
    ///
    /// - Parameters:
    ///   - text: 待测量文字。
    ///   - font: 目标字体。
    /// - Returns: 宽度（pt）；空字符串返回 0。
    static func textWidth(_ text: String, font: NSFont) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        return (text as NSString).size(withAttributes: [.font: font]).width
    }
}

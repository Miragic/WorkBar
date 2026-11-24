import AppKit

/// 设置面板（单个小窗口）。
///
/// ## 为什么做成独立窗口而不是塞进菜单
/// 菜单项适合「一次性动作」（打开 WorkBuddy、退出），而「模式切换」是有状态的开关：
/// 用户需要**看见当前状态**，菜单勾选态在不同 macOS 版本里样式不一致、也不容易加说明文字。
/// 一个小窗口放下「开关 + 一句解释」最清楚，且不影响菜单的清爽。
///
/// - Note: 应用是 `LSUIElement`（无 Dock 图标），打开窗口时必须显式 `activate`，
///   否则窗口会出现在其他应用后面，用户以为「点了没反应」。
///
/// ## 布局（纯 UI 重构）
/// 640pt 宽的双栏：左侧 156pt 分类导航（常规 / 布局 / 关于），右侧分组卡片内容区。
/// 三个分类内容视图叠放在右侧，切换时只切 `isHidden`，不动任何控件实例与回调。
final class SettingsWindowController: NSWindowController {

    /// 极简模式开关。
    private let minimalSwitch = NSSwitch()
    /// 默认详情模式开关。
    private let detailSwitch = NSSwitch()
    /// 任务步骤开关。
    private let stepSwitch = NSSwitch()
    /// 图形上下文图标开关。
    private let graphicIconSwitch = NSSwitch()
    /// 常驻显示开关。
    private let keepAwakeSwitch = NSSwitch()
    /// 空闲统计口径（今日各轮之和 / 本轮消耗）。用下拉而非开关：两个具名口径比 on/off 更自解释，
    /// 且不会增加 NSSwitch 数量（现有布局测试固定 10 个开关）。
    private let idleCreditsPopup = NSPopUpButton(frame: .zero, pullsDown: false)

    // MARK: - DIY 布局

    /// 当前布局（本地镜像，改动后写回 `Settings.layoutOrder`）。
    private var layoutItems: [Settings.LayoutItem] = Settings.layoutOrder
    private var layoutNameLabels: [NSTextField] = []
    private var layoutSwitches: [NSSwitch] = []
    private var layoutUpButtons: [NSButton] = []
    private var layoutDownButtons: [NSButton] = []

    /// 预览模式开关：开 = 空闲态，关 = 工作态。
    private let previewModeSwitch = NSSwitch()
    private let previewHintLabel = NSTextField(labelWithString: "")
    private let layoutPreview = LayoutPreviewView()
    private var previewIsIdle = false

    /// 当前设置变更时回调（控制器用它立即重建 Touch Bar，不必等下一轮轮询）。
    var onSettingsChanged: (() -> Void)?

    // MARK: - 双栏结构（只负责摆位与切换，不承载业务逻辑）

    private let navTitles = ["常规", "布局", "关于"]
    private let navSymbols = ["gearshape", "square.grid.2x2", "info.circle"]
    private var navButtons: [NSButton] = []
    private let navHighlight = NSView()
    private var selectedTab = 0

    private let sidebarView = NSView()
    private let generalView = NSView()
    private let layoutView = NSView()
    private let aboutView = NSView()

    // 几何常量：窗口 640×640（原 560，新增「空闲统计口径」一行后加高 80），
    // 右侧内容区 172..620。所有子视图仍按 content.bounds 换算，不越界。
    private let kSidebarWidth: CGFloat = 156
    private let kContentX: CGFloat = 172
    private let kContentWidth: CGFloat = 448
    private let kCardPad: CGFloat = 16
    private let kSwitchWidth: CGFloat = 52
    private let kSwitchHeight: CGFloat = 28
    /// 所有开关统一右对齐到这个 x（在右侧内容视图坐标系里）。
    private var kSwitchX: CGFloat { kContentX + kContentWidth - kCardPad - kSwitchWidth }

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 640),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "WorkBar 设置"
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        buildContent()
    }

    /// 显示窗口并把它带到最前。
    func show() {
        guard let window = window else { return }
        // 每次打开都同步一次，避免「用 UserDefaults 手改过」后界面显示与实际不一致。
        minimalSwitch.state = Settings.minimalMode ? .on : .off
        detailSwitch.state = Settings.taskDetailByDefault ? .on : .off
        stepSwitch.state = Settings.showTaskStep ? .on : .off
        graphicIconSwitch.state = Settings.graphicContextIcon ? .on : .off
        keepAwakeSwitch.state = Settings.keepAwake ? .on : .off
        idleCreditsPopup.selectItem(at: Settings.idleCreditsMode == .todayTotal ? 0 : 1)
        layoutItems = Settings.layoutOrder
        syncLayoutControls()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - 搭建双栏骨架

    private func buildContent() {
        guard let content = window?.contentView else { return }

        // 三个分类内容视图先铺好（都在窗口内），最后盖 sidebar，
        // 保证点击左侧导航不会落到下层内容视图上。
        let tabFrame = NSRect(x: kContentX, y: 0,
                              width: kContentWidth, height: content.bounds.height)
        generalView.frame = tabFrame
        layoutView.frame = tabFrame
        aboutView.frame = tabFrame
        content.addSubview(generalView)
        content.addSubview(layoutView)
        content.addSubview(aboutView)

        buildGeneralView()
        buildLayoutView()
        buildAboutView()
        buildSidebar(in: content)
        selectTab(0)

        syncLayoutControls()
    }

    private func buildSidebar(in content: NSView) {
        sidebarView.frame = NSRect(x: 0, y: 0,
                                   width: kSidebarWidth, height: content.bounds.height)
        sidebarView.wantsLayer = true
        sidebarView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let separator = NSBox(frame: NSRect(x: kSidebarWidth - 1, y: 0,
                                            width: 1, height: content.bounds.height))
        separator.boxType = .separator
        sidebarView.addSubview(separator)

        // 选中态高亮背景：放在按钮之前添加，保证在按钮下层。
        navHighlight.wantsLayer = true
        navHighlight.layer?.cornerRadius = 6
        navHighlight.layer?.backgroundColor = NSColor.selectedContentBackgroundColor.cgColor
        sidebarView.addSubview(navHighlight)

        let navTop = content.bounds.height - 32
        for (index, title) in navTitles.enumerated() {
            let button = NSButton(title: title, target: self, action: #selector(navClicked(_:)))
            button.tag = index
            button.bezelStyle = .rounded
            button.isBordered = false
            button.setButtonType(.momentaryPushIn)
            button.alignment = .left
            button.frame = NSRect(x: 14,
                                  y: navTop - 30 - CGFloat(index * 34),
                                  width: kSidebarWidth - 28,
                                  height: 28)
            sidebarView.addSubview(button)
            navButtons.append(button)
        }
        content.addSubview(sidebarView)
    }

    @objc private func navClicked(_ sender: NSButton) {
        selectTab(sender.tag)
    }

    private func selectTab(_ index: Int) {
        guard index >= 0, index < navTitles.count else { return }
        selectedTab = index
        generalView.isHidden = index != 0
        layoutView.isHidden = index != 1
        aboutView.isHidden = index != 2

        for (i, button) in navButtons.enumerated() {
            button.attributedTitle = Self.navTitle(navTitles[i],
                                                    symbol: navSymbols[i],
                                                    selected: i == index)
        }
        navHighlight.frame = navButtons[index].frame.insetBy(dx: -6, dy: -2)
    }

    /// 导航标题：图标 + 两个空格（约 8pt 间距）+ 文字，同行垂直居中。
    /// 系统符号不可用时只留文字，不画占位方块。
    private static func navTitle(_ title: String,
                                 symbol: String,
                                 selected: Bool) -> NSAttributedString {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: selected ? .semibold : .regular),
            .foregroundColor: NSColor.labelColor
        ]
        let result = NSMutableAttributedString()
        if let icon = navIcon(named: symbol) {
            let attachment = NSTextAttachment()
            attachment.image = icon
            attachment.bounds = NSRect(x: 0, y: -2, width: 15, height: 15)
            result.append(NSAttributedString(attachment: attachment))
            result.append(NSAttributedString(string: "  ", attributes: attributes))
        }
        result.append(NSAttributedString(string: title, attributes: attributes))
        return result
    }

    private static func navIcon(named symbol: String) -> NSImage? {
        guard #available(macOS 11.0, *) else { return nil }
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) else {
            return nil
        }
        image.size = NSSize(width: 14, height: 14)
        image.isTemplate = true
        return image
    }

    /// 浅灰圆角卡片 + 组内标题。返回卡片视图，行与分隔线都放进它内部。
    @discardableResult
    private func makeCard(in parent: NSView, frame: NSRect, title: String) -> NSView {
        let card = NSView(frame: frame)
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor.separatorColor.cgColor
        parent.addSubview(card)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.frame = NSRect(x: kCardPad,
                                  y: frame.height - kCardPad - 20,
                                  width: frame.width - 2 * kCardPad,
                                  height: 20)
        card.addSubview(titleLabel)
        return card
    }

    // MARK: - 常规页

    private func buildGeneralView() {
        let card = makeCard(in: generalView,
                            frame: NSRect(x: 0, y: 36, width: kContentWidth, height: 580),
                            title: "显示")

        var top = card.bounds.height - kCardPad - 20 - 12
        top = addGeneralRow(to: card, top: top,
                            title: "极简模式",
                            detail: "只显示一个状态摘要（几个在跑 / 待确认），隐藏任务条与今日统计。",
                            detailLines: 2,
                            toggle: minimalSwitch,
                            action: #selector(minimalModeToggled))
        top = addCardSeparator(to: card, top: top)

        top = addGeneralRow(to: card, top: top,
                            title: "默认详情模式",
                            detail: "任务条一出现就用两行详情展示（状态 · 模型 · 上下文 · 时长），"
                                  + "不用再点；点一下仍然可以收起。极简模式下不生效。",
                            detailLines: 2,
                            toggle: detailSwitch,
                            action: #selector(taskDetailModeToggled))
        top = addCardSeparator(to: card, top: top)

        top = addGeneralRow(to: card, top: top,
                            title: "任务步骤",
                            detail: "详情里加一段「做到第几步 · 当前在做什么」，"
                                  + "数据来自 WorkBuddy 自己的待办清单；没有待办清单的任务不显示。",
                            detailLines: 2,
                            toggle: stepSwitch,
                            action: #selector(showTaskStepToggled))
        top = addCardSeparator(to: card, top: top)

        top = addGeneralRow(to: card, top: top,
                            title: "图形上下文图标",
                            detail: "用真正绘制的圆环替代 `◔◑◒●` 字符。若 Touch Bar 上图标不显示，关掉本项即可。",
                            detailLines: 2,
                            toggle: graphicIconSwitch,
                            action: #selector(graphicIconToggled))
        top = addCardSeparator(to: card, top: top)

        top = addGeneralRow(to: card, top: top,
                            title: "常驻显示",
                            detail: "有任务在跑时定期补挂，减少被其他应用的 Touch Bar 顶掉；"
                                  + "切回本工具时也会自动回来。\n"
                                  + "注意：系统在无操作几分钟后仍会自动调暗/关闭 Touch Bar 背光，"
                                  + "这是系统行为，本工具不会为此阻止屏幕休眠。",
                            detailLines: 4,
                            toggle: keepAwakeSwitch,
                            action: #selector(keepAwakeToggled))
        top = addCardSeparator(to: card, top: top)

        idleCreditsPopup.addItems(withTitles: ["今日各轮之和", "本轮消耗"])
        idleCreditsPopup.font = .systemFont(ofSize: 11)
        addGeneralPopupRow(to: card, top: top,
                           title: "空闲统计口径",
                           detail: "今日累计 = 今天所有轮次消耗之和；本轮 = 最近一次消耗。",
                           detailLines: 2,
                           popup: idleCreditsPopup,
                           action: #selector(idleCreditsModeChanged))
    }

    /// 常规页一行：左侧标题 + 说明，右侧统一 x 的开关。
    @discardableResult
    private func addGeneralRow(to card: NSView,
                               top: CGFloat,
                               title: String,
                               detail: String,
                               detailLines: Int,
                               toggle: NSSwitch,
                               action: Selector) -> CGFloat {
        let titleHeight: CGFloat = 18
        // 11pt 字单行约 14pt，留 2pt 行距；再多给 4pt 让 descender 不被切。
        let detailHeight = CGFloat(detailLines) * 15 + 6
        let switchLocalX = kSwitchX - kContentX
        let textWidth = switchLocalX - kCardPad - 12

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.frame = NSRect(x: kCardPad, y: top - titleHeight,
                             width: textWidth, height: titleHeight)
        card.addSubview(label)

        toggle.target = self
        toggle.action = action
        toggle.frame = NSRect(x: switchLocalX, y: top - titleHeight - 5,
                              width: kSwitchWidth, height: kSwitchHeight)
        card.addSubview(toggle)

        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.maximumNumberOfLines = detailLines
        detailLabel.frame = NSRect(x: kCardPad,
                                   y: top - titleHeight - 6 - detailHeight,
                                   width: card.bounds.width - 2 * kCardPad,
                                   height: detailHeight)
        card.addSubview(detailLabel)

        return top - titleHeight - 6 - detailHeight - 12
    }

    /// 常规页的下拉行：左侧标题 + 说明，右侧下拉框的**右边缘**与开关统一右对齐。
    /// 单独写一个 helper 而不复用 `addGeneralRow`，是为了不动现有 5 行 NSSwitch 的几何
    /// （布局测试对它们的数量、右对齐 x、行距都有断言）。
    @discardableResult
    private func addGeneralPopupRow(to card: NSView,
                                    top: CGFloat,
                                    title: String,
                                    detail: String,
                                    detailLines: Int,
                                    popup: NSPopUpButton,
                                    action: Selector) -> CGFloat {
        let titleHeight: CGFloat = 18
        let detailHeight = CGFloat(detailLines) * 15 + 6
        let popupWidth: CGFloat = 132
        let popupHeight: CGFloat = 24
        // 下拉框比开关宽，用右边缘对齐 kSwitchX+kSwitchWidth 保证视觉同一列。
        let popupLocalX = kSwitchX - kContentX + kSwitchWidth - popupWidth
        let textWidth = popupLocalX - kCardPad - 12

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.frame = NSRect(x: kCardPad, y: top - titleHeight,
                             width: textWidth, height: titleHeight)
        card.addSubview(label)

        popup.target = self
        popup.action = action
        popup.frame = NSRect(x: popupLocalX, y: top - titleHeight - 3,
                             width: popupWidth, height: popupHeight)
        card.addSubview(popup)

        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.maximumNumberOfLines = detailLines
        detailLabel.frame = NSRect(x: kCardPad,
                                   y: top - titleHeight - 6 - detailHeight,
                                   width: card.bounds.width - 2 * kCardPad,
                                   height: detailHeight)
        card.addSubview(detailLabel)

        return top - titleHeight - 6 - detailHeight - 12
    }

    @discardableResult
    private func addCardSeparator(to card: NSView, top: CGFloat) -> CGFloat {
        let line = NSBox(frame: NSRect(x: kCardPad, y: top,
                                       width: card.bounds.width - 2 * kCardPad, height: 1))
        line.boxType = .separator
        card.addSubview(line)
        return top - 12
    }

    // MARK: - 布局页

    private func buildLayoutView() {
        // 卡片一：Touch Bar 项（4 行名称 + 统一 x 开关 + 紧邻的上下箭头）
        let itemsCard = makeCard(in: layoutView,
                                 frame: NSRect(x: 0, y: 296, width: kContentWidth, height: 240),
                                 title: "Touch Bar 项")

        let sectionHint = NSTextField(labelWithString: "开关控制显示 / 隐藏，↑↓ 调整顺序；宽度固定不变。")
        sectionHint.font = .systemFont(ofSize: 11)
        sectionHint.textColor = .secondaryLabelColor
        sectionHint.frame = NSRect(x: kCardPad,
                                   y: itemsCard.bounds.height - kCardPad - 20 - 8 - 16,
                                   width: itemsCard.bounds.width - 2 * kCardPad,
                                   height: 16)
        itemsCard.addSubview(sectionHint)

        var top = itemsCard.bounds.height - kCardPad - 20 - 8 - 16 - 8
        for index in 0..<Settings.defaultLayoutOrder.count {
            top = addLayoutRow(to: itemsCard, top: top, index: index)
        }

        // 卡片二：预览（空闲态开关 + 微缩预览 + 提示 + 恢复默认）
        let previewCard = makeCard(in: layoutView,
                                   frame: NSRect(x: 0, y: 70, width: kContentWidth, height: 210),
                                   title: "预览")

        let modeLabel = NSTextField(labelWithString: "预览空闲态")
        modeLabel.font = .systemFont(ofSize: 11)
        modeLabel.frame = NSRect(x: kCardPad,
                                 y: previewCard.bounds.height - kCardPad - 20 - 10 - 18,
                                 width: 200, height: 18)
        previewCard.addSubview(modeLabel)
        previewModeSwitch.target = self
        previewModeSwitch.action = #selector(previewModeToggled)
        previewModeSwitch.frame = NSRect(x: kSwitchX - kContentX,
                                         y: previewCard.bounds.height - kCardPad - 20 - 10 - 18 - 5,
                                         width: kSwitchWidth, height: kSwitchHeight)
        previewCard.addSubview(previewModeSwitch)

        layoutPreview.frame = NSRect(x: kCardPad,
                                     y: previewCard.bounds.height - kCardPad - 20 - 10 - 18 - 8 - 48,
                                     width: previewCard.bounds.width - 2 * kCardPad,
                                     height: 48)
        previewCard.addSubview(layoutPreview)

        previewHintLabel.font = .systemFont(ofSize: 10)
        previewHintLabel.textColor = .secondaryLabelColor
        previewHintLabel.frame = NSRect(x: kCardPad,
                                        y: previewCard.bounds.height - kCardPad - 20 - 10 - 18 - 8 - 48 - 8 - 16,
                                        width: previewCard.bounds.width - 2 * kCardPad,
                                        height: 16)
        previewCard.addSubview(previewHintLabel)

        let reset = NSButton(title: "恢复默认布局",
                             target: self,
                             action: #selector(resetLayout))
        reset.bezelStyle = .rounded
        reset.font = .systemFont(ofSize: 11)
        reset.frame = NSRect(x: kCardPad,
                             y: previewCard.bounds.height - kCardPad - 20 - 10 - 18 - 8 - 48 - 8 - 16 - 10 - 24,
                             width: 120, height: 24)
        previewCard.addSubview(reset)
    }

    /// 一行 DIY 布局项：名称在左，开关统一右对齐，紧邻的 ↑↓ 在开关左侧。
    @discardableResult
    private func addLayoutRow(to card: NSView, top: CGFloat, index: Int) -> CGFloat {
        let rowHeight: CGFloat = 38
        let controlCenterY = top - rowHeight / 2
        let switchLocalX = kSwitchX - kContentX
        let arrowSide: CGFloat = 30

        let name = NSTextField(labelWithString: "")
        name.font = .systemFont(ofSize: 12)
        name.frame = NSRect(x: kCardPad,
                            y: controlCenterY - 9,
                            width: switchLocalX - 2 * arrowSide - 14 - kCardPad - 8,
                            height: 18)
        card.addSubview(name)
        layoutNameLabels.append(name)

        let toggle = NSSwitch()
        toggle.frame = NSRect(x: switchLocalX,
                              y: controlCenterY - kSwitchHeight / 2,
                              width: kSwitchWidth, height: kSwitchHeight)
        toggle.target = self
        toggle.action = #selector(layoutToggle(_:))
        card.addSubview(toggle)
        layoutSwitches.append(toggle)

        let up = Self.chevronButton(symbol: "chevron.up", fallback: "↑",
                                    target: self, action: #selector(layoutMoveUp(_:)))
        up.frame = NSRect(x: switchLocalX - 10 - arrowSide,
                          y: controlCenterY - 13,
                          width: arrowSide, height: 26)
        card.addSubview(up)
        layoutUpButtons.append(up)

        let down = Self.chevronButton(symbol: "chevron.down", fallback: "↓",
                                      target: self, action: #selector(layoutMoveDown(_:)))
        down.frame = NSRect(x: switchLocalX - 10 - arrowSide - 4 - arrowSide,
                            y: controlCenterY - 13,
                            width: arrowSide, height: 26)
        card.addSubview(down)
        layoutDownButtons.append(down)

        return top - rowHeight
    }

    /// SF Symbols 箭头（14pt）；系统符号不可用时降级成文字箭头。
    private static func chevronButton(symbol: String,
                                      fallback: String,
                                      target: Any?,
                                      action: Selector) -> NSButton {
        if #available(macOS 11.0, *) {
            if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
                image.size = NSSize(width: 14, height: 14)
                // 只有浅色圆角底 + 符号，不再画「方块里的小箭头」；30×26 热区保持不变。
                let button = NSButton(image: image, target: target, action: action)
                button.imagePosition = .imageOnly
                button.bezelStyle = .rounded
                button.isBordered = false
                button.contentTintColor = .secondaryLabelColor
                button.wantsLayer = true
                button.layer?.cornerRadius = 5
                button.layer?.backgroundColor = NSColor.quaternaryLabelColor
                    .withAlphaComponent(0.14).cgColor
                return button
            }
        }
        let button = NSButton(title: fallback, target: target, action: action)
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 16, weight: .semibold)
        return button
    }

    // MARK: - 关于页

    /// 项目 GitHub 地址（关于页展示，可点击）。
    ///
    /// - Note: 为空时关于页不显示这一行，避免给出点不开的假链接。
    ///   该 URL 已实测可访问（仓库公开、默认分支 main）。
    private static let gitHubURL = "https://github.com/Miragic/WorkBar"

    private func buildAboutView() {
        let card = makeCard(in: aboutView,
                            frame: NSRect(x: 0, y: 300, width: kContentWidth, height: 236),
                            title: "关于")

        let appName = NSTextField(labelWithString: "WorkBar")
        appName.font = .systemFont(ofSize: 18, weight: .semibold)
        appName.frame = NSRect(x: kCardPad, y: card.bounds.height - kCardPad - 20 - 12 - 22,
                               width: card.bounds.width - 2 * kCardPad, height: 22)
        card.addSubview(appName)

        let version = NSTextField(labelWithString: "版本 \(Self.appVersion())")
        version.font = .systemFont(ofSize: 11)
        version.textColor = .secondaryLabelColor
        version.frame = NSRect(x: kCardPad, y: appName.frame.minY - 8 - 16,
                               width: card.bounds.width - 2 * kCardPad, height: 16)
        card.addSubview(version)

        let description = NSTextField(labelWithString: "为 Touch Bar 上的 WorkBuddy 状态监控而做。")
        description.font = .systemFont(ofSize: 12)
        description.textColor = .secondaryLabelColor
        description.frame = NSRect(x: kCardPad, y: version.frame.minY - 16 - 18,
                                   width: card.bounds.width - 2 * kCardPad, height: 18)
        card.addSubview(description)

        let author = NSTextField(labelWithString: "作者：Miragic")
        author.font = .systemFont(ofSize: 12)
        author.textColor = .secondaryLabelColor
        author.frame = NSRect(x: kCardPad, y: description.frame.minY - 10 - 18,
                              width: card.bounds.width - 2 * kCardPad, height: 18)
        card.addSubview(author)

        // Git 地址：用可点击的链接样式；常量为空时整行不显示。
        let urlString = Self.gitHubURL
        if !urlString.isEmpty, let url = URL(string: urlString) {
            let link = NSTextField(labelWithString: "")
            link.font = .systemFont(ofSize: 12)
            link.isSelectable = true
            link.allowsEditingTextAttributes = true
            link.attributedStringValue = NSAttributedString(
                string: "源码：\(urlString)",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12),
                    .foregroundColor: NSColor.linkColor,
                    .link: url
                ])
            link.frame = NSRect(x: kCardPad, y: author.frame.minY - 10 - 18,
                                width: card.bounds.width - 2 * kCardPad, height: 18)
            card.addSubview(link)
        }
    }

    private static func appVersion() -> String {
        if let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           !value.isEmpty {
            return value
        }
        return "0.1.0"
    }

    private static func name(for id: String) -> String {
        switch id {
        case "summary": return "状态摘要"
        case "task": return "任务条"
        case "stats": return "今日统计"
        case "voice": return "语音按钮"
        default: return id
        }
    }

    /// 把本地镜像同步到所有控件与预览（含按钮可用状态、模式提示）。
    private func syncLayoutControls() {
        for (index, item) in layoutItems.enumerated() {
            guard index < layoutSwitches.count else { break }
            layoutNameLabels[index].stringValue = Self.name(for: item.id)
            layoutSwitches[index].state = item.enabled ? .on : .off
            layoutSwitches[index].tag = index
            layoutUpButtons[index].tag = index
            layoutUpButtons[index].isEnabled = index > 0
            layoutDownButtons[index].tag = index
            layoutDownButtons[index].isEnabled = index < layoutItems.count - 1
        }
        layoutPreview.layout = layoutItems
        layoutPreview.isIdle = previewIsIdle
        // 上方四个开关也反映到预览：极简、详情两行、任务步骤、图形圆环。
        // keepAwake 只影响屏幕常亮，不改变 bar 内容，所以这里刻意不同步。
        layoutPreview.minimalMode = Settings.minimalMode
        layoutPreview.detailExpanded = Settings.taskDetailByDefault
        layoutPreview.showTaskStep = Settings.showTaskStep
        layoutPreview.graphicContextIcon = Settings.graphicContextIcon
        previewModeSwitch.state = previewIsIdle ? .on : .off
        if Settings.minimalMode {
            previewHintLabel.stringValue = "极简模式：只显示摘要 + 语音"
        } else {
            previewHintLabel.stringValue = previewIsIdle
                ? "当前预览：空闲态（显示今日统计，隐藏任务条）"
                : "当前预览：工作态（显示任务条，隐藏今日统计）"
        }
    }

    /// 写回设置 → 触发通知与实时重建 → 同步预览。
    private func commitLayout() {
        Settings.layoutOrder = layoutItems
        syncLayoutControls()
        onSettingsChanged?()
    }

    @objc private func layoutToggle(_ sender: NSSwitch) {
        let index = sender.tag
        guard layoutItems.indices.contains(index) else { return }
        layoutItems[index].enabled = (sender.state == .on)
        commitLayout()
    }

    @objc private func layoutMoveUp(_ sender: NSButton) {
        let index = sender.tag
        guard index > 0, index < layoutItems.count else { return }
        layoutItems.swapAt(index, index - 1)
        commitLayout()
    }

    @objc private func layoutMoveDown(_ sender: NSButton) {
        let index = sender.tag
        guard index >= 0, index < layoutItems.count - 1 else { return }
        layoutItems.swapAt(index, index + 1)
        commitLayout()
    }

    @objc private func resetLayout() {
        layoutItems = Settings.defaultLayoutOrder
        commitLayout()
    }

    @objc private func previewModeToggled(_ sender: NSSwitch) {
        previewIsIdle = (sender.state == .on)
        syncLayoutControls()
    }

    @objc private func minimalModeToggled() {
        Settings.minimalMode = (minimalSwitch.state == .on)
        syncLayoutControls() // 预览实时跟随
        onSettingsChanged?()
    }

    @objc private func taskDetailModeToggled() {
        Settings.taskDetailByDefault = (detailSwitch.state == .on)
        syncLayoutControls()
        onSettingsChanged?()
    }

    @objc private func showTaskStepToggled() {
        Settings.showTaskStep = (stepSwitch.state == .on)
        syncLayoutControls()
        onSettingsChanged?()
    }

    @objc private func graphicIconToggled() {
        Settings.graphicContextIcon = (graphicIconSwitch.state == .on)
        syncLayoutControls()
        onSettingsChanged?()
    }

    @objc private func keepAwakeToggled() {
        Settings.keepAwake = (keepAwakeSwitch.state == .on)
        onSettingsChanged?()
    }

    @objc private func idleCreditsModeChanged(_ sender: NSPopUpButton) {
        Settings.idleCreditsMode = (sender.indexOfSelectedItem == 0) ? .todayTotal : .latest
        // 走 applySettingsChange → refresh(forceRebuild: true) → 重取 idleStats，
        // 空闲统计立刻按新口径重算并重建 bar，不必等下一轮轮询。
        onSettingsChanged?()
    }
}

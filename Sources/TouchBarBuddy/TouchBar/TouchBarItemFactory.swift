import AppKit
import QuartzCore

/// 瞬时提示（2 秒后由控制器清除）。
///
/// 为什么把三种语义放进同一个类型、同一个 item 位：
/// Touch Bar 可用宽度只有约 290pt，已经被 summary + stats + voice 占满，
/// **挤不出第二个提示位**（再多一个 item，priority 最低的 stats 会被系统整块隐藏）。
/// 所以三档共用一格，只换颜色与文案。
///
/// - Important: `style` 不是纯装饰 —— `.error` 用项目统一的错误红（#E05B5B），
///   `.comfort` 用 `secondaryLabelColor`，`.info` 用 `labelColor`。
///   **安慰不能是红的**、**识别回显不能是灰的**：前者会让人以为出事了，
///   后者会让人以为回显是一句「没事」的安慰，而不是系统真实听到的话。
struct TransientNotice: Equatable {

    /// 提示语气。
    enum Style: Equatable {
        /// 真错误：需要用户处理（未授权 / 找不到输入框 / AX 忙）。
        case error
        /// 安慰：已经失败但不必处理，只是给个台阶。
        case comfort
        /// 识别回显：把语音识别到的原文短暂显示给用户看，正常文字色。
        ///
        /// - Note: 不是错误也不是安慰，所以既不能红也不能灰；
        ///   而且长度必须受限（见 `TouchBarController.transcriptNoticeText`），
        ///   否则这一格 prepend 到最左会把 voice 挤掉。
        case info
    }

    /// 展示文案。
    let text: String
    /// 语气（决定颜色）。
    let style: Style
}

/// 详情视图第二行的一段文字。
///
/// - Note: 除了 `text` / `isWarning`，这里多存了一个 `kind`。原因不是冗余，
///   而是**宽度裁剪需要认出「哪一段是模型」**：只有 3 段时（`状态 · 模型 · 上下文` 与
///   `状态 · 上下文 · 时长`）光看文本无法区分模型与时长，按位置猜会在将来插入新段时
///   静默丢错段 —— 而「上下文」是这一段里唯一必须永远保留的新信息。
///   显式带上 `kind` 后，裁剪规则（先丢模型、再丢时长）就有了可靠依据。
struct TaskMetaSegment {

    /// 段的种类：决定宽度不够时「先丢谁」。
    enum Kind {
        /// 状态（进行中 / 待确认 …）——**永不裁剪**。
        case status
        /// 模型可读名 —— 宽度不够时第一个被丢（WorkBuddy 界面里本来就看得到）。
        case model
        /// 当前步骤（`3/8 核实粉丝数`）—— 宽度不够时第三个被丢。
        case step
        /// 本轮已消耗积分（`◇ 10.56`）—— 宽度不够时第四个被丢。
        case credit
        /// 上下文占用 ——**永不裁剪**，是本功能的核心信息。
        case context
        /// 时长（`12s` / `3m`）—— 宽度不够时第二个被丢。
        case age
    }

    /// 段种类。
    let kind: Kind
    /// 段文本（不含分隔符）。
    let text: String
    /// 该段是否要用警告色（目前只有「上下文快满了」会用）。
    let isWarning: Bool
    /// 步骤段的进度比例（0...1）；只有 `.step` 段且数据有效时非 nil。
    ///
    /// - Note: 进度条是独立视图，这里只携带「画多少」；文案仍由 `TaskStep.segmentText`
    ///   单一真源给出，两者用 `TaskStep.progress` 同一套有效性判据。
    let progress: Double?

    init(kind: Kind, text: String, isWarning: Bool = false, progress: Double? = nil) {
        self.kind = kind
        self.text = text
        self.isWarning = isWarning
        self.progress = progress
    }
}

/// Touch Bar item 构建器：根据状态与当前聚焦任务生成 `NSTouchBarItem`。
///
/// item 标识符内嵌 `generation`，每次重建都使用新标识符，从而绕过 NSTouchBar 对
/// 相同 identifier 的 item 缓存，保证状态变化后能真正刷新内容。
enum TouchBarItemFactory {

    /// 视图与控制器之间的回调集合。
    struct Handlers {
        /// 点击概要（待确认时）=> 跳转激活 WorkBuddy。
        var onJump: () -> Void
        /// 点击语音按钮 => 开始/结束录音。
        var onVoiceToggle: () -> Void
        /// 横滑切换任务：+1 下一个 / -1 上一个。
        var onSwipe: (Int) -> Void
        /// 点任务条 => 在紧凑 / 详情两套布局之间切换。
        ///
        /// - Note: 带默认空实现，避免破坏既有构造点（历史上有测试直接构造过 `Handlers`）。
        var onTaskToggle: () -> Void = {}
        /// 点击弹层选项 => 按该文本去按 WorkBuddy 弹层里对应的按钮。
        var onDialogOption: (String) -> Void
        /// 点权限屏 1 的标题 / 屏 2 的「返回」=> 在两屏之间切换。
        var onPermissionDetail: () -> Void
        /// 点某个权限勾选项 => 按该标签去切换 WorkBuddy 里的勾选框（状态以重新读取为准）。
        var onPermissionToggle: (String) -> Void
        /// 点「✅ 允许」=> 按当前勾选集合授权（真的去按 WorkBuddy 的允许按钮）。
        var onPermissionAllow: () -> Void
        /// 点「✕ 取消」=> 全部不授权。
        var onPermissionCancel: () -> Void
        /// 点 Control Strip（系统栏）里的 WorkBar logo => 重新挂载常驻 bar。
        ///
        /// - Note: 带默认空实现，理由同 `onTaskToggle` —— 不能让这个纯新增回调
        ///   把所有既有 `Handlers(...)` 构造点（含单测）一起改掉。
        var onTrayTap: () -> Void = {}
    }

    /// Control Strip（Touch Bar 最右侧系统栏）里那个「重开入口」图标的标识符。
    ///
    /// ## 为什么需要它
    /// `presentSystemModalTouchBar` 的第五个参数就是 `systemTrayItemIdentifier`：
    /// 系统会在 Control Strip 区域为它留一个**常驻**格子。用户点右侧的「×」把整条
    /// bar 关掉之后，bar 的 item 全部消失，但这个格子还在 —— 点它就能把 bar 唤回来，
    /// 于是「关闭 / 打开」变成用户可自行控制的手动开关。
    ///
    /// ## 为什么不放进 `defaultItemIdentifiers`
    /// 它属于 Control Strip，不属于应用区。若同时塞进应用区，会白吃掉约 30pt
    /// —— 本工具可用宽度只有约 290pt，这个代价不可能接受。
    /// 所以它只在系统主动来要这个标识符时才被构造（见 `makeItem` 的 `case "tray"`）。
    static let trayIdentifier = NSTouchBarItem.Identifier("tb.tray.0")

    /// 弹层态最多铺几个选项（与 `DialogDetector.optionLimit` 保持一致）。
    static let choiceOptionLimit = DialogDetector.optionLimit

    /// 权限屏 1 的标题最多显示几个字。
    ///
    /// - Note: 取 7 而不是 8，是实测出来的：`displayTitle` 对超长标题会补一个 `…`，
    ///   于是「8 字 + …」在 13pt 下是 154pt，加「✅ 允许 69 + ✕ 取消 60」= **286pt**，
    ///   超出 280pt 预算；7 字时降到约 273pt，留出余量。
    ///   真实标题「允许完全访问」只有 6 字，正常情况根本不会被截断。
    static let permissionTitleLimit = 7

    /// 权限屏 1 的按钮字号（标题 / 允许 / 取消）。
    static let permissionActionFontSize: CGFloat = 13

    /// 权限屏 2 的按钮字号。
    ///
    /// - Important: 必须比屏 1 小一档，原因不是审美而是**实测宽度**：
    ///   三个勾选项 + 返回共 4 个 item，每个 `NSButton` 自带约 10pt 内边距，
    ///   13pt 字号下 `✅ 文件操作=95 / ☐ 终端命令=86 / ☐ 访问互联网=99 / ‹ 返回=56`
    ///   合计 **336pt**，远超约 290pt 的可用宽度（会静默隐藏最右的项 —— 用户直接被卡在屏 2）。
    ///   11pt 时同一组降到 **272pt**（见 `permissionBackTitle` 的说明）。
    static let permissionCheckboxFontSize: CGFloat = 11

    /// 屏 2 的「返回」文案。
    ///
    /// - Note: 刻意只留箭头 `‹` 而不是「‹ 返回」：完整文案在 11pt 下也要 50pt，
    ///   会把屏 2 顶到 297pt（又超了）。`‹` 是系统里通行的返回符号，省下 25pt
    ///   换来 18pt 的宽度余量 —— 在 Touch Bar 上，「整条铺得下」比「多两个字」重要。
    static let permissionBackTitle = "‹"

    /// 依据状态生成 item 标识符列表。
    /// - Parameter notice: 非空时在首位插入一条瞬时提示 item（颜色由 `notice.style` 决定，2 秒后由控制器清除）。
    /// - Parameter idleStats: 空闲态时在 summary 之后插入统计 item。
    /// - Parameter permissions: 识别到的权限请求；非 nil 且处于 `.choice` 态时**接管弹层布局**。
    /// - Parameter permissionDetailShown: 权限屏 2（逐项勾选）是否展开。
    /// - Parameter layoutOrder: 用户 DIY 的显示 / 隐藏与顺序；只在非 choice 且非极简模式生效。
    /// - Note: `.choice` 态下**不出现** summary / stats / task，而是「标题 + 至多 3 个选项」，
    ///   因为此时 Touch Bar 上每一分宽度都该留给选项（用户唯一要做的事）。
    /// - Note: 权限弹窗要拆两屏，是因为原设计 694pt 是这个工具可用宽度（约 290pt）的 2.4 倍：
    ///   「三样勾选 + 允许 + 取消 + 标题」一屏怎么裁都放不下。拆成
    ///   「标题 / 允许 / 取消」与「三个勾选 / 返回」两屏后，每屏都在 280pt 以内。
    static func identifiers(for state: TouchBarState,
                            generation: Int,
                            notice: TransientNotice?,
                            idleStats: IdleStats,
                            permissions: PermissionRequest? = nil,
                            permissionDetailShown: Bool = false,
                            minimalMode: Bool = false,
                            layoutOrder: [Settings.LayoutItem]) -> [NSTouchBarItem.Identifier] {
        var ids: [NSTouchBarItem.Identifier] = []
        if notice != nil {
            ids.append(identifier("error", generation))
        }
        // 只有「非 choice 且非极简」这一条路径走 DIY 顺序；voice 的收尾追加也只对这两条路径生效
        // （choice / minimal 保持原有行为，不受用户布局影响）。
        let usesDiyOrder = state.choice == nil && !minimalMode
        if let choice = state.choice {
            if let permissions = permissions, !permissions.items.isEmpty {
                // 权限布局（两屏之一），不再铺普通 dopt。
                if permissionDetailShown {
                    for index in 0..<permissions.items.count {
                        ids.append(identifier("pcb\(index)", generation))
                    }
                    ids.append(identifier("pback", generation))
                } else {
                    ids.append(identifier("ptitle", generation))
                    ids.append(identifier("pallow", generation))
                    ids.append(identifier("pcancel", generation))
                }
            } else {
                ids.append(identifier("dtitle", generation))
                for index in 0..<min(choice.options.count, choiceOptionLimit) {
                    ids.append(identifier("dopt\(index)", generation))
                }
            }
        } else if minimalMode {
            // 极简模式（V8 一瞥型）：只留「摘要（一个数字 + 一个状态）」与语音，
            // 隐藏任务条与今日统计。`.choice` 态不受影响 —— 那是用户必须做选择的时候，
            // 少显示一个选项等于让流程卡住。DIY 顺序在极简模式下也不生效。
            ids.append(identifier("summary", generation))
        } else {
            // DIY 布局：只决定显示 / 隐藏与顺序，**不改任何 item 的宽度**。
            // task 与 stats 仍按状态互斥（idle → stats，其它 → task），规则与原来完全一致。
            for item in layoutOrder where item.enabled {
                switch item.id {
                case "summary":
                    ids.append(identifier("summary", generation))
                case "task":
                    if !state.isIdle { ids.append(identifier("task", generation)) }
                case "stats":
                    if state.isIdle { ids.append(identifier("stats", generation)) }
                case "voice":
                    ids.append(identifier("voice", generation))
                default:
                    break // 非法 id 由 Settings.layoutOrder 的 getter 拦掉，这里只做防御
                }
            }
        }
        if !usesDiyOrder {
            ids.append(identifier("voice", generation))
        }
        return ids
    }

    /// 解析标识符所属类别（去掉 generation 前缀）；非本工具标识符返回 nil。
    static func kind(of identifier: NSTouchBarItem.Identifier) -> String? {
        let raw = identifier.rawValue
        guard raw.hasPrefix("tb.") else { return nil }
        let parts = raw.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        return String(parts[1])
    }

    /// 构建单个 item。
    ///
    /// - Parameters:
    ///   - notice: 瞬时提示（决定是否插入提示 item 及其颜色）。
    ///   - face: 当前情绪脸（由控制器统一算好，含失败覆盖）。
    ///   - faceTransition: 本次重建是否要播过渡动效（只在脸刚变化时非 nil）。
    static func makeItem(
        identifier: NSTouchBarItem.Identifier,
        state: TouchBarState,
        focusedIndex: Int,
        isListening: Bool,
        notice: TransientNotice?,
        face: BuddyFace,
        faceTransition: BuddyFaceTransition?,
        idleStats: IdleStats,
        permissions: PermissionRequest? = nil,
        taskElapsed: TimeInterval? = nil,
        taskExpanded: Bool = false,
        graphicContextIcon: Bool = false,
        turnCredits: Double? = nil,
        showTaskStep: Bool = true,
        handlers: Handlers
    ) -> NSTouchBarItem? {
        let kindName = kind(of: identifier) ?? ""
        let item: NSTouchBarItem?
        if kindName.hasPrefix("dopt") {
            // `dopt0` / `dopt1` / `dopt2`：选项下标编在标识符里，delegate 才能知道该铺第几个。
            let index = Int(kindName.dropFirst("dopt".count)) ?? 0
            item = makeDialogOptionItem(identifier: identifier,
                                        state: state,
                                        index: index,
                                        handlers: handlers)
        } else if kindName.hasPrefix("pcb") {
            // `pcb0` / `pcb1` / `pcb2`：权限勾选项，下标同样编在标识符里。
            let index = Int(kindName.dropFirst("pcb".count)) ?? 0
            item = makePermissionCheckboxItem(identifier: identifier,
                                              permissions: permissions,
                                              index: index,
                                              handlers: handlers)
        } else {
            switch kindName {
            case "error":
                item = makeNoticeItem(identifier: identifier, notice: notice)
            case "summary":
                item = makeSummaryItem(identifier: identifier,
                                       state: state,
                                       focusedIndex: focusedIndex,
                                       face: face,
                                       transition: faceTransition,
                                       handlers: handlers)
            case "stats":
                item = makeStatsItem(identifier: identifier, idleStats: idleStats)
            case "task":
                item = makeTaskItem(identifier: identifier,
                                    state: state,
                                    focusedIndex: focusedIndex,
                                    elapsed: taskElapsed,
                                    expanded: taskExpanded,
                                    graphicRing: graphicContextIcon,
                                    credits: turnCredits,
                                    showTaskStep: showTaskStep,
                                    handlers: handlers)
            case "dtitle":
                item = makeDialogTitleItem(identifier: identifier, state: state)
            case "ptitle":
                item = makePermissionTitleItem(identifier: identifier,
                                               permissions: permissions,
                                               handlers: handlers)
            case "pallow":
                item = makePermissionActionItem(identifier: identifier,
                                                title: "✅ 允许",
                                                fontSize: permissionActionFontSize,
                                                onClick: handlers.onPermissionAllow)
            case "pcancel":
                item = makePermissionActionItem(identifier: identifier,
                                                title: "✕ 取消",
                                                fontSize: permissionActionFontSize,
                                                onClick: handlers.onPermissionCancel)
            case "pback":
                item = makePermissionActionItem(identifier: identifier,
                                                title: permissionBackTitle,
                                                fontSize: permissionCheckboxFontSize,
                                                onClick: handlers.onPermissionDetail)
            case "voice":
                item = makeVoiceItem(identifier: identifier,
                                     isListening: isListening,
                                     handlers: handlers)
            case "tray":
                // 只由系统在 Control Strip 侧询问（见 `trayIdentifier` 的说明）。
                item = makeTrayItem(onTap: handlers.onTrayTap)
            default:
                item = nil
            }
        }

        // 尺寸排障日志：Touch Bar 对自定义视图只认「非零尺寸」，
        // 0×0 会表现为整块不渲染（真机上出现过按钮消失、只剩 label 的现象）。
        // 用 TB_DEBUG=1 打开，避免平时刷屏。
        if let custom = item as? NSCustomTouchBarItem {
            // 关键：Touch Bar 宽度不足时，系统会**按 visibilityPriority 从低到高隐藏整个 item**。
            // 默认全是 .standard，于是末尾的「语音」按钮被最先挤掉（真机现象：文字都在，语音始终不出现）。
            // 这里显式定级：语音最高（核心交互，绝不可丢）、汇总次之、统计最低（可被牺牲）。
            //
            // 弹层态（.choice）的取舍不同：此时用户唯一要做的是「点某个选项」，
            // 所以选项给最高优先级，**语音主动降到 0** —— 宽度不够时先挤掉语音，保住选项。
            switch kindName {
            case "voice":
                custom.visibilityPriority = state.choice == nil
                    ? .high
                    : NSTouchBarItem.Priority(rawValue: 0)
            case "summary":
                // 摘要是「现在处于什么状态」的唯一入口，绝不能被系统压缩成「1..」。
                // 工作态 intrinsic 合计约 362pt（摘要 80~99 + 任务 200 + 语音 82）远超可用宽度，
                // 摘要与任务同为 0 时系统会压摘要的文字（用户真机看到只剩「1..」）。
                // 提到与语音同级（.high = 1000）：宽度紧张时牺牲可截断的任务标题，保住摘要完整。
                custom.visibilityPriority = .high
            case "dtitle", "ptitle":
                custom.visibilityPriority = NSTouchBarItem.Priority(rawValue: 0)
            // 「允许 / 取消 / 返回 / 勾选项」是权限屏上用户唯一能做的动作，
            // 一律最高：宽度真的不够时可以先把标题挤掉，但绝不能让用户没法做决定。
            case "pallow", "pcancel":
                custom.visibilityPriority = .high
            // 屏 2 的「返回」单独再抬一档。
            //
            // 为什么它要比其它权限项更高：`.high` 全都一样时，系统在等优先级里挑谁被牺牲
            // 并不保证。而屏 2 唯一的退出口就是它 —— 一旦被挤掉，用户会**卡在屏 2 出不来**，
            // 只能等弹窗自己消失，这是本套 UI 里最坏的失效模式。
            // 宁可少显示一个勾选项（用户还能回屏 1，或者直接去 WorkBuddy 里点），
            // 也不能让返回消失。1000 与语音按钮同级，本项目已真机验证过这个值能保住。
            case "pback":
                custom.visibilityPriority = NSTouchBarItem.Priority(rawValue: 1000)
            case "stats", "error":
                custom.visibilityPriority = .low
            default:
                if kindName.hasPrefix("dopt") || kindName.hasPrefix("pcb") {
                    custom.visibilityPriority = .high
                } else {
                    custom.visibilityPriority = NSTouchBarItem.Priority(rawValue: 0)
                }
            }
        }

        if ProcessInfo.processInfo.environment["TB_DEBUG"] == "1" {
            let label = kindName.isEmpty ? "?" : kindName
            if let custom = item as? NSCustomTouchBarItem {
                let v = custom.view
                tbLog("[TB] item=\(label) view=\(type(of: v)) frame=\(v.frame) intrinsic=\(v.intrinsicContentSize) priority=\(custom.visibilityPriority.rawValue)")
            } else {
                tbLog("[TB] item=\(label) <非 NSCustomTouchBarItem: \(String(describing: item))>")
            }
        }
        return item
    }

    // MARK: - 私有构建

    private static func identifier(_ kind: String, _ generation: Int) -> NSTouchBarItem.Identifier {
        NSTouchBarItem.Identifier("tb.\(kind).\(generation)")
    }

    /// 摘要区展示文案：去掉 `summaryLabel` 开头的状态 emoji。
    ///
    /// 为什么要去：情绪脸（🌙/👀/🙋/🎉/😞）已经由左侧图片表达同一件事，
    /// 再留 `summaryLabel` 自带的 emoji（◆/⏳/🟢/📬/❓）就是「两个 emoji 并排」——
    /// 视觉重复，而且每个 emoji 都要吃掉十几 pt 宽度。实测（`intrinsicContentSize`）：
    /// 保留前缀时「🟢 0 进行中 + 22pt 表情」= **108pt**，已越过 100pt 预算、会挤掉 stats；
    /// 去掉前缀后同一格只要 **87pt**，比现状（13pt「🟢 2 进行中」= 93pt）还窄。
    ///
    /// 规则：首个空格前的 token 长度 ≤ 2 个字符就当作状态图标丢掉；否则原文返回。
    /// 这样 `summaryLabel` 的格式将来若变了（比如没有图标前缀），这里不会误伤。
    ///
    /// - Parameters:
    ///   - state: 当前展示状态。
    ///   - focusedIndex: 当前聚焦的任务下标（只在**工作态且该任务已卡住**时用到）。
    ///     带默认值 0 是为了不破坏既有的纯文案单测 —— 它们只关心「去 emoji」规则。
    /// - Returns: 去掉图标前缀的文案（纯函数，便于单测）。
    static func summaryTitle(for state: TouchBarState, focusedIndex: Int = 0) -> String {
        // V25「卡住状态可读化」：工作态下聚焦任务超过阈值时，摘要要把那个橙色数字
        // 说清楚。判定统一走 `TaskInfo.isStale`，不在界面层重复写阈值。
        //
        // 仍走下面同一条「去 leading emoji」流程：「⚠️ N 疑似卡住」→「N 疑似卡住」，
        // 所以卡片宽度规则和普通态完全一致，不需要为新文案单开一条分支。
        let label: String
        if case .working(let tasks) = state, !tasks.isEmpty {
            let index = min(max(focusedIndex, 0), tasks.count - 1)
            label = tasks[index].isStale
                ? "⚠️ \(tasks.count) 疑似卡住"
                : state.summaryLabel
        } else {
            label = state.summaryLabel
        }
        guard let spaceIndex = label.firstIndex(of: " ") else { return label }
        let leading = label[label.startIndex..<spaceIndex]
        guard leading.count <= 2 else { return label }
        let rest = label[label.index(after: spaceIndex)...]
        let trimmed = rest.trimmingCharacters(in: .whitespaces)
        // 去掉前缀后不能变空，否则按钮会变成一张只有图标的空壳。
        return trimmed.isEmpty ? label : trimmed
    }

    private static func makeSummaryItem(
        identifier: NSTouchBarItem.Identifier,
        state: TouchBarState,
        focusedIndex: Int,
        face: BuddyFace,
        transition: BuddyFaceTransition?,
        handlers: Handlers
    ) -> NSTouchBarItem {
        let item = NSCustomTouchBarItem(identifier: identifier)
        // 表情嵌在摘要块里，**不新增 item**：290pt 已经铺满，多一个 item 会先挤掉
        // stats（visibilityPriority 最低），而它是空闲态唯一有信息量的东西。
        //
        // 承载方式从 `NSButton` 换成 `SummaryBarView` 容器：这样表情位图、点击跳转、
        // 宽度预算和 celebrate 缩放都在一处管（曾经的眨眼自绘视图已撤回，见 archive）。
        // 字号仍是 12pt：加 22pt 图标后必须从文字里省回宽度。
        // 实测（容器 intrinsicContentSize）：空闲 59 / 进行中 80 / 待读 68 / 疑似卡住 92 /
        // 最长「12 疑似卡住」99pt。整块宽度按文案自适应、上限 140pt，确保各状态文案完整；
        // 该 item 的 visibilityPriority 已提到 .high，避免系统把它挤成「1..」。
        // 显式传 frame 而不是 `SummaryBarView()`：`NSView` 的 `init()` 语义依赖
        // 系统实现（是否转发到 `init(frame:)` 并非契约），走指定初始化器最稳。
        // 尺寸随后由 `update(...)` 按文字实测宽度改写。
        let view = SummaryBarView(frame: NSRect(x: 0, y: 0,
                                                width: SummaryBarView.maxWidth,
                                                height: SummaryBarView.barHeight))
        view.update(title: summaryTitle(for: state, focusedIndex: focusedIndex), face: face)
        view.onClick = handlers.onJump
        item.view = view

        if let transition = transition {
            playFaceTransition(transition, on: view)
        }
        return item
    }

    /// 统一的 Touch Bar 按钮构造。
    ///
    /// - Important: 必须用 `NSButton(title:target:action:)` 工厂方法创建。
    ///   真机验证：用 `NSButton` **子类** + `init(frame:)` 创建的实例在 Touch Bar 上**完全不渲染**
    ///   （既不显示也不报错），而工厂方法创建的普通 `NSButton` 正常显示。
    ///   因此不要为了「闭包回调」而写 NSButton 子类，改用 `TouchBarActionHolder` 持有 target。
    /// - Note: 以前这里有个可选的 `face` 参数，用来把情绪脸当成 `NSButton.image` 贴上去。
    ///   现在摘要改成 `SummaryBarView` 容器（眼睛要眨眼，静态图做不到），
    ///   其余按钮都不需要图标，所以这个参数已经没有调用方，随之删掉 ——
    ///   留着只会让后来的人以为「按钮也能显示表情」。
    private static func makeTouchBarButton(title: String,
                                          onClick: (() -> Void)?) -> NSButton {
        let holder = TouchBarActionHolder(onClick ?? {})
        retainedHolders.append(holder)
        if retainedHolders.count > 16 { retainedHolders.removeFirst() }

        let button = NSButton(title: title,
                              target: holder,
                              action: #selector(TouchBarActionHolder.fire))
        button.bezelStyle = .rounded
        return button
    }

    /// 播放一次情绪过渡动效（只在脸刚发生变化的那次重建里调用）。
    ///
    /// - Important: 缩放走 `CALayer.transform` 而**不是** `NSView.animator().frame` ——
    ///   改 frame 会改变 item 的固有尺寸，把右边的 stats / 语音按钮顶来顶去；
    ///   layer transform 只影响绘制，不参与 Auto Layout / Touch Bar 的宽度分配。
    /// - Parameter view: 承载摘要的容器（每次重建都是新实例，动画不会叠加）。
    private static func playFaceTransition(_ transition: BuddyFaceTransition, on view: SummaryBarView) {
        switch transition {
        case .celebrate:
            // 下一轮 runloop 再播：此刻视图可能还没进 Touch Bar 的图层树，
            // 立即 add 的动画会随视图挂载被丢弃（真机上表现为「完全看不到」）。
            DispatchQueue.main.async {
                view.wantsLayer = true
                guard let layer = view.layer else { return }
                let bounce = CABasicAnimation(keyPath: "transform.scale")
                bounce.fromValue = 1.0
                bounce.toValue = 1.18
                bounce.duration = 0.1
                // autoreverses 让 0.1s 放大 + 0.1s 还原 = 总 200ms，一个动画搞定往返。
                bounce.autoreverses = true
                bounce.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                layer.add(bounce, forKey: "tb.celebrate")
            }

        case .console:
            // 文字变红 200ms 再恢复。
            // - Note: 以前是对 `NSButton.attributedTitle` 设红；换成 label 之后
            //   直接改 `textColor` 即可 —— 少一层 attributedString，也就少一类
            //   「带属性的标题把颜色永久污染」的问题（旧实现就踩过）。
            view.setTitleColor(.systemRed)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak view] in
                guard let view = view else { return }
                // 恢复成 labelColor（不是 secondaryLabelColor）：摘要文字的正常色
                // 比次要色亮，设成次要色会看起来永久偏灰。
                view.setTitleColor(.labelColor)
            }

        case .acknowledge:
            // 点击被接收的即时确认：同样的 200ms 短暂变色，但用设计色板的青绿
            // #3DDC97，而不是红色 —— 红在本项目里一直是「出错了要你处理」。
            //
            // - Note: 这里**只改颜色、不缩放、不加 item**：用户对视觉噪音敏感
            //   （眨眼动画和秒级 `●` 都被否掉了），一次 200ms 的文字变色是
            //   「我收到了」的最小信号，不占宽度、不挡住 right 侧的时长。
            view.setTitleColor(Palette.acknowledge)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak view] in
                guard let view = view else { return }
                // 与 `.console` 同一条恢复规则：回到 labelColor，不能写成次要色。
                view.setTitleColor(.labelColor)
            }
        }
    }

    /// 空闲态统计 item（今日完成数 + 消耗积分），按用户选的口径渲染。
    private static func makeStatsItem(
        identifier: NSTouchBarItem.Identifier,
        idleStats: IdleStats
    ) -> NSTouchBarItem {
        let item = NSCustomTouchBarItem(identifier: identifier)
        let label = NSTextField(labelWithString: idleStats.label(mode: Settings.idleCreditsMode))
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 12)
        label.alignment = .center
        item.view = label
        return item
    }

    /// 瞬时提示 item：`.error` 用项目统一的错误红（#E05B5B），`.comfort` 用次要色。
    ///
    /// - Note: 一个 style 一个颜色，**绝不让安慰走红色**：红色在本项目里一直表示
    ///   「需要你处理」（未授权 / 注入失败 / 按钮已消失），把「没关系，可以重试」染红
    ///   会让用户以为还有别的问题没解决。
    private static func makeNoticeItem(
        identifier: NSTouchBarItem.Identifier,
        notice: TransientNotice?
    ) -> NSTouchBarItem {
        let item = NSCustomTouchBarItem(identifier: identifier)
        let text = notice?.text ?? "出错了"
        let color: NSColor
        switch notice?.style ?? .error {
        case .error:
            color = Palette.error
        case .comfort:
            color = .secondaryLabelColor
        case .info:
            // 识别回显是「系统真实听到的话」，既不是错误也不是安慰 → 用正常文字色。
            // 用次要色会显得像一句附注，用户会以为那不是自己说的话。
            color = .labelColor
        }
        let button = makeTouchBarButton(title: text, onClick: nil)
        button.attributedTitle = NSAttributedString(
            string: text,
            attributes: [.foregroundColor: color]
        )
        item.view = button
        return item
    }

    /// 任务条 item 的固定宽度（pt）。紧凑/详情两视图共用，改这里一处即可。
    ///
    /// - Note: 真机探针显示 4 个 item 总宽约 450pt 也能完整显示，故宽度不是主要瓶颈，
    ///   取 200pt 兼顾任务标题可读性与布局余量（横滑切换仍可用）。
    ///   详情视图也不加宽 —— 换宽度会让整条 bar 重排，而详情只是「同一格里换两行」。
    static let taskItemWidth: CGFloat = 200

    private static func makeTaskItem(
        identifier: NSTouchBarItem.Identifier,
        state: TouchBarState,
        focusedIndex: Int,
        elapsed: TimeInterval?,
        expanded: Bool,
        graphicRing: Bool,
        credits: Double?,
        showTaskStep: Bool,
        handlers: Handlers
    ) -> NSTouchBarItem {
        let item = NSCustomTouchBarItem(identifier: identifier)
        let tasks = state.tasks
        let index = tasks.isEmpty ? 0 : min(max(focusedIndex, 0), tasks.count - 1)
        let task = tasks.isEmpty ? nil : tasks[index]

        // 宽度：见 `taskItemWidth`。
        // - Note: V13 的时长文案挤在这 200pt 内（右侧 32pt），标题可用宽度 168pt，**不加宽**。
        let view = TaskStripView(frame: NSRect(x: 0, y: 0,
                                               width: Self.taskItemWidth,
                                               height: 30))
        let meta = Self.taskMetaRendering(
            task: task,
            elapsed: elapsed,
            // 第二行能用的宽度 = item 宽度 - 左右内边距。
            // 与 `TaskStripView.layoutExpanded()` 里算的是同一个式子，
            // 后者负责「排版」，这里负责「裁剪文案」，两边必须一致。
            maxWidth: Self.taskItemWidth - TaskStripView.expandedHorizontalInset * 2,
            graphicRing: graphicRing,
            credits: credits,
            showTaskStep: showTaskStep)
        view.update(title: taskText(task: task, index: index, total: tasks.count),
                    activityAge: task?.activityAge,
                    elapsed: elapsed,
                    expanded: expanded,
                    meta: meta.attributed,
                    ringTint: Self.ringTint(for: task), rendering: meta)
        view.onSwipe = handlers.onSwipe
        view.onToggle = handlers.onTaskToggle
        item.view = view
        return item
    }

    /// 圆环颜色：上下文吃紧（≥75%）时转橙，否则跟第二行同色。
    ///
    /// - Note: 与「上下文百分比文字变橙」用同一个判据（`TaskInfo.isContextTight`），
    ///   否则会出现「圆环橙了但数字还是灰的」这种自相矛盾的画面。
    static func ringTint(for task: TaskInfo?) -> NSColor {
        (task?.isContextTight ?? false) ? .systemOrange : .secondaryLabelColor
    }

    /// 详情视图第二行的段间分隔符。
    ///
    /// - Note: 富文本里分隔符也要单独着色（次要色），所以它必须是一个具名常量：
    ///   一处定义，`fittedMetaSegments` 的宽度估算与 `taskMetaAttributedText` 的拼接
    ///   都读它，否则「估算宽度」与「实际宽度」会随分隔符改动悄悄走岔。
    static let metaSeparator = " · "

    /// 详情视图第二行纯文本（= 富文本的 `.string`，保留给单测断言）。
    ///
    /// - Important: 签名与行为对既有调用方 / 既有单测保持不变：
    ///   `maxWidth: nil` 表示不裁剪，输出仍然是「状态 · 模型 · 上下文 · 时长」全段。
    ///   改造前它返回 `"进行中 · 混元 4 · 12s"`，改造后（任务无 contextUsage 时）逐字相同。
    ///
    /// - Parameters:
    ///   - task: 当前聚焦任务；nil（无任务）时返回空串，第二行留空。
    ///   - elapsed: 本次运行已持续秒数；nil 时省略时长段。
    /// - Returns: 用 `" · "` 连接的非空段。
    static func taskMetaText(task: TaskInfo?, elapsed: TimeInterval?, credits: Double? = nil) -> String {
        // 纯文本直接由段拼，不经过富文本：图形模式下上下文段会插入圆环附件，
        // 走 `.string` 会得到附件控制字符（￼）而不是文案。
        taskMetaSegments(task: task, elapsed: elapsed, credits: credits)
            .map(\.text)
            .joined(separator: metaSeparator)
    }

    /// 详情视图第二行各段（按显示顺序）。
    ///
    /// 顺序：状态 · 步骤 · 模型 · 上下文 · 时长。
    /// - 步骤紧跟状态：它是「Buddy 此刻在做什么」，重要性仅次于状态；
    ///   且它比模型长得多，放不下时先被裁的是模型，正好留下「状态 · 步骤 · 上下文 · 时长」。
    /// - 上下文排在时长之前：时长本身在变、且卡住判定另有橙色时长槽，
    ///   而上下文是这次新加的信息，排在前面才不会被尾部截断吃掉。
    ///
    /// 纯函数（`internal` 便于单测）：不含任何视图状态，输入一样就一定输出一样。
    ///
    /// - Parameters:
    ///   - task: 当前聚焦任务；nil 时返回空数组（第二行留空）。
    ///   - elapsed: 本次运行已持续秒数；nil 时省略时长段。
    /// - Returns: 非空段列表；每段自带「是否用警告色」。
    static func taskMetaSegments(task: TaskInfo?,
                                 elapsed: TimeInterval?,
                                 graphicRing: Bool = false,
                                 credits: Double? = nil,
                                 showTaskStep: Bool = true) -> [TaskMetaSegment] {
        guard let task = task else { return [] }
        var segments: [TaskMetaSegment] = [
            TaskMetaSegment(kind: .status, text: statusText(task.status))
        ]

        // 当前步骤：只有开启设置且该会话确实有待办清单时才非 nil（provider 已经过滤）。
        // 文案形如 `3/8 核实粉丝数`，没有进行中的步骤时只有 `3/8`。
        // `showTaskStep` 是显式第二道闸：provider 已在开关关闭时把 `stepProgress` 置 nil，
        // 这里再 gate 一次，保证即便有脏数据带进来也不会偷偷显示步骤 / 进度条。
        if showTaskStep, let step = TaskStep.segmentText(task.stepProgress) {
            segments.append(TaskMetaSegment(kind: .step, text: step,
                                            progress: TaskStep.progress(task.stepProgress)))
        }

        // 模型名：优先用 provider 已算好的展示名，退化到 ModelCatalog 现算；
        // 两者都空就整段省略 —— 显示「未知模型」比不显示更糟（用户会以为模型识别错了）。
        if let model = ModelCatalog.displayName(for: task.modelDisplayName ?? task.model),
           !model.isEmpty {
            segments.append(TaskMetaSegment(kind: .model, text: model))
        }

        // 积分：本轮已消耗（WorkBuddy 界面「已消耗 ◇ 10.56」）。
        // 排在模型之后、上下文之前，与用户在需求里给的顺序一致。
        if let credit = TurnDurationReader.formatCredits(credits) {
            segments.append(TaskMetaSegment(kind: .credit, text: credit))
        }

        // 上下文占用：无数据（nil）时整段省略，绝不显示「上下文 --」占位符。
        // 警告色只在达到阈值时才用 —— 常态（实测峰值 52.8%）它必须是安静的次要色。
        if let context = ContextUsage.format(task.contextUsage, graphic: graphicRing) {
            segments.append(TaskMetaSegment(kind: .context,
                                            text: context,
                                            isWarning: task.isContextTight))
        }

        // 时长：复用 ActivityAge 的秒档格式化，**不改动它的任何规则**。
        if let age = ActivityAge.formatActivityAge(elapsed) {
            segments.append(TaskMetaSegment(kind: .age, text: age))
        }
        return segments
    }

    /// 宽度感知地挑选能放下的段。
    ///
    /// 规则（保证**永远保留**「状态」与「上下文」，二者是这一行的核心）：
    /// 1. 先试全部段；
    /// 2. 放不下 → **先把模型名缩短**（保留 `…`，认得出是哪个模型），见 `shortenedModel`；
    /// 3. 缩到最短仍放不下 → 丢模型段；
    /// 4. 还放不下 → 丢时长段；
    /// 5. 还放不下 → 丢步骤段。
    ///
    /// - Important: 第 2 步是 2026-11-19 真机反馈的修复。之前「放不下就整段丢模型」，
    ///   实测 `DeepSeek V4.1 Flash` 那一行宽 **197.1pt**、预算 **196pt**，只超 1.1pt，
    ///   于是模型在几pt 的边界上反复「显示 → 消失」。缩短 1~2 个字符就能解决，
    ///   不该为此把整段信息丢掉。
    ///
    /// 宽度用 `TouchBarTextMetrics.textWidth(_:font:)` 按 `expandedMetaFontSize` 估算，
    /// 段间分隔符是 `" · "`。
    ///
    /// - Parameters:
    ///   - segments: 待裁剪的段（顺序即显示顺序）。
    ///   - font: 第二行字体（宽度估算基准）。
    ///   - maxWidth: 可用宽度上限（pt）；nil 表示不裁剪（单测用）。
    /// - Returns: 能放下的段；即使全部放不下也至少返回「状态 + 上下文」。
    static func fittedMetaSegments(_ segments: [TaskMetaSegment],
                                   font: NSFont,
                                   maxWidth: CGFloat?,
                                   graphicRing: Bool = false) -> [TaskMetaSegment] {
        // nil 或非正宽度 = 「不做裁剪」（单测与 `taskMetaText` 走这条路径）。
        guard let maxWidth = maxWidth, maxWidth > 0 else { return segments }

        /// 带进度段的段列表额外要占的宽度：细条本身 + 与后缀之间的一道间隙。
        /// 这是 V13 的真实宽度成本，必须计入裁剪预算，否则会挤掉状态 / 上下文环。
        func barCost(of list: [TaskMetaSegment]) -> CGFloat {
            list.contains { $0.progress != nil }
                ? StepProgressView.barWidth + TaskStripView.contextRingGap
                : 0
        }

        /// 一组段渲染出来的总宽度（含分隔符与进度条 —— 都占地方）。
        func width(of list: [TaskMetaSegment]) -> CGFloat {
            guard !list.isEmpty else { return 0 }
            let extra = barCost(of: list)
            if graphicRing, let index = list.firstIndex(where: { $0.kind == .context }) {
                let prefix = list[..<index].map(\.text).joined(separator: metaSeparator)
                    + (index > 0 ? metaSeparator : "")
                let suffix = list[index...].map(\.text).joined(separator: metaSeparator)
                return TaskStripView.metaFieldWidth(NSAttributedString(string: prefix, attributes: [.font: font]))
                    + ContextRingView.side + TaskStripView.contextRingGap
                    + extra
                    + TaskStripView.metaFieldWidth(NSAttributedString(string: suffix, attributes: [.font: font]))
            }
            let text = list.map(\.text).joined(separator: metaSeparator)
            return TouchBarTextMetrics.textWidth(text, font: font) + extra
        }

        if width(of: segments) <= maxWidth { return segments }

        // 第 2 步：尽量缩短模型名而不是整段丢掉。
        if let modelIndex = segments.firstIndex(where: { $0.kind == .model }) {
            let others = segments.enumerated()
                .filter { $0.offset != modelIndex }
                .map(\.element)
            // 模型夹在中间，除了它自己的宽度，还要额外占一个分隔符。
            let separatorWidth = TouchBarTextMetrics.textWidth(metaSeparator, font: font)
            let budget = maxWidth - width(of: others) - separatorWidth
            if let shortened = shortenedModel(segments[modelIndex], budget: budget, font: font) {
                var candidate = segments
                candidate[modelIndex] = shortened
                if width(of: candidate) <= maxWidth { return candidate }
            }
        }

        // 第 3 步：丢模型。
        let withoutModel = segments.filter { $0.kind != .model }
        if width(of: withoutModel) <= maxWidth { return withoutModel }

        // 第 4 步：丢时长；第 5 步：丢积分；第 6 步：丢步骤。
        // 最后只剩状态 + 上下文，不再继续裁 —— 这两段加起来在 8pt 下约 80pt，
        // 远小于 196pt；真放不下也只让它尾部被截断，而不是把「上下文」整段删掉。
        let withoutAge = withoutModel.filter { $0.kind != .age }
        if width(of: withoutAge) <= maxWidth { return withoutAge }
        let withoutCredit = withoutAge.filter { $0.kind != .credit }
        if width(of: withoutCredit) <= maxWidth { return withoutCredit }
        return withoutCredit.filter { $0.kind != .step }
    }

    /// 把模型名缩到预算内，保留尾部 `…`；实在不行返回 nil（由调用方整段丢）。
    ///
    /// - Note: 至少保留 4 个字符。比这再短就已经认不出是哪个模型了，
    ///   与其显示 `Dee…` 这种废话，不如让调用方走「整段丢」。
    private static func shortenedModel(_ segment: TaskMetaSegment,
                                       budget: CGFloat,
                                       font: NSFont) -> TaskMetaSegment? {
        guard budget > 0 else { return nil }
        let chars = Array(segment.text)
        let minimum = 4
        guard chars.count > minimum else { return nil }
        // 从「少 1 个字」开始试，尽可能多留原文。
        for keep in stride(from: chars.count - 1, through: minimum, by: -1) {
            let candidate = String(chars.prefix(keep)) + "…"
            if TouchBarTextMetrics.textWidth(candidate, font: font) <= budget {
                return TaskMetaSegment(kind: segment.kind,
                                       text: candidate,
                                       isWarning: segment.isWarning)
            }
        }
        return nil
    }

    /// 第二行文字及图形模式下的两侧文本；圆环永不覆盖整行文字。
    struct TaskMetaRendering {
        let attributed: NSAttributedString
        let prefix: NSAttributedString?
        let suffix: NSAttributedString?
        /// 保留既有只读接口；实际布局使用独立文本框，而不是这个估算偏移。
        let ringOffsetX: CGFloat?
        let ringRatio: Double?
        /// 步骤进度条的比例（0...1）；无有效步骤段时为 nil（进度条隐藏）。
        let stepProgressRatio: Double?
        /// 进度条相对第二行前缀起点的估算偏移（供测试 / 兼容；实际布局按 ring 运行时位置排布）。
        let stepProgressOffsetX: CGFloat?
    }

    /// 详情视图第二行富文本：整体 `.secondaryLabelColor`，
    /// `isWarning` 为 true 的段用 `.systemOrange`。
    ///
    /// 为什么必须是富文本而不是纯文本：警告色只作用于「上下文」那一段，
    /// 纯文本只能整行一个颜色 —— 整行变橙会让「卡住」（时长橙色）的含义失效。
    ///
    /// - Parameters:
    ///   - task: 当前聚焦任务。
    ///   - elapsed: 本次运行已持续秒数。
    ///   - maxWidth: 可用宽度上限（pt）；nil 表示不裁剪。
    ///   - graphicRing: true 时上下文段省略字符环，改由独立视图 `ContextRingView` 绘制。
    ///   - credits: 本轮已消耗积分；nil 时省略积分段。
    /// - Returns: 富文本 + 圆环位置/比例。
    static func taskMetaRendering(task: TaskInfo?,
                                 elapsed: TimeInterval?,
                                 maxWidth: CGFloat?,
                                 graphicRing: Bool,
                                 credits: Double? = nil,
                                 showTaskStep: Bool = true) -> TaskMetaRendering {
        let font = NSFont.systemFont(ofSize: TaskStripView.expandedMetaFontSize)
        let segments = fittedMetaSegments(
            taskMetaSegments(task: task, elapsed: elapsed,
                             graphicRing: graphicRing, credits: credits,
                             showTaskStep: showTaskStep),
            font: font,
            maxWidth: maxWidth,
            graphicRing: graphicRing
        )

        let result = NSMutableAttributedString()
        let normalColor = NSColor.secondaryLabelColor
        var contextStart: Int?

        for (index, segment) in segments.enumerated() {
            if index > 0 {
                // 分隔符也着色（次要色）：否则它会继承 label 的默认色，
                // 在「上下文」变橙时显得像个孤立的亮点。
                result.append(NSAttributedString(
                    string: metaSeparator,
                    attributes: [.font: font, .foregroundColor: normalColor]
                ))
            }
            let color = segment.isWarning ? NSColor.systemOrange : normalColor
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color
            ]
            if segment.kind == .context {
                contextStart = result.length
            }
            // - Important: 这里**绝不**插入 `NSTextAttachment`。圆环是独立子视图
            //   （见 `ContextRingView` 与 `TaskMetaRendering` 的说明）。
            result.append(NSAttributedString(string: segment.text, attributes: attributes))
        }

        let hasContext = segments.contains { $0.kind == .context }
        let ratio = task?.contextUsage
        let ringOffsetX: CGFloat?
        let ringRatio: Double?
        if graphicRing, hasContext, let ratio = ratio {
            let prefixText = result.attributedSubstring(from: NSRange(location: 0, length: contextStart ?? 0)).string
            ringOffsetX = TouchBarTextMetrics.textWidth(prefixText, font: font)
            ringRatio = ratio
        } else {
            ringOffsetX = nil
            ringRatio = nil
        }
        let prefix: NSAttributedString?
        let suffix: NSAttributedString?
        if ringRatio != nil, let start = contextStart {
            prefix = result.attributedSubstring(from: NSRange(location: 0, length: start))
            suffix = result.attributedSubstring(from: NSRange(location: start, length: result.length - start))
        } else {
            prefix = nil
            suffix = nil
        }

        // 步骤进度条：只在「裁剪后仍保留的 step 段」上出现（与文案同源，不会被裁掉后还留个空条）。
        let stepProgressRatio = segments.first { $0.progress != nil }?.progress
        let stepProgressOffsetX: CGFloat?
        if stepProgressRatio != nil {
            if ringOffsetX != nil {
                // 图形模式：进度条排在圆环之后（前缀起点 + 前缀文字宽 + 环宽 + 间隙）。
                stepProgressOffsetX = (ringOffsetX ?? 0) + ContextRingView.side
                    + TaskStripView.contextRingGap
            } else {
                // 字符模式（无环）：排在整行文字之后。
                stepProgressOffsetX = TaskStripView.metaFieldWidth(result) + TaskStripView.contextRingGap
            }
        } else {
            stepProgressOffsetX = nil
        }

        return TaskMetaRendering(attributed: result,
                                 prefix: prefix, suffix: suffix,
                                 ringOffsetX: ringOffsetX,
                                 ringRatio: ringRatio,
                                 stepProgressRatio: stepProgressRatio,
                                 stepProgressOffsetX: stepProgressOffsetX)
    }

    /// 详情视图第二行富文本（兼容包装：只要富文本的调用方走这里）。
    ///
    /// - Note: 图形模式下返回的富文本里**没有圆环**（圆环由 `ContextRingView` 单独绘制），
    ///   所以只有「不关心圆环、只关心文字」的场景（例如单测断言文案）适合用它。
    ///   真正上屏请用 `taskMetaRendering`，否则圆环不会出现在 Touch Bar 上。
    static func taskMetaAttributedText(task: TaskInfo?,
                                       elapsed: TimeInterval?,
                                       maxWidth: CGFloat?,
                                       graphicRing: Bool = false,
                                       credits: Double? = nil,
                                       showTaskStep: Bool = true) -> NSAttributedString {
        taskMetaRendering(task: task, elapsed: elapsed, maxWidth: maxWidth,
                          graphicRing: graphicRing, credits: credits,
                          showTaskStep: showTaskStep).attributed
    }

    /// 任务状态的中文短名（详情视图第二行用）。
    ///
    /// - Note: 与 `taskText` 的图标映射一一对应，改一处必须改另一处；
    ///   测试 `testTaskMetaStatusText` 覆盖全部六种取值。
    static func statusText(_ status: TaskStatus) -> String {
        switch status {
        case .working, .active: return "进行中"
        case .pending: return "待确认"
        case .completed: return "已完成"
        case .archived: return "已归档"
        case .unknown: return "未知"
        }
    }

    private static func makeVoiceItem(
        identifier: NSTouchBarItem.Identifier,
        isListening: Bool,
        handlers: Handlers
    ) -> NSTouchBarItem {
        let item = NSCustomTouchBarItem(identifier: identifier)
        let title = isListening ? "⏹ 结束" : "🎙️ 语音"
        // 保持 NSButton：实测宽度约 82pt、系统自带按下高亮都免费，
        // 换成自绘 NSView 要自己实现 intrinsicContentSize 和按下态，风险不值得。
        let button = makeTouchBarButton(title: title, onClick: handlers.onVoiceToggle)
        item.view = button
        return item
    }

    /// Control Strip（系统栏）里的 WorkBar logo：点一下重新挂载常驻 bar。
    ///
    /// - Important: 这里用 `NSButton` + `imageOnly` 而不是自绘视图：
    ///   Control Strip 的格子由系统托管（宽度、圆角、按下态都不归我们管），
    ///   自带 bezel 的 `NSButton` 才和系统控件长得一致；自绘只会在系统换圆角时显得突兀。
    /// - Note: 标识符固定为 `trayIdentifier`（不带 generation）：这个 item 是**长期存在**的，
    ///   每次数据刷新都换标识符会让 Control Strip 的格子被反复重新注册、闪一下。
    static func makeTrayItem(onTap: @escaping () -> Void) -> NSCustomTouchBarItem {
        let item = NSCustomTouchBarItem(identifier: trayIdentifier)
        let button = makeTouchBarButton(title: "", onClick: onTap)
        button.bezelStyle = .rounded
        button.imagePosition = .imageOnly
        button.image = trayIcon()
        button.toolTip = "WorkBar"
        item.view = button
        return item
    }

    /// Control Strip 图标：优先用**菜单栏那枚单色图标**，退到 app 图标，最后兜底画一个。
    ///
    /// - Note: 首选菜单栏图标是为了「协调」—— 用户在同一块 Touch Bar 的最右侧看到的，
    ///   应该和屏幕上菜单栏里那枚是同一个形状，否则像两个不相干的东西塞在一起。
    ///
    /// - Important: 单色图标是模板图（只有 alpha 有意义），在 Control Strip 的深底上
    ///   会不会变成「黑底黑图 = 看不见」是实打实的风险，所以做过离屏渲染实测：
    ///   在 `darkAqua` 下画带模板图的 `NSButton.cell`，像素最大亮度约 0.70、
    ///   明显亮于底色（0.18）—— 系统会把模板图着成浅色，可以放心用。
    ///   若哪天系统不再着色，表现为图标消失，此时把下面 `isTemplate` 改 false 并自绘白色即可。
    static func trayIcon() -> NSImage {
        let target = NSSize(width: 18, height: 18)
        // 1) 菜单栏同款单色图标（模板图，随外观着色）。
        if let image = loadIcon(named: "MenuBarIcon") {
            image.size = target
            image.isTemplate = true
            return image
        }
        // 2) app 图标（彩色，非模板）：形状不同，但至少认得出是 WorkBar。
        if let image = loadIcon(named: "TouchBarBuddy") {
            image.size = target
            image.isTemplate = false
            return image
        }
        // 3) 两条路都取不到：现画一个，保证格子不会空白。
        return drawnTrayIcon(size: target)
    }

    /// 加载资源图标（返回可安全修改尺寸的副本）。
    ///
    /// - Note: 先 `NSImage(named:)`（走图片表/按名查找），再按 `Contents/Resources`
    ///   下的散放文件兜底 —— 本项目是脚本直编自签、资源是散放的，
    ///   只靠 `NSImage(named:)` 在部分打包方式下取不到。
    private static func loadIcon(named name: String) -> NSImage? {
        guard let source = NSImage(named: name) ?? bundleImage(named: name) else { return nil }
        return source.copy() as? NSImage ?? source
    }

    /// 从 `Bundle.main` 直接取资源图片。
    ///
    /// - Note: `NSImage(named:)` 只查 `Assets.car` / 主 bundle 的图片表，**不查**
    ///   `Contents/Resources` 下散放的 png/icns；本项目是脚本直编自签、资源是散放的，
    ///   所以必须再走一次按路径加载。
    private static func bundleImage(named name: String) -> NSImage? {
        for ext in ["png", "icns"] {
            if let url = Bundle.main.url(forResource: name, withExtension: ext),
               let image = NSImage(contentsOf: url) {
                return image
            }
        }
        return nil
    }

    /// 兜底图标：圆角方块 + 「W」。
    ///
    /// - Note: 用浅色块 + 深色字（而不是之前那个绿色块）：Control Strip 上其它条目全是
    ///   单色浅色图标，一个彩色块在那里会显得格格不入。这里只在三条资源全丢时才出现。
    private static func drawnTrayIcon(size: NSSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        let rect = NSRect(origin: .zero, size: size)
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
        NSColor(white: 0.92, alpha: 1).setFill()
        path.fill()
        let text = "W" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .bold),
            .foregroundColor: NSColor(white: 0.15, alpha: 1)
        ]
        let bounds = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: (size.width - bounds.width) / 2,
                              y: (size.height - bounds.height) / 2),
                  withAttributes: attrs)
        image.unlockFocus()
        return image
    }

    /// 弹层态的标题 item：纯 label，**不可点**（避免误触把它当成选项）。
    private static func makeDialogTitleItem(
        identifier: NSTouchBarItem.Identifier,
        state: TouchBarState
    ) -> NSTouchBarItem {
        let item = NSCustomTouchBarItem(identifier: identifier)
        let title = DialogDetector.displayTitle(state.choice?.title ?? "")
        let label = NSTextField(labelWithString: "❓\(title)")
        label.textColor = .labelColor
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.alignment = .center
        item.view = label
        return item
    }

    /// 弹层态的选项 item：可点按钮，点击回调携带该选项的**文本**（不是下标 ——
    /// 弹层重排后下标会漂，文本才是稳定标识）。
    private static func makeDialogOptionItem(
        identifier: NSTouchBarItem.Identifier,
        state: TouchBarState,
        index: Int,
        handlers: Handlers
    ) -> NSTouchBarItem {
        let item = NSCustomTouchBarItem(identifier: identifier)
        guard let choice = state.choice, index < choice.options.count else {
            // 状态已变化（例如弹层被用户自己在界面里关掉）：给一个占位不可点视图，别崩。
            item.view = NSTextField(labelWithString: "—")
            return item
        }
        let label = choice.options[index]
        item.view = makeTouchBarButton(title: label, onClick: { handlers.onDialogOption(label) })
        return item
    }

    // MARK: - 权限屏（V17）

    /// 权限屏 1 的标题：`🙋 ` + 截断标题，**可点**（点它进入屏 2 看逐项勾选）。
    ///
    /// 为什么标题要可点：可用宽度只有约 290pt，一屏塞不下「标题 + 3 个勾选 + 允许 + 取消」，
    /// 唯一的「不占额外宽度」的入口就是标题本身 —— 它本来就在那儿，点它展开明细，
    /// 不需要再放一个「详情」按钮（那要多花 66pt，正好把允许/取消挤出去）。
    private static func makePermissionTitleItem(
        identifier: NSTouchBarItem.Identifier,
        permissions: PermissionRequest?,
        handlers: Handlers
    ) -> NSTouchBarItem {
        let item = NSCustomTouchBarItem(identifier: identifier)
        let title = DialogDetector.displayTitle(permissions?.title ?? PermissionParser.fallbackTitle,
                                                limit: permissionTitleLimit)
        let button = makeTouchBarButton(title: "🙋 \(title)", onClick: handlers.onPermissionDetail)
        button.font = .systemFont(ofSize: permissionActionFontSize, weight: .medium)
        item.view = button
        return item
    }

    /// 权限屏的单个动作按钮（允许 / 取消 / 返回）。
    ///
    /// - Parameter fontSize: 屏 1 用 13pt，屏 2（含返回）用 11pt —— 原因见
    ///   `permissionCheckboxFontSize`，是宽度实测逼出来的，不是审美选择。
    private static func makePermissionActionItem(
        identifier: NSTouchBarItem.Identifier,
        title: String,
        fontSize: CGFloat,
        onClick: (() -> Void)?
    ) -> NSTouchBarItem {
        let item = NSCustomTouchBarItem(identifier: identifier)
        let button = makeTouchBarButton(title: title, onClick: onClick)
        button.font = .systemFont(ofSize: fontSize)
        item.view = button
        return item
    }

    /// 权限屏 2 的第 `index` 个勾选项：`✅ / ☐` + 截断标签，点击切换勾选态。
    ///
    /// - Important: 勾选态**只来自 AX 重新读取**（`PermissionRequest.items`），
    ///   这里不做任何本地翻转 —— 本地翻转会在 WorkBuddy 拒绝切换时让界面说谎。
    private static func makePermissionCheckboxItem(
        identifier: NSTouchBarItem.Identifier,
        permissions: PermissionRequest?,
        index: Int,
        handlers: Handlers
    ) -> NSTouchBarItem {
        let item = NSCustomTouchBarItem(identifier: identifier)
        guard let permissions = permissions, index < permissions.items.count else {
            // 状态已变化（弹窗被用户自己关掉 / 项数变少）：给占位不可点视图，别崩。
            item.view = NSTextField(labelWithString: "—")
            return item
        }
        let permission = permissions.items[index]
        let title = PermissionParser.itemTitle(permission)
        let button = makeTouchBarButton(title: title,
                                        onClick: { handlers.onPermissionToggle(permission.label) })
        button.font = .systemFont(ofSize: permissionCheckboxFontSize)
        item.view = button
        return item
    }

    /// 强引用点击动作持有者，避免 target 弱引用被释放（保留最近若干个即可）。
    private static var retainedHolders: [TouchBarActionHolder] = []

    /// 单任务展示文案：状态图标 + 标题 + （多任务时）序号。
    ///
    /// - Note: internal 可见，控制器就地刷新标题时复用它，保证「首次构建」与
    ///   「轮询刷新」的图标 / 序号规则只有这一份实现（单一真源）。
    static func taskText(task: TaskInfo?, index: Int, total: Int) -> String {
        guard let task = task else { return "无任务" }
        let counter = total > 1 ? " (\(index + 1)/\(total))" : ""
        let icon: String
        switch task.status {
        case .pending: icon = "⏳"
        case .working, .active: icon = "🟢"
        case .completed: icon = task.unread ? "📬" : "✅"
        case .archived: icon = "🗄"
        case .unknown: icon = "•"
        }
        return "\(icon) \(task.title)\(counter)"
    }
}


/// 点击动作持有者。
///
/// - Important: `NSButton.target` 是**弱引用**，必须由外部强引用持有，否则点击无响应。
///   此外，真机验证表明：用 `NSButton(title:target:action:)` 工厂方法创建的按钮在 Touch Bar 上
///   能稳定显示，而 `NSButton` 子类 + `init(frame:)` 的实例在「同一 bar 内第二个按钮」的位置上
///   会不显示。因此语音按钮不走 `ClosureButton`，改用工厂方法 + 本持有者。
final class TouchBarActionHolder: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) {
        self.action = action
        super.init()
    }

    @objc func fire() {
        action()
    }
}

/// Touch Bar 上的任务条视图：显示当前聚焦任务，支持左右横滑切换（direct touch）。
///
/// 右侧追加一段「距上次活动」的时长文案（V13 降级版）。
/// 详情第二行在环形上下文图标之外，还排布一条 V13 步骤进度条（`StepProgressView`）：
/// 两者都是独立兄弟子视图，按 frame 顺序排列，互不覆盖文字。
final class TaskStripView: NSView, NSGestureRecognizerDelegate {

    let label = NSTextField(labelWithString: "")

    /// 距上次活动的时长文案（10pt，右侧）。
    private let ageLabel = NSTextField(labelWithString: "")

    /// 详情视图第二行：状态 · 模型 · 时长（9pt 次要色，左对齐）。
    ///
    /// - Note: 不加 `private`：单测要断言「两行 frame 不越界、不重叠」，
    ///   而这正是只在真机才看得见的失效（文字被容器切掉）。
    let metaLabel = NSTextField(labelWithString: "")
    let metaPrefixLabel = NSTextField(labelWithString: "")
    let metaSuffixLabel = NSTextField(labelWithString: "")
    static let contextRingGap: CGFloat = 3

    /// 使用真实 cell 的排版尺寸，包含 NSTextField 内部 padding。
    static func metaFieldWidth(_ text: NSAttributedString) -> CGFloat {
        guard text.length > 0 else { return 0 }
        let cell = NSTextFieldCell(textCell: "")
        cell.isBordered = false
        cell.isBezeled = false
        cell.font = .systemFont(ofSize: expandedMetaFontSize)
        cell.attributedStringValue = text
        return ceil(cell.cellSize.width)
    }

    /// 当前是否处于详情（两行）视图。
    ///
    /// - Note: 由 `update(...)` 按控制器传入的 `expanded` 覆盖，视图自己不保存业务状态 ——
    ///   否则「点了展开 → 后台状态变化重建」时两边会不一致。
    private(set) var isExpanded = false

    /// 上下文用量圆环（图形模式）。
    ///
    /// - Important: 它必须是**独立子视图**，不能塞进 `metaLabel` 的富文本里 ——
    ///   详情第二行每 3 秒重写一次，而 Touch Bar 的 `NSTextFieldCell` 对
    ///   `NSTextAttachment` 只在首次绘制有效，之后圆环就消失了（真机现象）。
    ///   详见 `ContextRingView`。
    let ringView = ContextRingView()

    /// V13 步骤进度条（独立子视图，与 ring 同为第二行的兄弟视图，按 frame 顺序排布）。
    let stepProgressView = StepProgressView()

    var onSwipe: ((Int) -> Void)?
    /// 点一下 => 切换紧凑 / 详情。
    var onToggle: (() -> Void)?
    /// 两个手势都要被保留引用：`shouldRequireFailureOf` 里要用身份比较。
    private var swipePan: NSPanGestureRecognizer?
    private var toggleClick: NSClickGestureRecognizer?
    private let swipeThreshold: CGFloat = 20

    /// 紧凑视图标题字号。
    static let compactTitleFontSize: CGFloat = 13
    /// 详情视图第一行字号（比紧凑小一档，才可能两行塞进 30pt）。
    static let expandedTitleFontSize: CGFloat = 12
    /// 详情视图第二行字号。
    static let expandedMetaFontSize: CGFloat = 8
    /// 详情视图两行的左右内边距。
    ///
    /// - Note: 不加 `private`：工厂要用它算第二行的**可用宽度**（`taskItemWidth - inset*2`）
    ///   来裁剪文案。裁剪宽度与实际排版宽度必须是同一个值，否则会出现
    ///   「估算放得下、真机上尾巴被切」这种只在真机才看得见的偏差。
    static let expandedHorizontalInset: CGFloat = 2
    /// 详情视图第一行的垂直余量（emoji 会超出行高一点）。
    ///
    /// - Note: 比紧凑视图的 `verticalSlack`（8pt）小得多 —— 两行合计只有 30pt，
    ///   第一行最多拿到 17pt（15pt 行高 + 2pt 余量）。这个值是真机上「emoji 不被裁」
    ///   与「两行都放得下」的折中点，需要真机再确认一次底部有没有切边。
    private static let expandedTitleSlack: CGFloat = 3
    /// 详情视图第二行的垂直余量。
    private static let expandedMetaSlack: CGFloat = 1
    /// 详情视图第一行文字中心的纵向位置（占容器高度的比例）。
    ///
    /// 0.66 是「顶部留白 ≥ emoji 上沿溢出量」与「两行之间留出间隙」的折中：
    /// 30pt 容器下第一行中心约 19.8pt，文字顶部约 27pt，离容器顶留 3pt。
    private static let expandedTitleBandRatio: CGFloat = 0.7
    /// 详情视图第二行文字中心的纵向位置（占容器高度的比例）。30pt 下约 7.5pt。
    private static let expandedMetaBandRatio: CGFloat = 0.2

    /// 时长文案的占位宽度（pt）。
    ///
    /// 文案改为 WorkBuddy 同款后最长是 `"1h2m3s"`（6 字符），10pt 下约 33pt；
    /// 再留 6pt 间隙 + 4pt 右边距 = 44pt。
    /// 标题可用宽度因此从 200pt 降到 **156pt**（标题本来就会截断，这是可接受的代价）。
    /// - Note: 槽宽必须固定，否则秒数从 `59s` 变成 `1m0s` 时标题会左右跳。
    static let ageSlotWidth: CGFloat = 44

    /// 时长段的右内边距，避免文字贴着 Touch Bar 边缘。
    private static let ageTrailingInset: CGFloat = 4

    /// 文字框的垂直余量（pt）。
    ///
    /// 为什么需要：`textHeight` 按字体 ascender-descender 算出 16pt（13pt 字），
    /// 但 emoji（🟢/⏳ 等）作为图文混排，实际渲染会超出这个行高一点点。
    /// 之前把 label 高度**写死**为 16pt，emoji 的下半部分就被裁掉了
    /// （用户反馈「文字和图标下面的部分没有显示全」）。多给 8pt 并把框居中，
    /// 内容就完整落在框内；框本身仍小于 30pt 容器，不会溢出到相邻 item。
    static let verticalSlack: CGFloat = 8

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    /// 更新展示内容。
    ///
    /// - Parameters:
    ///   - title: 任务文案（图标 + 标题 + 序号）。
    ///   - activityAge: 距上次活动秒数；nil 时不显示时长段，标题占满整条宽度
    ///     （没数据时留一块空白比不留更难看，也会让人以为「时长是 0」）。
    /// - Parameter elapsed: 「本次运行已持续多久」（由控制器从首次进入进行中算起）。
    ///   非 nil 时**优先显示它**，因为它只增不减；`activityAge` 会在每次有输出时归零，
    ///   用户看到「0,1,4,7,10,13 然后回到 0s」就是旧行为（用户 2026-11-19 报的 bug）。
    ///   卡住判定仍走 `activityAge`（"多久没动静"），与这里的"跑了多久"是两件事。
    /// - Parameter expanded: 是否显示详情（两行）视图。
    /// - Parameter meta: 详情视图第二行富文本（状态 · 模型 · 上下文 · 时长）；nil / 空串时第二行留空。
    /// - Parameter ringOffsetX: 兼容旧调用签名；图形布局应传 `rendering`，不再按文字偏移覆盖圆环。
    /// - Parameter ringRatio: 圆环填充比例（0…1）。
    /// - Parameter ringTint: 圆环颜色（上下文吃紧时由调用方传 `.systemOrange`）。
    ///
    /// - Note: 这个参数从 `String?` 升级成 `NSAttributedString?`，因为「上下文 80%」那一段
    ///   要单独染警告色。纯文本无法做到「只让一段变色」，而整行变橙会让
    ///   「橙色 = 卡住了」这个既有含义失效。
    func update(title: String,
                activityAge: TimeInterval?,
                elapsed: TimeInterval? = nil,
                expanded: Bool = false,
                meta: NSAttributedString? = nil,
                ringOffsetX: CGFloat? = nil,
                ringRatio: Double? = nil,
                ringTint: NSColor = .secondaryLabelColor,
                rendering: TouchBarItemFactory.TaskMetaRendering? = nil) {
        isExpanded = expanded
        label.stringValue = title
        // 字号 / 对齐随视图切换：紧凑 13pt 居中（现状不变），详情 12pt 左对齐（省宽度）。
        label.font = .systemFont(ofSize: expanded ? Self.expandedTitleFontSize
                                                 : Self.compactTitleFontSize)
        label.alignment = expanded ? .left : .center

        // 判空用富文本的 `.string`：富文本赋进去之后 `stringValue` 在不同 AppKit 版本上
        // 可能被重新格式化，而 `.string` 就是我们自己拼的那串，最可靠。
        let metaText = (rendering?.attributed ?? meta)?.string ?? ""
        metaLabel.attributedStringValue = rendering?.attributed ?? meta ?? NSAttributedString(string: "")
        metaLabel.isHidden = !expanded || metaText.isEmpty
        applyRendering(rendering, expanded: expanded, tint: ringTint)

        // 显示用 elapsed（只增不减）；橙色仍按 activityAge（多久没动静）判定。
        // 两者语义不同：跑了 10 分钟但一直在输出 → 显示 10m 且**不该**变橙。
        setAgeText(elapsed ?? activityAge, staleSeconds: activityAge)
    }

    /// 就地更新标题（多任务轮询切换时，详情第二行换了、标题也必须跟着换）。
    ///
    /// - Note: 只改 `label.stringValue` 并按当前 `isExpanded` 保持既有字号 / 对齐规则，
    ///   不重建 item、不 dismiss / present、不碰 identifier。紧凑态（未展开）同样适用 ——
    ///   用户说的是「标题」本身，与详情是否展开无关。
    func updateTitle(_ title: String) {
        label.stringValue = title
        label.font = .systemFont(ofSize: isExpanded ? Self.expandedTitleFontSize
                                                    : Self.compactTitleFontSize)
        label.alignment = isExpanded ? .left : .center
        needsLayout = true
        layoutContent()
    }

    /// 只改时长文案，同时保留「卡住判定」用的那个秒数。
    ///
    /// - Parameter displaySeconds: 显示用的秒数（elapsed 优先）。
    /// - Parameter staleSeconds: 用于橙色判定的秒数（距上次活动）。
    private func setAgeText(_ displaySeconds: TimeInterval?, staleSeconds: TimeInterval?) {
        guard let seconds = displaySeconds,
              let text = ActivityAge.formatActivityAge(seconds) else {
            ageLabel.stringValue = ""
            ageLabel.isHidden = true
            needsLayout = true
            layoutContent()
            return
        }

        ageLabel.stringValue = text
        ageLabel.isHidden = false
        // 超过阈值转橙：这是整个功能的价值点 —— 一眼看出「这个任务可能卡住了」。
        // 不用红色：红色在本项目里是「出错了要你处理」，而这里只是「有点久，看一眼」。
        ageLabel.textColor = (staleSeconds ?? seconds) > ActivityAge.staleThreshold
            ? .systemOrange
            : .secondaryLabelColor
        needsLayout = true
        layoutContent()
    }

    /// 就地更新时长文案：显示 `elapsed`（累加），橙色仍按 `activityAge`（卡住判定）。
    func updateElapsed(_ elapsed: TimeInterval?, activityAge: TimeInterval?) {
        setAgeText(elapsed ?? activityAge, staleSeconds: activityAge)
    }

    /// 只更新右侧「距上次活动」文案（不动标题、不重建 item）。
    ///
    /// 为什么需要单独一个入口：时长是**随时间自然增长**的值，每轮轮询都不同。
    /// 若为了刷新这三个字去重建整条 Touch Bar（`dismiss` + `present`），
    /// 用户就会看到周期性的「刷新一下」。所以控制器把它拆成第三档：
    /// 只有数字变了时调本方法，其它情况什么都不做。
    ///
    /// - Parameter activityAge: 距上次活动秒数；nil 表示隐藏这一格。
    func updateActivityAge(_ activityAge: TimeInterval?) {
        guard let seconds = activityAge, let text = ActivityAge.formatActivityAge(seconds) else {
            ageLabel.stringValue = ""
            ageLabel.isHidden = true
            needsLayout = true
            layoutContent()
            return
        }

        ageLabel.stringValue = text
        ageLabel.isHidden = false
        // 超过阈值转橙：这是整个功能的价值点 —— 一眼看出「这个任务可能卡住了」。
        // 不用红色：红色在本项目里是「出错了要你处理」，而这里只是「有点久，看一眼」。
        ageLabel.textColor = seconds > ActivityAge.staleThreshold
            ? .systemOrange
            : .secondaryLabelColor
        needsLayout = true
        layoutContent()
    }

    /// 详情视图下就地刷新第二行（时长在走 / 上下文比例变化时用，避免为了一个数字去重建整条 bar）。
    ///
    /// - Parameters:
    ///   - meta: 新的第二行富文本；非详情态忽略（紧凑视图没有第二行）。
    ///   - ringOffsetX: 兼容旧签名，实际图形布局使用 `rendering` 中的两侧文本。
    ///   - ringRatio: 兼容旧签名，比例从 `rendering` 读取。
    ///   - ringTint: 圆环颜色。
    ///   - rendering: 裁剪后的分段结果；每次更新同步文字、颜色、比例与模式。
    func updateExpandedMeta(_ meta: NSAttributedString?,
                            ringOffsetX: CGFloat? = nil,
                            ringRatio: Double? = nil,
                            ringTint: NSColor = .secondaryLabelColor,
                            rendering: TouchBarItemFactory.TaskMetaRendering? = nil) {
        guard isExpanded else { return }

        metaLabel.attributedStringValue = rendering?.attributed ?? meta ?? NSAttributedString(string: "")
        metaLabel.isHidden = metaLabel.stringValue.isEmpty
        applyRendering(rendering, expanded: true, tint: ringTint)
        needsLayout = true
        layoutContent()
    }

    private func applyRendering(_ rendering: TouchBarItemFactory.TaskMetaRendering?,
                                expanded: Bool, tint: NSColor) {
        let split = expanded && rendering?.prefix != nil && rendering?.suffix != nil
        metaPrefixLabel.attributedStringValue = rendering?.prefix ?? NSAttributedString(string: "")
        metaSuffixLabel.attributedStringValue = rendering?.suffix ?? NSAttributedString(string: "")
        metaPrefixLabel.isHidden = !split
        metaSuffixLabel.isHidden = !split
        ringView.isHidden = !split
        if split { metaLabel.isHidden = true }
        ringView.ratio = rendering?.ringRatio ?? 0
        ringView.tint = tint

        // 步骤进度条：独立于 ring / 字符模式，只由裁剪后是否保留 step 段决定。
        let stepRatio = rendering?.stepProgressRatio
        stepProgressView.isHidden = !expanded || stepRatio == nil
        if let stepRatio = stepRatio {
            stepProgressView.progress = stepRatio
            stepProgressView.tint = StepProgressView.tint(for: stepRatio)
            stepProgressView.trackColor = StepProgressView.tint(for: stepRatio)
                .withAlphaComponent(0.25)
        }
    }

    /// 详情视图两行各自的高度（第一行标题、第二行 meta）。
    ///
    /// 抽成静态纯函数是为了单测能直接断言「两行加起来不超过容器高度」——
    /// 这个函数算错的表现是文字被容器切掉，而这种裁切只在真机上看得见。
    ///
    /// - Parameter boundsHeight: 容器高度（Touch Bar 上是 30pt）。
    /// - Returns: 两行高度；两者之和恒 ≤ `boundsHeight`。
    static func expandedRowHeights(boundsHeight: CGFloat) -> (title: CGFloat, meta: CGFloat) {
        let titleLine = textHeight(for: .systemFont(ofSize: expandedTitleFontSize))
        let metaLine = textHeight(for: .systemFont(ofSize: expandedMetaFontSize))
        // 第二行先占，且不超过半高（避免 meta 过长把标题压没）；剩下的全给第一行。
        let meta = min(boundsHeight / 2, metaLine + expandedMetaSlack)
        let title = min(boundsHeight - meta, titleLine + expandedTitleSlack)
        return (title: max(0, title), meta: max(0, meta))
    }

    private func setup() {
        label.frame = bounds
        // 只跟随宽度：高度由 `layoutContent()` 按字体行高写死。
        // 若保留 `.height`，视图被拉高时 label 会被 autoresizing 拉回 `bounds.height`，
        // 于是又退回「字贴顶边」的老样子（这次要修的正是它）。
        label.autoresizingMask = [.width]
        label.alignment = .center
        label.font = .systemFont(ofSize: Self.compactTitleFontSize)
        addSubview(label)

        ageLabel.font = .systemFont(ofSize: 10)
        ageLabel.textColor = .secondaryLabelColor
        ageLabel.alignment = .right
        ageLabel.isBordered = false
        ageLabel.isEditable = false
        ageLabel.isSelectable = false
        ageLabel.drawsBackground = false
        ageLabel.isHidden = true
        addSubview(ageLabel)

        metaLabel.font = .systemFont(ofSize: Self.expandedMetaFontSize)
        metaLabel.textColor = .secondaryLabelColor
        metaLabel.alignment = .left
        metaLabel.lineBreakMode = .byTruncatingTail
        metaLabel.maximumNumberOfLines = 1
        metaLabel.isBordered = false
        metaLabel.isEditable = false
        metaLabel.isSelectable = false
        metaLabel.drawsBackground = false
        metaLabel.isHidden = true
        addSubview(metaLabel)

        for field in [metaPrefixLabel, metaSuffixLabel] {
            field.font = .systemFont(ofSize: Self.expandedMetaFontSize)
            field.alignment = .left
            field.lineBreakMode = .byTruncatingTail
            field.maximumNumberOfLines = 1
            field.isBordered = false
            field.isEditable = false
            field.isSelectable = false
            field.drawsBackground = false
            field.isHidden = true
            addSubview(field)
        }
        // 三个独立兄弟视图按 frame 顺序排布，不叠在整行文字上。
        // frame 由 `layoutExpanded()` 定位，初值给个合法尺寸避免首次绘制出 0×0 的怪状。
        ringView.frame = NSRect(x: 0, y: 0,
                                width: ContextRingView.side,
                                height: ContextRingView.side)
        ringView.isHidden = true
        addSubview(ringView)

        stepProgressView.frame = NSRect(x: 0, y: 0,
                                        width: StepProgressView.barWidth,
                                        height: StepProgressView.barHeight)
        stepProgressView.isHidden = true
        addSubview(stepProgressView)

        let pan = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        // Touch Bar 为直接触摸屏，限定 direct 触摸类型（见 docs/FEASIBILITY.md §1 #4）。
        // NSTouchTypeMask 为 OptionSet，`.direct` 对应 NSTouchTypeMaskDirect。
        pan.allowedTouchTypes = .direct
        addGestureRecognizer(pan)
        swipePan = pan

        // 点一下切换紧凑/详情。
        //
        // - Important: AppKit **没有** UIKit 的 `require(toFail:)`（只有 subclass/代理方法），
        //   所以「横滑时不要触发点击」靠下面 `gestureRecognizer(_:shouldRequireFailureOf:)`
        //   让 click 依赖 pan 失败来实现。少了这条，用户每滑一次都会顺带展开/收起。
        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
        click.allowedTouchTypes = .direct
        click.delegate = self
        addGestureRecognizer(click)
        toggleClick = click

        layoutContent()
    }

    /// click 必须等 pan 失败才算成功：横滑（pan 成功）时点击自动不触发。
    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer,
                           shouldRequireFailureOf otherGestureRecognizer: NSGestureRecognizer) -> Bool {
        gestureRecognizer === toggleClick && otherGestureRecognizer === swipePan
    }

    /// 手工排版：左侧标题 + 右侧时长，两者**垂直居中**。
    ///
    /// - Important: 高度必须按字体度量算，不能给 `bounds.height`（约 30pt）。
    ///   无边框 `NSTextField` 在高于行高的框里是**顶部对齐**绘制的，
    ///   13pt 的字贴着一个 30pt 框的顶边 —— 视觉上就是「字太靠上」，
    ///   这正是用户反馈的现象。改成「框高 = 一行行高、y 居中」才是真居中。
    ///
    /// - Note: 不用 Auto Layout。这个视图尺寸被 `makeTaskItem` 固定为 200pt，
    ///   加约束只会引入「约束没满足时谁被压缩」的不确定性，而手工算 frame 是确定的。
    private func layoutContent() {
        if isExpanded {
            layoutExpanded()
            return
        }
        let slot = ageLabel.isHidden ? 0 : Self.ageSlotWidth
        // 文字的视觉中心对齐容器中心（不是「框居中」——见 `topAlignedTextFrame` 说明）。
        let center = bounds.height / 2
        let titleFont = label.font ?? .systemFont(ofSize: 13)
        let titleFrame = Self.topAlignedTextFrame(bandCenter: center,
                                                  textHeight: Self.textHeight(for: titleFont),
                                                  slack: Self.verticalSlack,
                                                  boundsHeight: bounds.height)
        label.frame = NSRect(x: 0,
                             y: titleFrame.y,
                             width: max(0, bounds.width - slot),
                             height: titleFrame.height)
        guard !ageLabel.isHidden else { return }
        // 10pt 的时长文案更矮，同样按自己的行高对齐中心，否则和标题不在同一条基线上。
        let ageFont = ageLabel.font ?? .systemFont(ofSize: 10)
        let ageFrame = Self.topAlignedTextFrame(bandCenter: center,
                                                textHeight: Self.textHeight(for: ageFont),
                                                slack: Self.verticalSlack,
                                                boundsHeight: bounds.height)
        ageLabel.frame = NSRect(x: bounds.width - slot,
                                y: ageFrame.y,
                                width: max(0, slot - Self.ageTrailingInset),
                                height: ageFrame.height)
    }

    /// 计算「顶部对齐文本框」应有的 frame，使**文字的视觉中心**落在 `bandCenter`。
    ///
    /// ## 为什么不能直接用 `(bounds.height - height) / 2`
    /// 无边框 `NSTextField` 在高于行高的框里是**顶部对齐**绘制的：
    /// 框高 24pt、文字行高 16pt 时，文字占据框顶的 16pt，视觉中心在 `y + 24 - 8`，
    /// 而不是框中心。之前就是这么写的，结果紧凑态文字整体偏高 4pt
    /// （用户反馈「太靠上」），展开态第一行框顶贴到容器顶、emoji 顶部被切。
    ///
    /// 正确关系：`y = bandCenter - height + textHeight / 2`。
    /// 余量 `slack` 用来给 emoji 上下溢出留空间，但受两条约束夹紧：
    /// 框不能低于容器底（`y >= 0`）、不能高于容器顶（`y + height <= bounds`）。
    ///
    /// - Parameters:
    ///   - bandCenter: 文字视觉中心的目标 y（坐标系原点在左下）。
    ///   - textHeight: 字体行高（`textHeight(for:)`）。
    ///   - slack: 期望的垂直余量；会被自动收紧到不越界。
    ///   - boundsHeight: 容器高度。
    /// - Returns: 可直接赋给 `frame` 的 `(y, height)`。
    static func topAlignedTextFrame(bandCenter: CGFloat,
                                    textHeight: CGFloat,
                                    slack: CGFloat,
                                    boundsHeight: CGFloat) -> (y: CGFloat, height: CGFloat) {
        guard textHeight > 0, boundsHeight > 0 else { return (0, max(0, textHeight)) }
        // 中心点必须先夹进「文字能完整放进容器」的区间，
        // 否则 ratio 偏大（例如 0.9）时文字本身就会顶出容器，再加余量只会更糟。
        let half = textHeight / 2
        let center = min(max(bandCenter, half), max(half, boundsHeight - half))
        let roomBelow = max(0, center - half)
        let roomAbove = max(0, boundsHeight - center - half)
        let effectiveSlack = min(slack, min(roomBelow, roomAbove))
        let height = textHeight + effectiveSlack
        let y = center - height + half
        return (max(0, y), height)
    }

    /// 详情视图排版：第一行 12pt 占上半，第二行 9pt 占下半。
    ///
    /// - Important: 两行都用 `expandedRowHeights` 算出的高度，绝不写死 ——
    ///   加起来一旦超过 30pt，`NSView` 会把第二行画到容器外，表现为被 Touch Bar 切掉。
    /// - Note: 详情态下右侧时长槽**不显示**：时长已经在第二行里（`… · 12s`），
    ///   两行布局没有位置再放一个独立的右对齐数字。
    private func layoutExpanded() {
        ageLabel.isHidden = true

        let inset = Self.expandedHorizontalInset
        let width = max(0, bounds.width - inset * 2)

        // 两行各自把**文字视觉中心**放在自己的半区中心稍偏内，保证：
        // 1) 第一行顶部不会被容器顶切掉（之前贴顶就是这个问题）；
        // 2) 两行之间留出可辨认的间隙，而不是糊成一团。
        let titleFont = label.font ?? .systemFont(ofSize: Self.expandedTitleFontSize)
        let titleFrame = Self.topAlignedTextFrame(
            bandCenter: bounds.height * Self.expandedTitleBandRatio,
            textHeight: Self.textHeight(for: titleFont),
            slack: Self.expandedTitleSlack,
            boundsHeight: bounds.height
        )
        label.frame = NSRect(x: inset, y: titleFrame.y, width: width, height: titleFrame.height)

        let metaFont = metaLabel.font ?? .systemFont(ofSize: Self.expandedMetaFontSize)
        let metaFrame = Self.topAlignedTextFrame(
            bandCenter: bounds.height * Self.expandedMetaBandRatio,
            textHeight: Self.textHeight(for: metaFont),
            slack: Self.expandedMetaSlack,
            boundsHeight: bounds.height
        )
        metaLabel.frame = NSRect(x: inset, y: metaFrame.y, width: width, height: metaFrame.height)

        // 进度条在图形模式排在圆环之后、后缀之前；字符模式排在整行文字之后。
        // 三种固定宽度都从 `suffixWidth` 的预算里先扣掉，容器压缩时只压前缀，
        // 保证百分比（后缀）、圆环、进度条永远完整显示。
        let barWidth = stepProgressView.isHidden ? 0 : StepProgressView.barWidth
        let barGap = stepProgressView.isHidden ? 0 : Self.contextRingGap

        if !ringView.isHidden {
            // 先保住百分比与固定圆环（以及 V13 进度条），容器被压缩时只压前缀。
            let fixed = ContextRingView.side + Self.contextRingGap + barWidth + barGap
            let suffixWidth = min(Self.metaFieldWidth(metaSuffixLabel.attributedStringValue),
                                  max(0, width - fixed))
            let prefixWidth = min(Self.metaFieldWidth(metaPrefixLabel.attributedStringValue),
                                  max(0, width - suffixWidth - fixed))
            metaPrefixLabel.frame = NSRect(x: inset, y: metaFrame.y,
                                           width: prefixWidth, height: metaFrame.height)
            ringView.frame = NSRect(x: metaPrefixLabel.frame.maxX,
                                    y: max(0, metaLabel.frame.midY - ContextRingView.side / 2),
                                    width: ContextRingView.side, height: ContextRingView.side)
            let barX = ringView.frame.maxX + Self.contextRingGap
            if !stepProgressView.isHidden {
                stepProgressView.frame = NSRect(
                    x: barX,
                    y: max(0, metaLabel.frame.midY - StepProgressView.barHeight / 2),
                    width: StepProgressView.barWidth, height: StepProgressView.barHeight)
            }
            metaSuffixLabel.frame = NSRect(
                x: stepProgressView.isHidden ? barX : stepProgressView.frame.maxX + barGap,
                y: metaFrame.y, width: suffixWidth, height: metaFrame.height)
        } else if !stepProgressView.isHidden {
            // 字符模式：整行文字在 metaLabel，进度条排在它右边（font 宽度含 cell padding）。
            let textWidth = min(Self.metaFieldWidth(metaLabel.attributedStringValue), width)
            stepProgressView.frame = NSRect(
                x: inset + textWidth + Self.contextRingGap,
                y: max(0, metaLabel.frame.midY - StepProgressView.barHeight / 2),
                width: StepProgressView.barWidth, height: StepProgressView.barHeight)
        }
    }

    /// 单行文字高度（转发到共用度量工具，避免两处公式各写一份）。
    private static func textHeight(for font: NSFont) -> CGFloat {
        TouchBarTextMetrics.textHeight(for: font)
    }

    override func layout() {
        super.layout()
        layoutContent()
    }

    @objc private func handlePan(_ gesture: NSPanGestureRecognizer) {
        guard gesture.state == .ended else { return }
        let translation = gesture.translation(in: self)
        if translation.x >= swipeThreshold {
            onSwipe?(-1) // 右滑 => 上一个
        } else if translation.x <= -swipeThreshold {
            onSwipe?(1) // 左滑 => 下一个
        }
    }

    /// 点一下：切换紧凑 / 详情（横滑不会走到这里，`require(toFail: pan)` 已保证）。
    @objc private func handleClick() {
        onToggle?()
    }
}

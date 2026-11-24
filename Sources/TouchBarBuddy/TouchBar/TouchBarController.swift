import AppKit
import Darwin

/// Touch Bar 控制器：构建 `NSTouchBar`、常驻呈现（私有 API + 优雅降级）、按状态刷新、处理交互。
///
/// 线程模型：所有 NSTouchBar/NSButton 操作均在主线程（轮询回调、App 激活通知都在主线程）。
final class TouchBarController: NSObject, NSTouchBarDelegate {

    // MARK: - 依赖

    private let provider: BuddyStateProvider
    private let voice: VoiceRecognizer
    private var poller: PollingService?

    // MARK: - 运行时状态

    private var state: TouchBarState = .idle
    private var focusedIndex = 0
    /// 任务条是否处于详情（两行）视图。
    ///
    /// - Note: 状态放在 controller 而不是视图里：`item` 每次重建都是新视图，
    ///   放视图里会「一重建就自动收起」。重置规则见 `rebuildTouchBar()` / `handleSwipe`。
    /// - Important: 初始值与「复位目标」都跟随 `Settings.taskDetailByDefault`，
    ///   不再硬编码 `false`。所有把展开态清零的地方统一走 `restingDetailExpanded`，
    ///   这样「默认详情模式」不会出现「滑一下任务就莫名收起了」的割裂。
    private var taskDetailExpanded = Settings.taskDetailByDefault

    /// 上一次已应用到 `taskDetailExpanded` 的「默认详情模式」取值。
    ///
    /// 用途：用户手动点开 / 收起之后，改**别的**设置项不该把他手动选的状态冲掉。
    /// 只有这个值真的变了（用户在设置面板里动了本项），才重新同步展开态。
    private var appliedDefaultExpanded = Settings.taskDetailByDefault

    /// 空闲时可停留的详情态取值：默认详情模式开 → 保持展开，关 → 收起。
    private var restingDetailExpanded: Bool { Settings.taskDetailByDefault }
    private var generation = 0
    private var isListening = false
    /// 瞬时提示（失败红字 / 安慰次要色，2 秒后清除）。
    ///
    /// - Note: 错误与安慰共用这一格，见 `TransientNotice` 的说明（290pt 挤不出第二格）。
    private var notice: TransientNotice?
    /// 每条进行中任务的「本次运行起始时刻」（key = 任务 id）。
    ///
    /// 数据库没有「本次任务开始时间」，只能由 App 观察：第一次看到它进入进行中时记下时刻，
    /// 一直累加直到任务离开进行中。见 `updateRunningSince(_:)`。
    private let elapsedStore = TaskElapsedStore()

    /// 从 WorkBuddy 界面读到的「本轮已处理时长」（秒）。
    ///
    /// 用户要求 Touch Bar 上显示的就是 WorkBuddy 红框里那个数（`已处理 1m8s`），
    /// 读不到时才退回 `elapsedStore` 的本地计时。随弹层检测一起在后台刷新。
    private var turnDurationSeconds: TimeInterval?

    /// 本轮已消耗积分（从 WorkBuddy 界面「已消耗 ◇ 10.56」读到）。
    ///
    /// 与 `turnDurationSeconds` 同一趟 AX 遍历取得，两者同源同时刻，不会出现
    /// 「时长是这一轮的、积分是上一轮的」这种错位。
    private var turnCredits: Double?

    /// 最新从 WorkBuddy 侧边栏 AX 读到的「当前选中会话」主标题（读不到为 nil）。
    private var selectedSessionTitle: String?
    /// 上次真正据此改过 `focusedIndex` 的标题。
    ///
    /// - Important: 只有标题**变化**时才覆盖 focusedIndex。否则用户在 Touch Bar 上横滑后，
    ///   下一轮轮询会因为「AX 仍读到同一个选中标题」而把焦点打回原任务 —— 横滑结果被作废。
    private var lastAppliedSelectedTitle: String?

    /// 「任务运行时常驻」：持有/释放阻止空闲熄屏的电源断言。
    private let keepAwakeService = KeepAwakeService()
    /// 待上屏的语音回显文本。
    ///
    /// 识别完成时先存这里、不动 Touch Bar；等注入成功后才 show 出来 ——
    /// 因为 dismiss+present 抢焦点会让 ⌘V 粘不进 WorkBuddy（2026-11-19 真机实测）。
    private var pendingEchoText: String?
    /// 上一次呈现的情绪脸；用于「只有脸变了才播动效」，避免每 3/5 秒抖一下。
    private var lastBuddyFace: BuddyFace?
    /// 本次重建要播的过渡动效（只有脸刚变化时非 nil，`makeItem` 消费一次）。
    private var pendingFaceTransition: BuddyFaceTransition?
    /// 是否还有一次「点击已被接收」的确认动效没播。
    ///
    /// - Important: 与 `pendingFaceTransition` **分开存**：确认动效不来自状态变化，
    ///   而来自一次 AXPress 成功。按完弹层不会立刻变成工作态（还有 0.5s 延迟，
    ///   且中间可能多次重建），所以不能塞进 `pendingFaceTransition` 让它被某次
    ///   不含 summary 的重建顺手消费掉。
    ///
    /// - Note: 1.5s 超时兜底，见 `acknowledgeTimeout`。
    private var pendingAckTransition = false
    /// 每次排队确认动效的自增序号，用来让「旧的超时」不要误清「新的排队」。
    private var ackToken = 0
    /// 空闲态统计（仅在空闲态查询，供 idle 时展示）。
    private var idleStats: IdleStats = .empty
    /// AX 读取是否在飞行中（保证同一时刻只有一个后台遍历，避免排队堆积）。
    ///
    /// - Note: 目前只有弹层检测走 AX。留这个闸门是因为弹层检测每 5 秒一次、
    ///   且点击后还会再检测一次，没有闸门会出现并发遍历。
    private var axFetchInFlight = false
    /// 当前检测到的弹层（nil = 没有弹层）。
    private var currentDialog: DialogSnapshot?
    /// 上一次弹层检测结果（用于「变化才重建」，避免 5 秒一抖）。
    private var lastDetectedDialog: DialogSnapshot?
    /// 当前弹层里识别到的权限请求（nil = 不是权限弹窗）。
    ///
    /// - Note: 单独存一份而不是塞进 `TouchBarState`：`.choice` 只关心「标题 + 按钮」，
    ///   而权限明细只影响布局选择。塞进状态机等于让它多带一个与归约无关的字段，
    ///   还会动到状态机现有一整套测试。
    private var currentPermission: PermissionRequest?
    /// 权限屏 2（逐项勾选）是否展开。
    private var permissionDetailShown = false
    /// 上一份权限请求的标题（用于「换了新弹窗就退回屏 1」，见 `requestDialogDetection`）。
    private var lastPermissionTitle: String?
    /// 权限项切换的重试计数（AX 忙时排队，避免无限递归重试）。
    private var permissionToggleAttempts = 0
    /// 弹层检测轮询（独立 5 秒节奏，与 3 秒状态轮询分开）。
    private var dialogPoller: PollingService?

    /// 弹层检测间隔（秒）。
    ///
    /// 为什么比状态轮询慢：弹层检测要唤醒 AX（0.3s）+ 遍历，成本比读 SQLite 高一个量级；
    /// 而弹层从开到关一般都有数秒，5 秒足够抓到，不会明显漏。
    static let dialogPollInterval: TimeInterval = 5.0

    /// 按压弹层选项的重试次数（AX 忙时排队，避免用户点了没反应）。
    static let dialogPressMaxAttempts = 3

    /// 点击确认动效的排队有效期（秒）。
    ///
    /// 为什么必须有超时：用户点了「允许」，弹层**没有**关掉（还在 `.choice` 态）时，
    /// bar 上根本没有 summary item 可以承载这次确认。若 flag 一直留着，
    /// 用户几秒后随便做个操作让 bar 回到工作态，那抹青绿会**突然**冒出来 ——
    /// 看起来像随机闪烁，比不反馈更糟。1.5s 足够覆盖正常的 0.5s 刷新延迟，
    /// 又短到不会让人忘记自己点过。
    static let acknowledgeTimeout: TimeInterval = 1.5

    /// 瞬时提示的停留时长（秒）。
    static let noticeDuration: TimeInterval = 2.0

    /// 语音识别回显的停留时长（秒）。
    ///
    /// 原为 1.5s，用户真机反馈「不够读完」，2026-11-19 调到 2.0s。
    /// 与错误提示时长相同也无妨：失败时红字会覆盖回显，不存在两条同时抢一格的问题。
    static let transcriptNoticeDuration: TimeInterval = 2.0

    /// 回显文案最多显示几个原文字（超出部分用 `…` 代替）。
    ///
    /// 依据：12pt 下一个汉字约 12pt，14 字约 168pt；加 🎙️ 与空格约 190pt。
    /// notice item 是 **prepend** 的，右边还有 voice(82pt) 与 summary(约 80pt)，
    /// 14 字已是「能读清一句短句」和「不把 voice 整块挤掉」的折中上限。
    /// - Note: 更长的文本只显示前 14 字，原文仍**完整**注入输入框，回显截断不影响功能。
    static let transcriptTextLimit = 14

    /// 把识别结果格式化成回显文案：`🎙️ <原文>`，超长截断到 `transcriptTextLimit` 字 + `…`。
    ///
    /// - Important: 这是纯函数（`internal` 而非 `private`），单测要直接钉住长度上限 ——
    ///   宽度超预算是「voice 被挤掉」这种只会在真机出现的失效，必须有自动化守卫。
    /// - Parameter text: 语音识别出的原文。
    /// - Returns: 可放进 `TransientNotice` 的短文案。
    static func transcriptNoticeText(_ text: String) -> String {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "🎙️" }
        let visible = cleaned.count <= transcriptTextLimit
            ? cleaned
            : String(cleaned.prefix(transcriptTextLimit)) + "…"
        let text = "🎙️ \(visible)"
        // 仅在 TB_DEBUG 下落盘：真机语音要真人说话才能触发，留一行可事后核对
        // 「系统到底听到了什么、回显被截成什么样」，不必靠用户复述。
        tbDebugLog("[TB] 识别回显文案：\(text)（原文 \(cleaned.count) 字）")
        return text
    }

    /// 失败后的安慰文案。
    ///
    /// - Note: 必须短。Touch Bar 可用宽度约 290pt，而它出现时左侧还有 summary + stats，
    ///   这条提示自己要能一眼看完（7 个字，约 84pt）。
    static let comfortText = "没关系，可以重试"

    /// 切换权限勾选后，等多久再重新读取勾选态（秒）。
    ///
    /// 与 `pasteboardHoldDelay` 同一个道理：AXPress 是投递出去的，Chromium 要跨进程把
    /// 点击转成 DOM 事件、再回写 `AXValue`。立刻回读只会读到旧状态，界面看起来「点了没反应」。
    static let permissionRefreshDelay: TimeInterval = 0.15
    /// 当前是否已完成 system-modal present（用于重建时先 dismiss 再 present）。
    private var isPresented = false
    /// 当前那条任务条视图（用于「只更新时长文字」时就地刷新，不重建 bar）。
    ///
    /// - Note: `weak` —— 视图由 Touch Bar 的 item 持有，controller 不该成为它的所有者；
    ///   item 被替换（重建 generation）后这里会自动变 nil，不会指着一个已经下线的视图。
    private weak var taskStripView: TaskStripView?
    private var touchBar: NSTouchBar?
    private var hostingWindow: NSWindow?
    private var workspaceObserver: NSObjectProtocol?
    /// 系统唤醒 / 屏幕点亮观察者。
    private var wakeObserver: NSObjectProtocol?
    /// Control Strip（系统栏）里的 WorkBar logo。
    ///
    /// - Important: 必须**强持有**。`addSystemTrayItem:` 把 item 交给系统托盘集合后，
    ///   系统那侧是弱引用语义 —— 本地没人持有就会被释放，格子变空白、点不动。
    private var systemTrayItem: NSCustomTouchBarItem?
    /// Control Strip 入口是否已安装（避免每次 app 激活都重复注册）。
    private var systemTrayInstalled = false

    /// 点击「跳转」时回调（由 AppDelegate 装配为激活 WorkBuddy 主窗口）。
    var onActivateWorkBuddy: (() -> Void)?

    // MARK: - 生命周期

    init(provider: BuddyStateProvider, voice: VoiceRecognizer) {
        self.provider = provider
        self.voice = voice
        super.init()
        configureVoiceCallbacks()
    }

    deinit {
        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        poller?.stop()
    }

    /// 启动：建窗口、建 bar、开轮询、监听 App 激活、立即刷新一次。
    func start() {
        setupHostingWindow()
        installSystemTrayEntry()
        rebuildTouchBar()
        poller = PollingService { [weak self] in self?.refresh() }
        poller?.start()

        // 弹层检测：独立 5 秒节奏，不依附于状态轮询（弹层随时可能在任何状态下弹出）。
        dialogPoller = PollingService(interval: Self.dialogPollInterval) { [weak self] in
            self?.requestDialogDetection()
        }
        dialogPoller?.start()
        requestDialogDetection()

        observeAppActivation()
        observeSystemWake()
        refresh()

        // 排障：TB_DEBUG=1 时把 Touch Bar 的窗口与视图树打出来，用于确认
        // 「item 已构建但没被加进视图层级」这类肉眼不可见的问题。
        if ProcessInfo.processInfo.environment["TB_DEBUG"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.dumpHierarchy()
            }
        }
    }

    // MARK: - 排障

    private func dumpHierarchy() {
        tbLog("[TB] === 窗口列表 ===")
        for w in NSApp.windows {
            let visible = w.isVisible ? "visible" : "hidden"
            tbLog("[TB] window \(type(of: w)) frame=\(w.frame) level=\(w.level.rawValue) \(visible)")
            dumpViews(w.contentView, depth: 1)
        }
    }

    private func dumpViews(_ view: NSView?, depth: Int) {
        guard let view = view, depth <= 7 else { return }
        let pad = String(repeating: "  ", count: depth)
        let title: String
        if let button = view as? NSButton {
            title = " title=\"\(button.title)\""
        } else if let field = view as? NSTextField {
            title = " text=\"\(field.stringValue)\""
        } else {
            title = ""
        }
        tbLog("[TB] \(pad)\(type(of: view)) frame=\(view.frame) hidden=\(view.isHidden)\(title)")
        for sub in view.subviews { dumpViews(sub, depth: depth + 1) }
    }

    /// 设置变更后立即重建一次（不等下一轮轮询，否则用户改完开关要等最多 3 秒才看到效果）。
    func applySettingsChange() {
        // 「默认详情模式」变了才动当前展开态；改极简 / 常驻时保留用户手动选的状态。
        let wanted = Settings.taskDetailByDefault
        if wanted != appliedDefaultExpanded {
            appliedDefaultExpanded = wanted
            taskDetailExpanded = wanted
            tbDebugLog("[TB] 默认详情模式变更 -> expanded=\(wanted)")
        }
        refresh(forceRebuild: true)
    }

    /// 系统唤醒 / 屏幕点亮后重新挂载 bar。
    ///
    /// 为什么需要：休眠会收掉系统模态 bar，而 `isPresented` 是本地标志、不会同步变 false，
    /// 于是唤醒后 bar 一直不回来（用户体感「过一会儿就熄了、再也不出现」）。
    func handleSystemWake() {
        tbLog("[TB] 系统唤醒：重新挂载常驻 bar")
        present()
    }

    /// 停止：停轮询、移除常驻 bar。
    func stop() {
        poller?.stop()
        poller = nil
        dialogPoller?.stop()
        dialogPoller = nil
        PrivateTouchBarBridge.shared.dismiss(touchBar: touchBar)
        isPresented = false
        // 退出时把 Control Strip 的常驻声明收回：不收回的话格子会留在系统栏上，
        // 但点它已经没有 app 响应 —— 一个「点了没反应」的图标比没有更糟。
        if systemTrayInstalled {
            PrivateTouchBarBridge.setControlStripPresence(for: TouchBarItemFactory.trayIdentifier,
                                                          present: false)
            systemTrayInstalled = false
        }
        // 丢弃还没播的确认动效；token +1 让已排队的超时回调失效（否则它会在
        // 退出后 1.5s 唤醒一个即将销毁的对象，虽然 weak self 不会崩，但是无谓唤醒）。
        pendingAckTransition = false
        ackToken += 1
        // 退出时必须释放断言，否则用户退出本工具后屏幕再也无法正常熄屏。
        keepAwakeService.update(shouldHold: false) { }
    }

    // MARK: - 刷新

    /// 读取最新 sessions → 归约 → **布局真的变了**才重建 bar。
    ///
    /// 这里有三档，不是两档（实测得出的，原因见下）：
    /// 1. 布局变了（任务增删、状态切换、弹层、统计）→ 重建（dismiss + present）；
    /// 2. 只有「距上次活动」的**文案**变了 → 就地改那一格，**不重建、不重挂**；
    /// 3. 什么都没变 → 只在 bar 真的掉了时补挂，见 `presentIfNeeded()`。
    ///
    /// - Important: 为什么必须单独有第 2 档 —— `TaskInfo.activityAge` 是「距上次活动秒数」，
    ///   它每轮轮询都会自然增长（同一个时间戳，`now` 变了，差值就变）。若直接拿
    ///   `TouchBarState ==` 判断「有没有变化」，这个字段会让比较**永远为 false**：
    ///   实测 62 秒里 `present 调用` 25 次、`present 跳过` **0 次**，
    ///   即「不重建」那条分支从未被执行过 —— 每 3 秒都在 dismiss + present 整条 bar。
    ///   把 volatile 字段踢出「是否重建」的判据、单独就地更新，才是真正止血。
    ///
    /// - Note: 状态没变时**不再重新 present**，只在 `isPresented == false`（bar 真的掉了）
    ///   时补挂一次，见 `presentIfNeeded()`。之前是无条件重挂，本意是看护
    ///   （系统在切换前台应用、显示通知、Mac 休眠唤醒等时机可能把 system-modal bar 收掉，
    ///   若不主动重挂，bar 会永久消失）；但轮询也是 3 秒一次，两者叠加就成了每分钟 20 次
    ///   可见的刷新。现在看护仍在，只是改成「掉了才补」，并把应用切换那条路径
    ///   保留为无条件重挂（`observeAppActivation()`）。
    private func refresh(forceRebuild: Bool = false) {
        let sessions = provider.fetchSessions()
        let newState = TouchBarStateMachine.reduce(sessions, dialog: currentDialog)
        tbDebugLog("[WorkBar] state=\(newState.summaryLabel) tasks=\(newState.tasks.count)")
        updateRunningSince(newState)

        // WorkBuddy 侧边栏切换会话 → 标题与详情要一起跟着切。
        // - Important: 必须在下面的 isSameLayout / metaTextChanged 比较**之前**定好 focusedIndex，
        //   否则标题和详情会用不同 index，用户又看到「详情换了、标题没换」。
        // - 只在 AX 选中标题**变化**时覆盖：读不到 / 标题没变时保留横滑结果（外部信号不打架）。
        let previousFocusedIndex = focusedIndex
        if let selected = selectedSessionTitle, selected != lastAppliedSelectedTitle {
            if let index = newState.tasks.firstIndex(where: { task in
                (task.status == .working || task.status == .active || task.status == .pending)
                    && SelectedSessionReader.matches(taskTitle: task.title,
                                                     selectedTitle: selected)
            }) {
                focusedIndex = index
                tbDebugLog("[TB] 跟随 WorkBuddy 选中会话：focusedIndex \(previousFocusedIndex) -> \(index)（\(newState.tasks[index].title)）")
            }
            // 匹配不到也标记已处理：不要把同一条读不到的标题每轮都重试、更不该打回横滑结果。
            lastAppliedSelectedTitle = selected
        }
        let focusChanged = focusedIndex != previousFocusedIndex

        // 常驻：只有「设置开启 **且** 有任务在跑」才阻止空闲熄屏。
        // 放在 refresh 里而不是设置回调里，是因为「有没有任务」本身也在变：
        // 任务一结束就要立刻释放断言，否则屏幕会一直亮着。
        let hasActive = newState.tasks.contains { $0.status == .working || $0.status == .active }
        keepAwakeService.update(
            shouldHold: KeepAwakePolicy.shouldHold(enabled: Settings.keepAwake,
                                                  hasActiveTasks: hasActive)
        ) { [weak self] in
            // 补挂：只是重新 present 同一份 bar，不重建 item。
            self?.present()
        }

        // 仅空闲态查询统计（非空闲态不用查，省开销）。
        let newIdleStats: IdleStats = newState.isIdle ? provider.fetchIdleStats() : .empty
        let layoutChanged = !Self.isSameLayout(state, newState)
        let statsChanged = (newIdleStats != idleStats)
        // 「只影响任务条第二行文字」的变化：时长与上下文占比都属于这一档。
        // 两者都不是布局问题，所以合并成同一个判据，走同一条就地刷新路径。
        let metaTextChanged = !Self.isSameActivityTexts(state, newState)
            || !Self.isSameContextTexts(state, newState)
            || !Self.isSameStepTexts(state, newState)

        if layoutChanged || statsChanged || forceRebuild {
            // 布局变了不代表用户想放弃当前选中的任务：横滑切到 (2/2) 后，只要任务还在，
            // 下一轮轮询就不该把焦点打回 0 —— 那样标题和序号都会跳回 (1/2)。
            // 只在索引真的越界时收缩；任务仍是原来那几个时保留用户的选择。
            if layoutChanged {
                focusedIndex = min(max(focusedIndex, 0), max(0, newState.tasks.count - 1))
            }
            state = newState
            idleStats = newIdleStats
            rebuildTouchBar()
        } else if metaTextChanged || focusChanged {
            // 只有数字在走 / 百分比在涨 / 聚焦任务被外部切换：直接把标题与那一格文字换掉。
            // 必须同步 `state`，否则下一轮又会拿旧的时长去比，变成每轮都判「变了」。
            state = newState
            refreshActivityAgeInPlace()
        } else {
            // 什么都没变：**只在 bar 真的掉了时才重挂**。
            //
            // 这里原来是无条件 `present()`，本意是幂等看护，但 `refresh()` 由轮询每 3 秒
            // 驱动一次，于是变成「每分钟 20 次重新 present」——实测日志里 present 的时间戳
            // 精确间隔 3.00 秒。用户能看到 Touch Bar 周期性刷新一下，
            // 每次还都要走一遍私有 API + 系统合成，纯浪费。
            presentIfNeeded()
        }
    }

    /// 维护「本次运行起始时刻」表。
    ///
    /// 为什么需要：数据库里只有 `created_at`（会话创建时间，长期会话会是几天前）
    /// 和 `updated_at` / `last_activity_at`（每轮有输出就刷新）。用前者会显示「7 天」，
    /// 用后者会「0,1,4,7…然后归零」。用户要的是**本次跑了多久**，只能由 App 自己记起点。
    ///
    /// 规则：
    /// - 某任务第一次出现在「进行中/计划中」里 → 记下当前时刻并**持久化**；
    /// - 之后只读取这个起点，不因有输出、切到待确认 / 选择态、重启 App 而重置；
    /// - 只有明确看到任务 completed / archived 才清起点。
    ///
    /// - Important: 旧实现「只要这一轮不在 activeIDs 里就清起点」是用户看到
    ///   「时间又回到上个版本」的直接原因：任务进待确认那一轮起点就没了。
    private func updateRunningSince(_ newState: TouchBarState) {
        let now = Date()
        // 先清真正结束的。
        for task in newState.tasks where task.status == .completed || task.status == .archived {
            elapsedStore.clear(task.id)
        }
        // 再进行中的补起点（已存在的会原样返回，不会刷新）。
        for task in newState.tasks where task.status == .working || task.status == .active {
            _ = elapsedStore.start(for: task.id, now: now)
        }
    }

    /// 当前聚焦任务「已运行多久」（秒）；非工作态或没有记录时为 nil。
    private var focusedElapsed: TimeInterval? {
        let tasks = state.tasks
        guard !tasks.isEmpty else { return nil }
        let index = min(max(focusedIndex, 0), tasks.count - 1)
        // 优先用 WorkBuddy 自己显示的「已处理 Xm Ys」—— 用户明确要求跟界面红框一致。
        if let turn = turnDurationSeconds { return turn }
        // 读不到 AX 时才退回本地计时。纯读取，绝不能顺手 start()，
        // 否则空闲态 / 待确认态被瞄一眼也会留下一个无意义的起点。
        let id = tasks[index].id
        guard let start = elapsedStore.startedDate(for: id) else { return nil }
        return Date().timeIntervalSince(start)
    }

    /// 就地更新「距上次活动」文案（不重建 bar）。
    ///
    /// - Note: 只改 `TaskStripView` 里那一个 label 的文字与颜色，不走 `rebuildTouchBar()`
    ///   —— 后者会 `dismiss` 再 `present`，那正是用户看到的「刷新一下」。
    /// - Note: 拿不到 strip（bar 还没被系统真正创建过 / 当前不是任务态）就什么都不做，
    ///   下一轮布局变化时自然会带上最新时长。
    private func refreshActivityAgeInPlace() {
        guard let strip = taskStripView, !state.tasks.isEmpty else { return }
        let index = min(max(focusedIndex, 0), state.tasks.count - 1)
        let elapsed = focusedElapsed
        // 标题与详情必须来自同一个 index、同一次调用：否则 rebuildTouchBar 未真正
        // 重建 item 时，详情被就地刷新切到新任务，标题却卡在旧任务（用户 2026-11-20 报的 bug）。
        // 用 taskText 单一真源生成，图标 / 序号与 makeTaskItem 完全一致。
        // 不包在 `if taskDetailExpanded` 里 —— 紧凑态的标题同样要跟着切换。
        let titleText = TouchBarItemFactory.taskText(
            task: state.tasks[index], index: index, total: state.tasks.count)
        strip.updateTitle(titleText)
        tbDebugLog("[TB] 标题同步 index=\(index)/\(state.tasks.count) title=[\(titleText)]")
        strip.updateElapsed(elapsed, activityAge: state.tasks[index].activityAge)
        // 详情视图的第二行也含时长与上下文比例，同样就地刷新；否则展开着的那一格会冻住。
        if taskDetailExpanded {
            let task = state.tasks[index]
            let meta = TouchBarItemFactory.taskMetaRendering(
                task: task,
                elapsed: elapsed,
                // 与 `makeTaskItem` 用同一个可用宽度算式，保证「首次构建」与
                // 「就地刷新」裁剪出来的段完全一致（否则会看到文字忽长忽短）。
                maxWidth: TouchBarItemFactory.taskItemWidth
                    - TaskStripView.expandedHorizontalInset * 2,
                graphicRing: Settings.graphicContextIcon,
                credits: turnCredits,
                showTaskStep: Settings.showTaskStep)
            strip.updateExpandedMeta(meta.attributed,
                                     ringTint: TouchBarItemFactory.ringTint(for: task), rendering: meta)
        }
        tbDebugLog("[TB] 就地更新时长：\(ActivityAge.formatActivityAge(elapsed ?? state.tasks[index].activityAge) ?? "nil")")
    }

    // MARK: - 状态比较（忽略 volatile 字段）

    /// 两个状态在**布局**层面是否相同（忽略 `activityAge`）。
    ///
    /// 为什么不用 `TouchBarState.==`：`TaskInfo` 的 `==` 包含 `activityAge`，
    /// 而它是「距上次活动秒数」——同一个数据库时间戳，`now` 每轮都变，差值必然变。
    /// 直接比较等于「每轮都判定变了」，于是每 3 秒重建一次 bar（dismiss + present）。
    ///
    /// - Parameters:
    ///   - lhs: 当前已呈现的状态。
    ///   - rhs: 本轮归约出的新状态。
    /// - Returns: 视图结构是否完全一致（时长不算）。
    private static func isSameLayout(_ lhs: TouchBarState, _ rhs: TouchBarState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle):
            return true
        case let (.pending(left), .pending(right)),
             let (.working(left), .working(right)),
             let (.unread(left), .unread(right)):
            // `droppingAge` 抹掉了秒数，但「是否卡住」是**跨阈值的一比特状态**，
            // 不是连续值：它决定摘要写「进行中」还是「疑似卡住」。
            // 若只比抹掉 age 后的任务，跨过 120 秒那一刻不会被判为布局变化，
            // 摘要词就永远停在「进行中」。加这一项后，只有跨阈值那一次会重建，
            // 普通走秒仍走第三档就地更新，不会引入周期性刷新。
            return droppingAge(left) == droppingAge(right)
                && left.map(\.isStale) == right.map(\.isStale)
        case let (.choice(leftTitle, leftOptions), .choice(rightTitle, rightOptions)):
            return leftTitle == rightTitle && leftOptions == rightOptions
        default:
            // 连状态种类都变了（空闲 ⇄ 进行中 ⇄ 待确认 ⇄ 弹层）：一定要重建。
            return false
        }
    }

    /// 两个状态里每个任务的**时长文案**是否一致。
    ///
    /// 比的是格式化后的文案（`"12s"` / `"3m"` / `"2h"`）而不是原始秒数：文案没变就没必要动界面 ——
    /// 秒数每轮都在变，但它在同一秒 / 同一分钟里会格式化成同一个字符串，
    /// 这才是省掉无意义刷新的正确判据（比的是「用户能看到的东西」，不是「内部数值」）。
    ///
    /// - Note: 秒档下这条判定几乎每轮都会返回 false（`12s → 15s`），
    ///   于是走 `refreshActivityAgeInPlace()` —— 那是**纯文字替换**，不重建、不重挂，
    ///   属于「在走秒」而不是「在刷新」。这是用户确认过的取舍：
    ///   他要求秒数可见，我们负责保证那种变化不带动布局。
    private static func isSameActivityTexts(_ lhs: TouchBarState, _ rhs: TouchBarState) -> Bool {
        let left = lhs.tasks.map { ActivityAge.formatActivityAge($0.activityAge) }
        let right = rhs.tasks.map { ActivityAge.formatActivityAge($0.activityAge) }
        return left == right
    }

    /// 两个状态里每个任务的**上下文占比文案**是否一致。
    ///
    /// 比的是格式化后的 `"上下文 53%"` 而不是原始比例：界面上看到的就是这个文案，
    /// 一两个 token 的变化不会改变百分比，也就没必要动界面。
    ///
    /// - Note: 与 `isSameActivityTexts` 一样只影响详情第二行文字，所以归入**就地刷新**那一档，
    ///   绝不参与「是否重建 bar」的判定（否则又要每 3 秒重建一次）。
    private static func isSameContextTexts(_ lhs: TouchBarState, _ rhs: TouchBarState) -> Bool {
        let left = lhs.tasks.map { ContextUsage.format($0.contextUsage) }
        let right = rhs.tasks.map { ContextUsage.format($0.contextUsage) }
        return left == right
    }

    /// 两个状态里每个任务的「当前步骤文案」是否一致。
    ///
    /// 步骤完成时文案会变（例如 `2/8 写 PRD` → `3/8 搭骨架`），但它只影响详情第二行，
    /// 所以和时长 / 上下文一样归入**就地刷新**那一档，绝不参与重建判定。
    private static func isSameStepTexts(_ lhs: TouchBarState, _ rhs: TouchBarState) -> Bool {
        let left = lhs.tasks.map { TaskStep.segmentText($0.stepProgress) }
        let right = rhs.tasks.map { TaskStep.segmentText($0.stepProgress) }
        return left == right
    }

    /// 把一个任务快照的 `activityAge` 清空（其余字段原样拷贝）。
    ///
    /// - Note: 用「拷贝一份把 volatile 字段抹掉」而不是自建字符串签名：
    ///   字符串签名一旦漏字段就会静默失效（少比一个字段 = 界面上那处永远不更新），
    ///   而 `TaskInfo` 的成员在编译期强制列全 —— 以后加字段时若忘了带上，
    ///   拷贝处会直接编译不过。
    /// - Important: **故意不传 `contextUsage` 与 `stepProgress`**。它们和 `activityAge`
    ///   一样是慢变量，但只影响详情第二行的文字，不该触发整条 bar 重建。
    ///   不传 → 两边都取默认 nil → 比较时互相抵消。若将来「顺手补全」把这两项带上，
    ///   就会退回「每 3 秒 dismiss + present 整条 bar」的老毛病（见 `refresh` 的说明）；
    ///   它们的变化由 `isSameContextTexts` / `isSameStepTexts` 走就地刷新处理。
    private static func droppingAge(_ tasks: [TaskInfo]) -> [TaskInfo] {
        tasks.map { task in
            TaskInfo(id: task.id,
                     title: task.title,
                     status: task.status,
                     unread: task.unread,
                     model: task.model,
                     groupID: task.groupID,
                     groupTitle: task.groupTitle,
                     buddyName: task.buddyName,
                     modelDisplayName: task.modelDisplayName,
                     modelMultiplier: task.modelMultiplier,
                     activityAge: nil)
        }
    }

    /// 仅在「bar 不在位」时重新挂载。
    ///
    /// - 为什么不再每次 refresh 都无条件 present：曾经每 3 秒挂一次（实测 60 秒 8 次），
    ///   用户能看到 Touch Bar 周期性刷新一下。`isPresented` 已经是 `present()` 的返回结果，
    ///   直接拿它当守卫即可 —— 系统没把 bar 收掉时我们什么都不用做。
    /// - Note: 这个守卫只对**轮询看护**成立。应用切换后的重挂必须无条件走 `present()`，
    ///   理由见 `observeAppActivation()`：那条路径上 `isPresented` 不可信。
    private func presentIfNeeded() {
        guard !isPresented else {
            tbDebugLog("[TB] present 跳过：bar 已挂载")
            return
        }
        tbDebugLog("[TB] present 补挂：bar 已丢失")
        present()
    }

    // MARK: - 弹层（需求 ③）

    /// 后台检测一次弹层；**结果变化时**才刷新 Touch Bar。
    ///
    /// 三条约束：
    /// 1. `axFetchInFlight` 保证同一时刻只跑一个 AX 遍历（AX 遍历很贵，且并发没意义）；
    /// 2. 必须在后台队列（含 0.3s 唤醒 + 最长 2.5s 遍历，主线程会卡死 Touch Bar）；
    /// 3. 结果没变就不重建（否则每 5 秒闪一下）。
    /// - Note: 检测是**纯读取**，不会点任何控件，所以不会在用户眼前弹面板。
    private func requestDialogDetection() {
        guard !axFetchInFlight else {
            tbDebugLog("[TB] 已有 AX 任务在跑，跳过本轮弹层检测")
            return
        }
        axFetchInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let detected = self.provider.detectDialog()
            // 同一趟后台 AX 里顺手读「已处理 Xm Ys」与「已消耗 ◇ N」；不与弹层检测并发，省一次唤醒。
            let turn = TurnDurationReader.read()
            DispatchQueue.main.async {
                self.axFetchInFlight = false
                let creditsChanged = self.turnCredits != turn.credits
                let selectedChanged = self.selectedSessionTitle != turn.selectedSessionTitle
                if self.turnDurationSeconds != turn.seconds || creditsChanged || selectedChanged {
                    self.turnDurationSeconds = turn.seconds
                    self.turnCredits = turn.credits
                    self.selectedSessionTitle = turn.selectedSessionTitle
                    // WorkBuddy 退出后选中标题变 nil：同时清掉「已应用」标记，
                    // 这样重开后即便又选中同一个会话，也会当作新变化重新匹配聚焦任务。
                    if turn.selectedSessionTitle == nil { self.lastAppliedSelectedTitle = nil }
                    tbDebugLog("[TB] WorkBuddy 轮次：耗时=\(turn.seconds.map { ActivityAge.formatActivityAge($0) ?? "nil" } ?? "读不到") 积分=\(TurnDurationReader.formatCredits(turn.credits) ?? "读不到") 选中=\(turn.selectedSessionTitle ?? "读不到")")
                    self.refresh()
                }
                let changed = (detected != self.lastDetectedDialog)
                let permissionsChanged = (detected?.permissions != self.currentPermission)
                self.lastDetectedDialog = detected
                self.currentDialog = detected
                self.currentPermission = detected?.permissions

                // 权限两屏的复位规则：
                // 1. 弹层消失 → 一定退回屏 1（否则下次弹窗一出来就是明细屏）；
                // 2. 换了一个**新标题**的权限请求 → 也退回屏 1；
                // 3. 只是勾选态变了（标题没变）→ **保持当前屏**，否则用户勾完第一项就被
                //    弹回屏 1，想勾第二项得再点一次标题，逐项勾选直接变成折磨。
                let title = detected?.permissions?.title
                if detected == nil || title != self.lastPermissionTitle {
                    self.permissionDetailShown = false
                }
                self.lastPermissionTitle = title

                guard changed else { return }
                if let dialog = detected {
                    tbLog("[TB] 弹层出现：title=\(dialog.title) options=\(dialog.options.joined(separator: "/"))")
                    if let permissions = dialog.permissions {
                        let items = permissions.items.map {
                            "\($0.label)=\($0.granted ? "✓" : "☐")"
                        }
                        tbLog("[TB] 权限请求：\(permissions.title)（\(items.joined(separator: " | "))）")
                    }
                } else {
                    tbLog("[TB] 弹层消失")
                }
                // 状态机要重新归约（弹层优先级最高），统一走 refresh 保证一条路径。
                // - Note: 权限项变化时**必须**强制重建：`.choice` 只带 title/options，
                //   勾选态变了不会让 state 变化，`refresh` 的常规分支会走 present()
                //   而不重建，屏 2 的 ✅/☐ 就永远停在旧状态。
                self.refresh(forceRebuild: permissionsChanged)
            }
        }
    }

    /// 点击 Touch Bar 上的弹层选项：重新检测 → 找到同文本按钮 → AXPress。
    ///
    /// - Parameter label: 选项文本（铺在按钮上的那一串）。
    /// - Note: **绝不复用缓存的 `AXUIElement`** —— 弹层每次重绘都会让旧元素失效，
    ///   缓存后按压会静默失败。所以每次点击都重新 `detect` 一遍。
    func pressDialogOption(_ label: String, attempt: Int = 1) {
        let target = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return }

        // AX 正忙（例如恰好在做 5 秒检测）：稍后重试，避免用户点了没反应。
        guard !axFetchInFlight else {
            guard attempt < Self.dialogPressMaxAttempts else {
                tbLog("[TB] 按压「\(target)」放弃：AX 一直忙（已重试 \(attempt) 次）")
                showTransientError("忙碌，请重试")
                return
            }
            tbLog("[TB] AX 忙碌，0.4s 后重试按压「\(target)」（第 \(attempt + 1) 次）")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.pressDialogOption(target, attempt: attempt + 1)
            }
            return
        }

        tbLog("[TB] 点击弹层选项：\(target)")
        axFetchInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let pressed = DialogDetector.pressOption(target)
            DispatchQueue.main.async {
                self.axFetchInFlight = false
                guard pressed else {
                    // 按不到就明确告诉用户，别静默（按钮已消失是最常见的情况）。
                    self.showTransientError("按钮已消失")
                    return
                }
                tbLog("[TB] 弹层选项按压成功：\(target)，0.5s 后刷新")
                self.queueAcknowledgement()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self = self else { return }
                    // 按完弹层大概率已经关了：先乐观清空，再让下一轮检测确认。
                    self.currentDialog = nil
                    self.lastDetectedDialog = nil
                    // 权限态一并清掉：不清的话，弹窗关掉后 `currentPermission` 还在，
                    // 下一个无关弹层会被当成权限弹窗来铺（布局直接错乱）。
                    self.currentPermission = nil
                    self.lastPermissionTitle = nil
                    self.permissionDetailShown = false
                    self.refresh()
                    self.requestDialogDetection()
                }
            }
        }
    }

    /// 排一次「点击已被接收」的确认动效（只在 AXPress **成功**后调用）。
    ///
    /// 为什么不直接改 UI：此时还在 `.choice` 态，bar 上是标题 + 选项，**没有 summary**
    /// 可以承载变色。所以只排队，等 0.5s 后弹层清空、bar 回到工作态重建时再播。
    ///
    /// - Note: `ackToken` 是防止「连续点两次」时第一次的超时把第二次的排队清掉：
    ///   两个 1.5s 定时器都在，但只有与当前 token 一致的那个有权清理。
    private func queueAcknowledgement() {
        ackToken += 1
        let token = ackToken
        pendingAckTransition = true
        tbDebugLog("[TB] 点击反馈：已排队确认动效")

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.acknowledgeTimeout) { [weak self] in
            guard let self = self,
                  self.pendingAckTransition,
                  self.ackToken == token else { return }
            self.pendingAckTransition = false
            tbDebugLog("[TB] 点击反馈：1.5s 超时，丢弃未播的确认动效")
        }
    }

    // MARK: - 权限屏（V17）

    /// 权限屏 1 标题 / 屏 2 「返回」：在两屏之间切换。
    private func handlePermissionDetail() {
        guard currentPermission != nil else { return }
        permissionDetailShown.toggle()
        tbLog("[TB] 权限屏切换：detail=\(permissionDetailShown)")
        rebuildTouchBar()
    }

    /// 点某个权限勾选项：切换它，然后**重新读取**勾选态。
    private func handlePermissionToggle(_ label: String) {
        let target = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return }

        // 与 `pressDialogOption` 同一道闸门：AX 正在跑就排队重试，避免用户点了没反应。
        guard !axFetchInFlight else {
            guard permissionToggleAttempts < Self.dialogPressMaxAttempts else {
                tbLog("[TB] 切换权限「\(target)」放弃：AX 一直忙")
                permissionToggleAttempts = 0
                showTransientError("忙碌，请重试")
                return
            }
            permissionToggleAttempts += 1
            tbLog("[TB] AX 忙碌，0.4s 后重试切换权限「\(target)」")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.handlePermissionToggle(target)
            }
            return
        }
        permissionToggleAttempts = 0

        tbLog("[TB] 切换权限项：\(target)")
        axFetchInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let pressed = DialogDetector.pressCheckbox(target)
            DispatchQueue.main.async {
                self.axFetchInFlight = false
                guard pressed else {
                    // 勾选框可能已经随弹窗消失：明确报一句，再让检测去收敛界面。
                    self.showTransientError("权限项没点动")
                    self.requestDialogDetection()
                    return
                }
                // 勾选态必须重新读：本地翻转一旦与 WorkBuddy 的真实状态不一致，
                // Touch Bar 就会显示「已勾」而实际没勾 —— 用户以为授权了，其实没有。
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.permissionRefreshDelay) { [weak self] in
                    self?.requestDialogDetection()
                }
            }
        }
    }

    /// 点「允许」/「取消」：复位两屏状态后，用**真实按钮文本**去按。
    ///
    /// - Parameter semantic: 语义标签（`PermissionParser.allowLabel` / `cancelLabel`）。
    private func handlePermissionDecision(_ semantic: String) {
        // 先复位：这一下之后弹窗大概率就关了，若不复位，下次弹窗一出来直接停在屏 2。
        permissionDetailShown = false

        guard let dialog = currentDialog else {
            tbLog("[TB] 权限操作「\(semantic)」跳过：弹窗已消失")
            showTransientError("弹窗已消失")
            rebuildTouchBar()
            return
        }

        // 界面上的按钮文案常带装饰（「允许 ✓」「取消 (Esc)」），精确匹配会失败，
        // 而失败的表现只是「点了没反应」，极难排查 —— 所以先做一次语义匹配。
        guard let label = PermissionParser.matchOption(semantic, in: dialog.options) else {
            tbLog("[TB] 权限操作失败：选项里没有「\(semantic)」"
                   + "（当前：\(dialog.options.joined(separator: "/"))）")
            showTransientError("找不到\(semantic)按钮")
            rebuildTouchBar()
            return
        }
        pressDialogOption(label)
    }

    private func rebuildTouchBar() {
        generation += 1
        // 重建时把详情态一起记下来。「默认详情模式」改的是**初始态**，
        // 一旦没生效，界面上只表现为「点了开关没反应」—— 日志是唯一能区分
        // 「设置没读到」和「设置读到了但视图没跟随」的线索。
        // Note: 只在重建时打，不走 3 秒轮询，不会刷屏。
        // 带上步骤文案：开了「任务步骤」却没看到 `3/8 …` 时，能区分是
        // 「provider 没读到步骤文件」还是「读到了但第二行没画出来」。
        let stepText = state.tasks.first.flatMap { TaskStep.segmentText($0.stepProgress) } ?? "无"
        tbDebugLog("[TB] 重建 bar：expanded=\(taskDetailExpanded) 任务数=\(state.tasks.count) 步骤=\(stepText)")

        // 旧的 item 马上会因为 generation 变化被系统丢弃，先把引用放开，
        // 免得「就地更新时长」写到一个已经不在界面上的视图。
        taskStripView = nil

        // 详情视图只在「有进行中任务」时有意义。任务清空 / 进入空闲、待确认、待读、
        // 弹层态时回到 resting 态（默认紧凑；开了「默认详情模式」则保持展开）。
        if case .working(let workingTasks) = state, !workingTasks.isEmpty {
            // 保持用户当前选择。
        } else if taskDetailExpanded != restingDetailExpanded {
            taskDetailExpanded = restingDetailExpanded
            tbDebugLog("[TB] 任务条详情视图复位：当前不是进行中任务态 -> expanded=\(taskDetailExpanded)")
        }

        // 情绪脸与过渡动效：**只在脸变化时**播一次。
        //
        // 为什么把判断放在 rebuild 而不是 refresh：`refresh()` 的最后一档（什么都没变）
        // 不走 rebuild，所以这里天然不会被「没变化」的重挂触发；而 rebuild 的其它调用方
        // （横滑切任务、语音状态变化）脸通常没变，`transition(from:)` 会返回 nil。
        let face = BuddyFace.resolve(state: state, hasFailure: notice != nil)
        pendingFaceTransition = lastBuddyFace.flatMap { face.transition(from: $0) }
        // 点击确认优先于「脸变了」的动效：用户刚按完的 0.5s 内，最重要的信号是「收到了」。
        //
        // - Important: **这里不清 pendingAckTransition**。本次重建可能仍停在 `.choice` 态
        //   （弹窗没关 / 检测还没收敛），bar 上没有 summary item，动效无处可播；
        //   清了就永远不会播。flag 只由 delegate 真正消费 `.acknowledge` 时清除，
        //   或由 1.5s 超时清理（`queueAcknowledgement()`）。
        if pendingAckTransition { pendingFaceTransition = .acknowledge }
        lastBuddyFace = face

        // 复用同一个 NSTouchBar 实例，只更新 defaultItemIdentifiers（delegate 会被重新询问）。
        //
        // 为什么不能每次新建：system-modal 位置同时只认一个 bar 对象。若在上一个 bar 仍处于
        // present 状态时再 present 一个**新**对象，两者会互相顶掉，结果一个都不显示
        // （真机实测：启动时先 present(items=2) 再 present(items=3)，Touch Bar 全黑）。
        // 复用同一实例后，重复 present 才是幂等的。
        let bar: NSTouchBar
        if let existing = touchBar {
            bar = existing
        } else {
            bar = NSTouchBar()
            bar.delegate = self
            touchBar = bar
            hostingWindow?.touchBar = bar
        }

        // 已 present 时先 dismiss 再更新 identifiers 再 present，强制系统重新询问 delegate。
        if isPresented {
            PrivateTouchBarBridge.shared.dismiss(touchBar: bar)
            isPresented = false
        }

        bar.defaultItemIdentifiers = TouchBarItemFactory.identifiers(
            for: state,
            generation: generation,
            notice: notice,
            idleStats: idleStats,
            permissions: currentPermission,
            permissionDetailShown: permissionDetailShown,
            minimalMode: Settings.minimalMode,
            layoutOrder: Settings.layoutOrder
        )
        present()
    }

    // MARK: - 交互

    private func handleSwipe(_ direction: Int) {
        let count = state.tasks.count
        guard count > 0 else { return }
        let next = focusedIndex + direction
        // 循环切换。
        focusedIndex = ((next % count) + count) % count
        // 换了任务：回到 resting 态。默认模式下「紧凑」才是例外 ——
        // 默认详情模式开着时切任务不该突然收起，那会让「默认两行」变成「随机一行」。
        // - Note: 展开态不会显示上一条的旧信息 —— `rebuildTouchBar()` 会用新的
        //   聚焦任务重新生成 meta，不存在「看的是旧任务」的问题。
        if taskDetailExpanded != restingDetailExpanded {
            taskDetailExpanded = restingDetailExpanded
            tbDebugLog("[TB] 横滑切任务：详情视图复位 -> expanded=\(taskDetailExpanded)")
        }
        rebuildTouchBar()
    }

    /// 点任务条：紧凑 ⇄ 详情。
    private func handleTaskToggle() {
        guard !state.tasks.isEmpty else { return }
        taskDetailExpanded.toggle()
        tbDebugLog("[TB] 任务条点击：expanded=\(taskDetailExpanded)")
        rebuildTouchBar()
    }

    private func handleJump() {
        onActivateWorkBuddy?()
    }

    private func handleVoiceToggle() {
        // 录音前先把 WorkBuddy 提到前台。
        //
        // 为什么在这里做：用户点 Touch Bar 时前台往往还是终端 / 访达（我们自己是
        // LSUIElement，从不抢焦点）。激活晚到「粘贴那一刻」也来得及，但早一步能让
        // 用户在说话期间**看见**自己正在往哪个窗口输入 —— 这是缺陷 2 要的可见性。
        // 激活失败不阻断录音：用户可能只是想先看看识别结果。
        AppActivation.activate()
        voice.toggleRecording()
    }

    /// 显示一条 2 秒的红色瞬时错误提示（用于语音/授权/注入失败的可视反馈），随后自动恢复正常态。
    ///
    /// - Parameter comfort: 是否在红字退场后补一条「安慰」提示。
    ///   **只给真失败传 true**（识别失败 / 注入失败）；「需授权」「忙碌」这类要用户动手的
    ///   提示后面再补一句「没关系，可以重试」是自相矛盾的。
    private func showTransientError(_ message: String, comfort: Bool = false) {
        show(TransientNotice(text: message, style: .error), duration: Self.noticeDuration) { [weak self] in
            guard comfort else { return }
            self?.showComfort()
        }
    }

    /// 「安慰」提示：同一个提示位换成次要色，文案固定。
    ///
    /// 为什么排在红字之后而不是同时：一格只能显示一条。先红字（用户需要知道错在哪），
    /// 再换成`没关系，可以重试`（把台阶递上），顺序比挤在一起更符合「先报错、再安抚」。
    private func showComfort() {
        show(TransientNotice(text: Self.comfortText, style: .comfort), duration: Self.noticeDuration)
    }

    /// 显示一条瞬时提示，`duration` 秒后清除并执行 `then`。
    ///
    /// - Note: 清除前会核对「当前这条还是不是我刚显示的那条」：期间若被更新的提示顶替，
    ///   直接跳过，否则会把别人的提示提前清掉（真机上表现为提示闪一下就没了）。
    private func show(_ notice: TransientNotice,
                      duration: TimeInterval,
                      then followUp: (() -> Void)? = nil,
                      skipInitialRebuild: Bool = false) {
        self.notice = notice
        tbDebugLog("[TB] 瞬时提示：设置 \(duration)s「\(notice.text)」skipRebuild=\(skipInitialRebuild)")
        // 回显走 skipInitialRebuild：识别完成时本已 rebuild 过一次（onStateChange(.finished)），
        // 紧接着再为回显 dismiss+present 一次会抢走 WorkBuddy 的键盘焦点，
        // 导致紧随其后的 ⌘V 投递失败（真机：输入框内容长度始终不变）。
        // 回显只先记数据，等注入完成后由调用方补一次 rebuild 上屏。
        if !skipInitialRebuild { rebuildTouchBar() }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self = self, self.notice == notice else { return }
            self.notice = nil
            tbDebugLog("[TB] 瞬时提示：清除「\(notice.text)」")
            self.rebuildTouchBar()
            followUp?()
        }
    }

    // MARK: - 语音回调装配

    private func configureVoiceCallbacks() {
        voice.onStateChange = { [weak self] voiceState in
            guard let self = self else { return }
            switch voiceState {
            case .listening:
                self.isListening = true
            case .denied:
                self.isListening = false
                // 未授权要用户去系统设置动手，不补安慰（那会让提示自相矛盾）。
                self.showTransientError("需授权语音/麦克风")
            case .failed(let reason):
                self.isListening = false
                // 真失败（没听清 / 识别中断 / 注入失败）→ 红字之后接一条安慰。
                self.showTransientError(reason, comfort: true)
            default:
                self.isListening = false
            }
            tbLog("[WorkBar] 语音状态: \(voiceState)")
            self.rebuildTouchBar()
        }
        // 注入结束后再让回显上屏：回显若先 rebuild Touch Bar，dismiss+present 会抢走
        // WorkBuddy 的键盘焦点，紧随其后的 ⌘V 就粘不进去（真机 2026-11-19 实测：
        // 输入框内容长度始终不变，注入连续两次回读失败）。所以这里先用 skipInitialRebuild
        // 把 notice 数据记好、界面不动，等注入完成回调到达再补一次 rebuild。
        voice.onInjectionFinished = { [weak self] succeeded in
            guard let self = self, let text = self.pendingEchoText else { return }
            self.pendingEchoText = nil
            // 成功与失败都显示回显：注入失败时用户更需要知道「系统到底听到了什么」，
            // 否则只会看到一句「粘贴未生效」，连自己说了什么都无从判断。
            // 失败时这条回显会紧接着被 `onStateChange(.failed)` 的红字覆盖 —— 失败优先，
            // 顺序上仍是「先让你看见听到的内容，再告诉你没粘上」。
            self.show(TransientNotice(text: Self.transcriptNoticeText(text), style: .info),
                      duration: Self.transcriptNoticeDuration)
        }
        voice.onTranscript = { [weak self] text in
            guard let self = self else { return }
            // 暂存回显文本，等注入完成后再上屏 —— 此刻绝不碰 Touch Bar，
            // 否则 dismiss+present 抢焦点会让紧随其后的 ⌘V 粘贴落空。
            self.pendingEchoText = text
            // 识别完成 => 通过剪贴板 + ⌘V 填入当前前台应用（WorkBuddy）输入框。
            self.voice.insertText(text)
        }
    }

    // MARK: - NSTouchBarDelegate

    func touchBar(_ touchBar: NSTouchBar,
                  makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        // 过渡动效只播一次：系统对同一个 generation 可能多次询问 item（切前台、重排时都会），
        // 不清掉的话「完成」会被连播两三遍，看起来像卡顿而不是庆祝。
        let isSummary = TouchBarItemFactory.kind(of: identifier) == "summary"
        let transition = isSummary ? pendingFaceTransition : nil
        if isSummary {
            // 确认动效只有真正进了 summary 才算播出去，此刻才清 flag —— 见
            // `rebuildTouchBar()` 里「为什么不在重建时清」的说明。
            if transition == .acknowledge { pendingAckTransition = false }
            pendingFaceTransition = nil
        }

        let handlers = TouchBarItemFactory.Handlers(
            onJump: { [weak self] in self?.handleJump() },
            onVoiceToggle: { [weak self] in self?.handleVoiceToggle() },
            onSwipe: { [weak self] direction in self?.handleSwipe(direction) },
            onTaskToggle: { [weak self] in self?.handleTaskToggle() },
            onDialogOption: { [weak self] label in self?.pressDialogOption(label) },
            onPermissionDetail: { [weak self] in self?.handlePermissionDetail() },
            onPermissionToggle: { [weak self] label in self?.handlePermissionToggle(label) },
            onPermissionAllow: { [weak self] in
                self?.handlePermissionDecision(PermissionParser.allowLabel)
            },
            onPermissionCancel: { [weak self] in
                self?.handlePermissionDecision(PermissionParser.cancelLabel)
            },
            onTrayTap: { [weak self] in self?.handleTrayTap() }
        )
        let item = TouchBarItemFactory.makeItem(
            identifier: identifier,
            state: state,
            focusedIndex: focusedIndex,
            isListening: isListening,
            notice: notice,
            face: BuddyFace.resolve(state: state, hasFailure: notice != nil),
            faceTransition: transition,
            idleStats: idleStats,
            permissions: currentPermission,
            taskElapsed: focusedElapsed,
            taskExpanded: taskDetailExpanded,
            graphicContextIcon: Settings.graphicContextIcon,
            turnCredits: turnCredits,
            showTaskStep: Settings.showTaskStep,
            handlers: handlers
        )
        // 记住任务条视图：轮询发现「只有时长数字在走」时要直接改它的文字，
        // 而不是重建整条 bar。`weak` 持有，item 被系统换掉后自动失效。
        if let custom = item as? NSCustomTouchBarItem,
           let strip = custom.view as? TaskStripView {
            taskStripView = strip
        }
        return item
    }

    // MARK: - 常驻（私有 API）

    /// 安装 Control Strip（Touch Bar 最右侧系统栏）里的 WorkBar logo。
    ///
    /// 用户价值：用右上角「×」把整条 bar 关掉之后，那个格子还在，点它就能重新打开
    /// —— 也就是「关闭 / 打开」由用户自己控制（用户明确要求的行为）。
    ///
    /// - Note: 失败不致命，也不重试到死：状态栏菜单里有「重新挂载 Touch Bar」这一条
    ///   纯公开 API 的兜底入口，用户永远有办法把 bar 弄回来。
    private func installSystemTrayEntry() {
        guard !systemTrayInstalled else { return }
        let item = TouchBarItemFactory.makeTrayItem { [weak self] in self?.handleTrayTap() }
        // 记一行图标实际取值：真机上图标「看不见 / 形状不对」时，先看这行就能分清
        // 是「资源没取到落到兜底」还是「取到了但没被着色」。
        if let button = item.view as? NSButton, let icon = button.image {
            tbLog("[WorkBar] Control Strip 图标 size=\(icon.size) template=\(icon.isTemplate) reps=\(icon.representations.count)")
        }
        // 先强持有再注册：见 `systemTrayItem` 的说明（系统那侧不持有）。
        systemTrayItem = item
        systemTrayInstalled = PrivateTouchBarBridge.installSystemTrayItem(
            item,
            identifier: TouchBarItemFactory.trayIdentifier
        )
    }

    /// 点击 Control Strip 里的 WorkBar logo => 重新挂载常驻 bar。
    private func handleTrayTap() {
        tbLog("[WorkBar] 点击 Control Strip 图标 => 重新挂载")
        remount()
    }

    /// 重新挂载常驻 bar（Control Strip logo 与状态栏菜单共用这一条路径）。
    ///
    /// ## 为什么这里必须无条件 `present()`
    /// 这两个入口存在的唯一意义就是「用户刚用 × 把 bar 关掉了，现在想打开」。
    /// 而 × 是系统直接 dismiss 的，我们收不到任何回调，`isPresented` 仍然是 `true`
    /// —— 一旦在这个路径上信它（走 `presentIfNeeded`），用户点一次没反应、再点还是没反应，
    /// 就彻底失去了「手动打开」的能力。`present` 本身幂等，重复调用只是几十微秒。
    ///
    /// ## 为什么还要 `refresh()`
    /// bar 被收掉的这段时间里数据还在跑（任务可能已经完成、切走）。重新挂载时如果沿用
    /// 旧状态，用户会看到一个「关之前的那一刻」的陈旧画面，看起来像卡死。
    /// `refresh()` 会按当前真实状态重建，挂上去就是新的。
    func remount() {
        present()
        refresh()
    }

    /// 重新 present 当前 bar（幂等、廉价），保证跨 app 切换后仍常驻。
    private func present() {
        guard let bar = touchBar else {
            tbLog("[WorkBar] present 跳过：touchBar 为 nil")
            return
        }
        tbDebugLog("[WorkBar] present 调用，items=\(bar.defaultItemIdentifiers.count)")
        // 幂等（内部有 installed 守卫）：放在这里而不是只在 start 里做一次，
        // 是为了「启动时恰好系统还没准备好」的情况能在下一次 present 自动补上。
        installSystemTrayEntry()
        isPresented = PrivateTouchBarBridge.shared.present(touchBar: bar)
    }

    /// 监听应用切换，重新 present（幂等）。失败时静默——present 内部已做降级。
    ///
    /// - Important: 这条路径**必须无条件** `present()`，不能改成 `presentIfNeeded()`。
    ///   应用切换（⌘Tab、点 Dock、系统弹通知）会让系统把 system-modal bar 真正收掉，
    ///   但 `isPresented` 只是「上次 present 调用成功」的本地标志，系统单方面收掉 bar
    ///   时它**不会**同步变 false —— 靠它判断会出现「切回来之后 bar 再也不出现」，
    ///   而这是本工具最致命的失效（用户以为工具挂了）。多挂一次的代价只是几十微秒，
    ///   漏挂的代价是功能消失，两者不对称，所以这里唯一允许绕过守卫。
    private func observeAppActivation() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.present()
        }
    }

    /// 监听系统唤醒 / 屏幕点亮，重新挂载 bar。
    ///
    /// 休眠会收掉系统模态 bar，而 `isPresented` 是本地标志、不会同步变 false，
    /// 于是唤醒后 bar 不回来 —— 用户体感就是「过一会儿 touchbar 熄了，再也不出现」。
    private func observeSystemWake() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleSystemWake()
        }
    }

    /// 创建承载 Touch Bar 的隐藏窗口（LSUIElement app 无传统主界面，用隐藏窗口承载/保留 bar 生命周期）。
    private func setupHostingWindow() {
        let window = NSWindow(
            contentRect: NSMakeRect(0, 0, 1, 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        var behavior: NSWindow.CollectionBehavior = []
        behavior.insert(.canJoinAllSpaces)
        behavior.insert(.stationary)
        window.collectionBehavior = behavior
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        hostingWindow = window
    }
}

/// 私有 Touch Bar 常驻桥接（system-modal 路径）。
///
/// ⚠️ 风险提示：`presentSystemModalTouchBar:placement:systemTrayItemIdentifier:` 为**未公开 API**，
/// - App Store 必拒（链接/调用私有符号）；
/// - macOS 升级可能移除 / 改名 / 改签名，导致 bar 无法呈现。
///
/// 防御策略（参考 ClaudeBar 的生产验证做法）：
/// - 所有符号查找均 `guard`，缺符号 = **不显示而非崩溃**（优雅降级）；
/// - `placement: 0` 走 Control Strip 同款 system-modal 路径，使菜单栏 app 的 bar 跨 app 常驻；
/// - 通过 `dlopen` 加载 DFRFoundation 后调用 `DFRSystemModalShowsCloseBoxWhenFrontMost(false)`，
///   隐藏「前置时右上角关闭按钮」；
/// - 用 `class_getClassMethod + unsafeBitCast(IMP)` 动态调用，避免硬链接私有符号（可规避静态扫描）。
final class PrivateTouchBarBridge {
    static let shared = PrivateTouchBarBridge()

    typealias PresentFn = @convention(c) (AnyClass, Selector, NSTouchBar, Int, NSString?) -> Void
    typealias DismissFn = @convention(c) (AnyClass, Selector, NSTouchBar) -> Void

    private let presentSelector = NSSelectorFromString("presentSystemModalTouchBar:placement:systemTrayItemIdentifier:")
    private let dismissSelector = NSSelectorFromString("dismissSystemModalTouchBar:")

    private let presentFunction: PresentFn?
    private let dismissFunction: DismissFn?

    private init() {
        // 动态查找类方法（避免硬链接私有符号）。
        if let method = class_getClassMethod(NSTouchBar.self, presentSelector) {
            let imp = method_getImplementation(method)
            presentFunction = unsafeBitCast(imp, to: PresentFn.self)
        } else {
            presentFunction = nil
        }
        if let method = class_getClassMethod(NSTouchBar.self, dismissSelector) {
            let imp = method_getImplementation(method)
            dismissFunction = unsafeBitCast(imp, to: DismissFn.self)
        } else {
            dismissFunction = nil
        }

        PrivateTouchBarBridge.disableCloseBox()

        if presentFunction == nil {
            tbLog("[WorkBar] ⚠️ 未找到 presentSystemModalTouchBar，Touch Bar 常驻降级（不显示）。")
        }
    }

    /// 呈现 bar（placement: 0 = Control Strip 同款 system-modal 路径）。
    ///
    /// 每次 present 前都重新关掉「前置时显示关闭按钮」：该开关会被系统在若干时机重置，
    /// 只设一次的话，用户会在 Touch Bar 右端看到「×」，点一下就整条 bar 被 dismiss
    /// 且不会自动回来（真机实测）。
    /// - Returns: 有私有符号且调用完成返回 `true`；降级（无符号）返回 `false`。
    @discardableResult
    func present(touchBar: NSTouchBar?) -> Bool {
        guard let touchBar = touchBar, let function = presentFunction else {
            // 降级：无私有符号时不显示，也不崩溃。
            return false
        }
        PrivateTouchBarBridge.disableCloseBox()
        // 第五个参数（systemTrayItemIdentifier）：要求系统在 Control Strip 区
        // 为这个标识符常驻一个格子。系统会回来找 delegate 要 item，由
        // `TouchBarItemFactory` 的 `case "tray"` 产出 WorkBar logo。
        //
        // 用户价值：按右上角「×」把整条 bar 关掉后，这个格子仍在，点它就能重新打开
        // —— 也就是把「关闭 / 打开」交给用户自己控制（用户明确要求的行为）。
        //
        // ⚠️ 传 `nil`（旧行为）不会报错，但系统不会留格子，关掉就再也打不开。
        // 传了之后若某个 macOS 版本不认这个参数，预期最坏情况是「格子不出现、bar 照常显示」；
        // 这一条待真机回归确认（若真机上 bar 反而呈现不出来，把这里改回 nil 即可，不影响其它路径）。
        function(NSTouchBar.self, presentSelector, touchBar, 0, TouchBarItemFactory.trayIdentifier.rawValue as NSString)
        return true
    }

    /// 关闭常驻 bar。
    func dismiss(touchBar: NSTouchBar?) {
        guard let touchBar = touchBar, let function = dismissFunction else { return }
        function(NSTouchBar.self, dismissSelector, touchBar)
    }

    /// 通过 dlopen 加载 DFRFoundation，调用 `DFRSystemModalShowsCloseBoxWhenFrontMost(false)`。
    ///
    /// - Note: 使用 `RTLD_NOW | RTLD_NODELETE` 且**刻意不 dlclose**：DFRFoundation 为系统私有框架，
    ///   若引用计数归零被卸载，常驻 Touch Bar 可能随之失效且极难排查；故让框架常驻内存（代价可忽略）。
    /// - Note: 非 private：`present` 每次呈现前都要重设一次（该开关会被系统重置）。
    static func disableCloseBox() {
        guard let function = dfrFunction("DFRSystemModalShowsCloseBoxWhenFrontMost",
                                         as: SetCloseBoxFn.self) else {
            tbLog("[WorkBar] 未找到 DFRSystemModalShowsCloseBoxWhenFrontMost（降级）。")
            return
        }
        function(false)
    }

    typealias SetCloseBoxFn = @convention(c) (Bool) -> Void
    typealias SetControlStripPresenceFn = @convention(c) (NSString, Bool) -> Void

    /// DFRFoundation 句柄（进程内单例）。
    ///
    /// - Important: 只 dlopen 一次并**永不 dlclose**：见 `disableCloseBox` 的说明。
    private static let dfrHandle: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation",
        RTLD_NOW | RTLD_NODELETE
    )

    /// 从 DFRFoundation 取一个符号并转成 C 函数指针；取不到返回 nil（调用方据此降级）。
    private static func dfrFunction<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle = dfrHandle, let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: T.self)
    }

    /// 把 WorkBar logo 装进 Control Strip（Touch Bar 最右侧系统栏）并让它常驻。
    ///
    /// ## 为什么单靠 `systemTrayItemIdentifier` 参数不够
    /// 真机实测：只在 `presentSystemModalTouchBar` 里传标识符，系统**不会**来向 delegate
    /// 索要 item（`TB_DEBUG=1` 日志里完全没有 `item=tray`），Control Strip 上什么都不会出现。
    /// 这个参数的作用是「把常驻 bar 与已经注册过的 tray 格子关联起来」，
    /// 而不是「顺手帮你注册一个格子」。注册要靠下面两步 SPI
    /// （Pock / MTMR 同款组合，Stack Overflow #47988940 亦有记载）：
    /// 1. `+[NSTouchBarItem addSystemTrayItem:]` —— 把 item 放进系统托盘集合；
    /// 2. `DFRElementSetControlStripPresenceForIdentifier(id, true)` —— 声明该标识符
    ///    在 Control Strip 中**常驻**，即 bar 被 dismiss 后格子仍然在。
    ///
    /// - Returns: 两步都成功才返回 `true`；任一步缺符号返回 `false`（调用方降级，不崩）。
    @discardableResult
    static func installSystemTrayItem(_ item: NSTouchBarItem,
                                      identifier: NSTouchBarItem.Identifier) -> Bool {
        let addSelector = NSSelectorFromString("addSystemTrayItem:")
        guard let method = class_getClassMethod(NSTouchBarItem.self, addSelector) else {
            tbLog("[WorkBar] 未找到 +[NSTouchBarItem addSystemTrayItem:]，Control Strip 入口降级。")
            return false
        }
        typealias AddTrayFn = @convention(c) (AnyClass, Selector, NSTouchBarItem) -> Void
        let add = unsafeBitCast(method_getImplementation(method), to: AddTrayFn.self)
        add(NSTouchBarItem.self, addSelector, item)

        guard let presence = dfrFunction("DFRElementSetControlStripPresenceForIdentifier",
                                         as: SetControlStripPresenceFn.self) else {
            // 只加到托盘集合、没声明常驻：格子可能出现但 dismiss 后消失。
            // 仍然返回 true —— 用户至少还有一次点击机会，比完全没有入口好。
            tbLog("[WorkBar] 未找到 DFRElementSetControlStripPresenceForIdentifier，格子可能不常驻。")
            return true
        }
        presence(identifier.rawValue as NSString, true)
        tbLog("[WorkBar] Control Strip 入口已安装（identifier=\(identifier.rawValue)）")
        return true
    }

    /// 收回 Control Strip 的常驻声明（退出时用）。
    static func setControlStripPresence(for identifier: NSTouchBarItem.Identifier, present: Bool) {
        guard let function = dfrFunction("DFRElementSetControlStripPresenceForIdentifier",
                                         as: SetControlStripPresenceFn.self) else { return }
        function(identifier.rawValue as NSString, present)
    }
}

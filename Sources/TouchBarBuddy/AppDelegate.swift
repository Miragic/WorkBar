import AppKit
import ApplicationServices
import ServiceManagement

/// 依赖组装（Composition Root）+ 应用生命周期管理。
///
/// 本工具为菜单栏型 app（`LSUIElement`，不占 Dock、不成为前台），因此：
/// - 不创建可见主窗口，Touch Bar 由 `TouchBarController` 通过私有 API 常驻呈现；
/// - 提供状态栏菜单（打开 WorkBuddy / 退出），便于用户操作与退出。
public final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var touchBarController: TouchBarController?
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    /// 设置面板（懒加载：没打开过就不占内存）。
    private var settingsWindowController: SettingsWindowController?

    /// 首次启动是否已自动弹过一次授权提示（避免每次启动都打扰）。
    private static let didPromptAXKey = "didPromptAccessibilityOnce"

    /// 上一次「开机自启」切换失败的原始错误文案（成功时清空）。
    ///
    /// - Important: 必须把错误**显示出来**。`SMAppService.register()` 常见的失败原因
    ///   （app 不在 /Applications、被系统策略拦、用户拒绝）在界面上都表现为「勾了又没勾上」，
    ///   静默失败会让用户以为功能坏了却无从判断。所以菜单项标题直接带错误信息。
    private var launchAtLoginError: String?

    public override init() {
        super.init()
    }

    // MARK: - NSApplicationDelegate

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // 单实例检查必须是**第一步**，早于 Touch Bar 安装、轮询启动、菜单创建。
        //
        // 为什么顺序不能动：若两个实例都先各自 `controller.start()`（内部会 present
        // system-modal bar），系统会先显示 A 的 bar、再被 B 的顶掉，然后 A 退出 ——
        // 用户会看到 Touch Bar 明显闪一下，而且在闪的过程中点按可能打到正在退出的进程上。
        // 先判重再初始化，就只有一个实例会碰到 Touch Bar。
        if terminateIfAnotherInstanceIsRunning() { return }

        // 依赖装配（替换真实/模拟数据源只需改这一行）。
        let provider: BuddyStateProvider = WorkBuddyProvider()
        let voice = VoiceRecognizer()
        let controller = TouchBarController(provider: provider, voice: voice)
        controller.onActivateWorkBuddy = { [weak self] in
            self?.activateWorkBuddy()
        }
        touchBarController = controller
        controller.start()

        // - Note: 曾经在这里「启动后按压账号弹窗读一次余额」，已移除。
        //   按压弹窗会在用户眼前弹出面板并抢焦点，属于割裂体验；余额也不再从 UI 里抠。
        //   空闲态只展示本地数据库能直接算出的「今日完成 / 今日消耗」。

        setupStatusItem()
        // 启动即写一行日志：既确认「日志落盘是否可用」，也让日志文件在排查前就存在。
        tbLog("[WorkBar] 启动完成。日志：\(TBLogFile.shared.path ?? "仅 stderr")")
        // 启动即记录一次授权状态：排查「语音识别成功但文字没进输入框」时，
        // 这一行能直接把「TCC 授权是否真的对当前构建生效」摆出来，不必靠猜。
        // - Note: 系统设置里开关显示为「开」**不代表**当前构建被授权 ——
        //   若那条 TCC 记录绑定的是旧构建的 cdhash（曾经用未生效的自签证书授权过），
        //   重编后 cdhash 变化，记录失效但那一行仍显示为开；此处以 API 返回值为准。
        tbLog("[WorkBar] 辅助功能授权=\(AXIsProcessTrusted() ? "已授权" : "未授权")")
        // 记录实际使用的数据库路径：排查「改了数据但界面没变」时，第一个要确认的
        // 就是 app 到底在读哪个库。`TOUCHBARBUDDY_DB_PATH` 是环境变量覆盖，
        // 一旦通过 `open --env` / 脚本误传，界面会安静地读另一个库，没有任何报错。
        tbLog("[WorkBar] 数据源=\(WorkBuddyProvider.defaultDBPath)")
        promptAccessibilityOnFirstLaunchIfNeeded()
        runInjectSmokeCheckIfRequested()
        runDialogPressIfRequested()
        runOpenSettingsIfRequested()
    }

    /// 设置面板冒烟钩子（`TB_OPEN_SETTINGS=1`）。
    ///
    /// 为什么需要它：设置面板是纯手工 UI，自动化测试碰不到它的排版 ——
    /// 而「文案换行后行距算错、说明文字被下一行压住」这类问题只有真机才看得见。
    /// 有了这个钩子就能在无人值守下把窗口摆到屏幕上再截图核对。
    /// 不设该变量时本方法什么都不做。
    private func runOpenSettingsIfRequested() {
        guard ProcessInfo.processInfo.environment["TB_OPEN_SETTINGS"] == "1" else { return }
        tbLog("[TB] TB_OPEN_SETTINGS 已开启：1s 后打开设置面板")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.menuOpenSettings()
        }
    }

    /// 弹层点选冒烟钩子（`TB_DIALOG_PRESS="关闭"`）。
    ///
    /// 为什么需要它：Touch Bar 上的按钮没法自动化点，但「检测 → 找到元素 → AXPress」
    /// 这条链路可以。启动后延迟（默认 2 秒，可用 `TB_DIALOG_PRESS_DELAY` 调大）在主线程走一次
    /// `pressDialogOption`，用于无人值守地验证按压链路。点的是**弹层按钮**，
    /// 不往任何输入框写文本（与 `TB_INJECT_SMOKE` 的本质区别）。不设该变量时本方法什么都不做。
    private func runDialogPressIfRequested() {
        guard let label = ProcessInfo.processInfo.environment["TB_DIALOG_PRESS"],
              !label.isEmpty else { return }
        // 弹层是异步渲染的（真机实测：先 `加载中...`，约 3~5 秒后按钮才进树），
        // 默认 2 秒够点「已经开着的弹层」，配合 TB_AX_PRESS 现场开弹层时需要调到 6~8 秒。
        let rawDelay = ProcessInfo.processInfo.environment["TB_DIALOG_PRESS_DELAY"] ?? ""
        let delay = max(0.0, Double(rawDelay) ?? 2.0)
        tbLog("[TB] TB_DIALOG_PRESS 已开启：\(delay)s 后尝试按压弹层选项「\(label)」")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.touchBarController?.pressDialogOption(label)
        }
    }

    /// 注入路径冒烟自检（`TB_INJECT_SMOKE="要粘的文字"`）。
    ///
    /// 语音识别必须有人说话，自动化验证做不到；所以这里提供一条**与环境变量门控**的
    /// 替代路径，直接跑一遍「激活 → 等前台 → 聚焦输入框 → 剪贴板 + ⌘V」，
    /// 用于验证注入链路在真实 app 里能跑通、不崩、失败时有明确 reason。
    /// 不设该变量时本方法什么都不做。
    private func runInjectSmokeCheckIfRequested() {
        guard let text = ProcessInfo.processInfo.environment["TB_INJECT_SMOKE"],
              !text.isEmpty else { return }
        // 可指定目标 app（默认 WorkBuddy）。排障时指向 TextEdit 之类的草稿 app，
        // 就能在不污染用户真实聊天输入框的前提下验证「粘贴机制本身是否有效」。
        let target = ProcessInfo.processInfo.environment["TB_INJECT_SMOKE_BUNDLE"]
            ?? AppActivation.workBuddyBundleID
        tbLog("[TB] TB_INJECT_SMOKE 已开启：0.5s 后向 \(target) 执行一次注入冒烟自检")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            // insert 是阻塞的，放后台跑，别拦住启动。
            DispatchQueue.global(qos: .userInitiated).async {
                let result = TextInjector.insert(text, bundleID: target)
                tbLog("[TB] 注入冒烟自检：ok=\(result.ok) reason=\(result.reason ?? "nil")")
            }
        }
    }


    public func applicationWillTerminate(_ notification: Notification) {
        touchBarController?.stop()
    }

    // MARK: - 状态栏菜单

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // 菜单栏用模板图：系统按明暗模式自动着色（isTemplate 只取 alpha 通道）。
        // 语义同 Dock 图标 A「凝视」——一条带双眼的 Touch Bar。
        if let icon = NSImage(named: "MenuBarIcon") {
            icon.isTemplate = true
            item.button?.image = icon
            item.button?.toolTip = "WorkBar · ⌘TB"
            item.button?.setAccessibilityLabel("WorkBar")
        } else {
            // 兜底：资源缺失时退回原文字，避免菜单栏出现空白项
            item.button?.title = "⌘TB"
        }

        let menu = NSMenu()
        // 每次展开时重建菜单项，保证「授权状态」实时准确（授权后不必重启 app）。
        menu.delegate = self
        item.menu = menu

        statusItem = item
        statusMenu = menu
        rebuildStatusMenu()
    }

    // MARK: - NSMenuDelegate

    public func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusMenu else { return }
        rebuildStatusMenu()
    }

    /// 重建状态栏菜单项。
    private func rebuildStatusMenu() {
        guard let menu = statusMenu else { return }
        menu.removeAllItems()

        // 辅助功能授权状态：
        // - 语音注入依赖「剪贴板 + ⌘V」，未授权会静默失败；
        // - 弹层选项检测（需求 ③）也走同一套 AX 遍历。
        // 两件事都依赖同一项授权，故在菜单置顶提示并引导。
        // - Note: 菜单里已**不再**有任何「刷新积分余额 / 刷新成长状态」入口：
        //   那两条都要按压 WorkBuddy 弹窗、抢用户焦点，属于割裂体验，已整体移除。
        if AXIsProcessTrusted() {
            let grantedItem = NSMenuItem(title: "✅ 辅助功能已授权",
                                         action: nil,
                                         keyEquivalent: "")
            grantedItem.isEnabled = false
            menu.addItem(grantedItem)
        } else {
            let warnItem = NSMenuItem(title: "⚠️ 点此授权辅助功能（弹层选项 / 语音填入）",
                                      action: #selector(menuRequestAccessibility),
                                      keyEquivalent: "")
            warnItem.target = self
            menu.addItem(warnItem)
        }
        menu.addItem(NSMenuItem.separator())

        let openItem = NSMenuItem(title: "打开 WorkBuddy",
                                  action: #selector(menuOpenWorkBuddy),
                                  keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        // 重新挂载 Touch Bar：这是「用 × 关掉 bar 之后」的兜底入口。
        // Control Strip 里的 logo 才是主入口，但它走私有 API（`systemTrayItemIdentifier`），
        // 不同 macOS 版本是否保留那个格子并不保证。菜单项走的是纯公开 API + 自有对象，
        // 一定能用 —— 两个入口同时存在，才不会出现「关掉之后彻底打不开」的死局。
        let remountItem = NSMenuItem(title: "重新挂载 Touch Bar",
                                     action: #selector(menuRemountTouchBar),
                                     keyEquivalent: "")
        remountItem.target = self
        menu.addItem(remountItem)

        // 开机自启：macOS 13+ 用 SMAppService 官方接口（不再手写 LaunchAgent plist，
        // 那条路要自己管文件落盘、权限、卸载，且在「登录项」里显示为未知项目）。
        // 低版本系统上整项不显示：本工具实际只跑在 macOS 14+，但别让编译期出现可用性告警。
        if #available(macOS 13.0, *) {
            menu.addItem(makeLaunchAtLoginItem())
        }

        let settingsItem = NSMenuItem(title: "设置",
                                      action: #selector(menuOpenSettings),
                                      keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "退出 WorkBar",
                                  action: #selector(menuQuit),
                                  keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc private func menuOpenWorkBuddy() {
        activateWorkBuddy()
    }

    /// 重新挂载 Touch Bar（用户用 × 关掉 bar 之后的手动恢复入口）。
    @objc private func menuRemountTouchBar() {
        tbLog("[WorkBar] 菜单：重新挂载 Touch Bar")
        touchBarController?.remount()
    }

    /// 打开设置面板。首次使用时创建，之后复用同一个窗口（避免反复开窗）。
    @objc private func menuOpenSettings() {
        if settingsWindowController == nil {
            let controller = SettingsWindowController()
            // 开关一变立即重建 Touch Bar：用户拖完开关就能看到结果，
            // 不必等 3 秒轮询，也不会出现「开关关了但 bar 还是极简」的错位感。
            controller.onSettingsChanged = { [weak self] in
                self?.touchBarController?.applySettingsChange()
            }
            settingsWindowController = controller
        }
        settingsWindowController?.show()
    }

    // MARK: - 开机自启（SMAppService）

    /// 「开机自启」菜单项标题里允许留给错误文案的字数。
    ///
    /// 为什么是 20：菜单宽度有限，系统错误文案（英文）动辄 80+ 字符，
    /// 整句塞进去会让菜单项宽到超出屏幕；截断后仍能看出「是权限 / 是路径 / 是策略」。
    private static let launchErrorLimit = 20

    /// 构造「开机自启」菜单项。
    ///
    /// 三种状态三种标题：
    /// - `status == .enabled` → `✓ 开机自启`
    /// - 有未清除的错误 → `⚠️ 开机自启失败：<错误>`（保持未勾选，且**仍可点**以便重试）
    /// - 其它（未注册 / 待用户批准）→ `开机自启`
    @available(macOS 13.0, *)
    private func makeLaunchAtLoginItem() -> NSMenuItem {
        let enabled = SMAppService.mainApp.status == .enabled
        let title: String
        if let error = launchAtLoginError {
            title = "⚠️ 开机自启失败：" + Self.truncate(error, limit: Self.launchErrorLimit)
        } else if enabled {
            title = "✓ 开机自启"
        } else {
            title = "开机自启"
        }
        let item = NSMenuItem(title: title,
                              action: #selector(menuToggleLaunchAtLogin),
                              keyEquivalent: "")
        item.target = self
        // 标题已经带 ✓，这里不再设 `item.state = .on`：两个勾并排出现像 bug，
        // 而 `state` 的勾在左、标题的 ✓ 在右，视觉上会读成两件事。
        return item
    }

    /// 切换开机自启；失败时把错误留在 `launchAtLoginError` 里，由标题显示。
    @available(macOS 13.0, *)
    @objc private func menuToggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
                tbLog("[WorkBar] 开机自启已关闭（status=\(service.status.rawValue)）")
            } else if service.status == .requiresApproval {
                // 已经注册过但用户在「登录项」里关掉了（或被系统挂起等批准）。
                // 此时 `register()` 不会让开关变绿，只能把用户送到设置页 —— 直接说清楚，
                // 别让用户反复点这一项却什么都没发生。
                tbLog("[WorkBar] 开机自启待系统批准，跳转登录项设置")
                openLoginItemsSettingsPane()
            } else {
                try service.register()
                tbLog("[WorkBar] 开机自启已开启（status=\(service.status.rawValue)）")
            }
            launchAtLoginError = nil
        } catch {
            // 常见原因：app 不在 /Applications、可执行体签名不完整、系统策略拒绝。
            launchAtLoginError = error.localizedDescription
            tbLog("[WorkBar] 开机自启切换失败：\(error.localizedDescription)")
        }
        // 菜单项标题要立刻反映结果，不依赖下次展开（展开时 `menuNeedsUpdate` 也会刷）。
        rebuildStatusMenu()
    }

    /// 打开「系统设置 → 通用 → 登录项」。
    private func openLoginItemsSettingsPane() {
        let urlString = "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    /// 截断到 `limit` 个字符（含省略号本身），并去掉首尾空白。
    ///
    /// - Note: 用 `count` 而不是 `utf8.count`：菜单标题按「字」显示，
    ///   按字节截会把中文切成半个字（乱码方块）。
    private static func truncate(_ text: String, limit: Int) -> String {
        let cleaned = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        guard cleaned.count > limit else { return cleaned }
        return String(cleaned.prefix(max(1, limit - 1))) + "…"
    }

    // MARK: - 辅助功能授权

    /// 触发系统授权流程。
    ///
    /// 关键点：`AXIsProcessTrustedWithOptions(kAXTrustedCheckOptionPrompt: true)` 会让
    /// **系统主动把本 app 登记进「辅助功能」列表**（未勾选状态），并弹出引导窗口。
    /// 用户随后只需在列表里拨一下开关，不必再去「+」的文件对话框里手动挑 .app ——
    /// 那一步对用户来说太容易走错（选到别处的旧构建产物就会授权到另一个 cdhash 上）。
    @objc private func menuRequestAccessibility() {
        requestAccessibilityTrust()
        openAccessibilitySettingsPane()
    }

    /// 首次启动（且未授权时）自动弹一次提示；之后不再打扰，用户可随时从菜单触发。
    private func promptAccessibilityOnFirstLaunchIfNeeded() {
        guard !AXIsProcessTrusted() else { return }
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.didPromptAXKey) else { return }
        defaults.set(true, forKey: Self.didPromptAXKey)
        requestAccessibilityTrust()
    }

    /// 请求辅助功能授权（同时把 app 登记到系统设置列表）。
    private func requestAccessibilityTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// 打开「系统设置 → 隐私与安全性 → 辅助功能」。
    private func openAccessibilitySettingsPane() {
        let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func menuQuit() {
        NSApp.terminate(nil)
    }

    // MARK: - 激活 WorkBuddy

    /// 激活 WorkBuddy 主窗口（MVP：提示 + 一键跳转，不做 CGEvent 按钮点击）。
    private func activateWorkBuddy() {
        // 统一走 `AppActivation`：语音录音前、文字注入前都用同一份实现，
        // 避免「这里加了 .activateIgnoringOtherApps，那里没加」导致的静默失效。
        AppActivation.activate()
    }

    // MARK: - 单实例

    /// 若已有另一个本 app 实例在跑：把它激活，然后结束本次启动。
    ///
    /// - Returns: 已存在其它实例（本次启动应直接放弃）为 `true`。
    ///
    /// 为什么需要：本工具是 `LSUIElement`，用户很容易通过「登录项 + 双击图标」启动两次。
    /// 两个实例会各自持有一条 system-modal Touch Bar：它们互相顶掉，
    /// 表现为 Touch Bar 时有时无、点按钮没反应（点到的是正在退出那个进程的 item），
    /// 而且日志里会出现互相交错的 `present 调用`。**必须**保证只有一个实例。
    ///
    /// - Note: 用 `runningApplications(withBundleIdentifier:)` 而不是「打开一个锁文件」：
    ///   前者能直接拿到对方的 `NSRunningApplication` 以便激活（用户点图标时期望的是
    ///   「打开它」，不是「什么都没发生」），也不用管锁文件残留 / 崩溃后锁没释放。
    /// - Note: 不能靠 `activate` 的返回值判断成败 —— 对 `LSUIElement` app，
    ///   系统可能不给它前台（没有窗口可显示），但实例确实还在，此时仍然应该退出自己。
    private func terminateIfAnotherInstanceIsRunning() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != selfPID }
        guard let existing = others.first else { return false }

        tbLog("[WorkBar] 已有实例在运行（pid=\(existing.processIdentifier)），"
               + "激活它并退出本次启动（pid=\(selfPID)）")
        AppActivation.activate(existing)
        // `terminate` 会走正常的 applicationWillTerminate，但此刻 controller 还没建，
        // 所以不会有任何 Touch Bar 被安装 —— 这正是把单实例检查放最前面的收益。
        NSApp.terminate(nil)
        return true
    }
}

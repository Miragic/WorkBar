import AppKit
import Foundation

/// WorkBuddy 进程查找 + 激活的共用实现。
///
/// 抽成独立类型的原因：这套逻辑有三个调用方（菜单项「打开 WorkBuddy」、
/// 语音录音前激活、文字注入前激活），复制三份必然漂移 —— 比如只有一处加了
/// `.activateIgnoringOtherApps`，另外两处在别的 app 抢焦点时就会静默失效。
///
/// - Note: 本工具是 `LSUIElement`（不占 Dock、不成为前台），所以这里的「激活」
///   永远是把**别的** app 提到前台，自身不会抢焦点。
enum AppActivation {

    /// WorkBuddy 的 bundle identifier。
    static let workBuddyBundleID = "com.tencent.workbuddy.mac"

    /// 等待前台切换的轮询间隔（秒）。
    static let pollInterval: TimeInterval = 0.05

    /// 等待前台切换的超时（秒）。
    static let waitTimeout: TimeInterval = 1.5

    /// 找到正在运行的 WorkBuddy 实例；未运行返回 nil。
    ///
    /// - Parameter bundleID: 目标 app，默认 WorkBuddy（单测/排障可替换）。
    static func runningApplication(bundleID: String = workBuddyBundleID) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    /// 把目标 app 提到前台。
    ///
    /// - Parameter bundleID: 目标 app，默认 WorkBuddy。
    /// - Returns: 进程存在且已发出激活请求为 `true`；进程不存在为 `false`（并打日志）。
    /// - Note: `activate` 是**异步**的 —— 返回 true 只代表请求已发出，
    ///   真正成为前台要配合 `waitUntilFrontmost(bundleID:)` 确认。
    @discardableResult
    static func activate(bundleID: String = workBuddyBundleID) -> Bool {
        guard let app = runningApplication(bundleID: bundleID) else {
            tbLog("[WorkBar] \(bundleID) 未在运行，无法激活。")
            return false
        }
        activate(app)
        return true
    }

    /// 把某个已取到的实例提到前台。
    ///
    /// - Parameter app: 已运行的实例（可以是 WorkBuddy，也可以是「另一个自己」——单实例检查要用）。
    /// - Note: 抽出来的原因：单实例逻辑（`AppDelegate`）也要激活一个 `NSRunningApplication`，
    ///   若在那里重写一遍版本分支，就又回到本文件要解决的「两处各写一份、迟早漂移」问题。
    static func activate(_ app: NSRunningApplication) {
        // `activateIgnoringOtherApps` 在 macOS 14 起已被废弃且**不再有任何效果**
        // （系统自己决定是否让出前台）。为了让编译期没有废弃警告、同时又不丢老系统上的行为，
        // 这里按可用性分支：新系统走默认激活 + 由 `waitUntilFrontmost` 事实验证。
        if #available(macOS 14.0, *) {
            app.activate(options: [])
        } else {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }

    /// 轮询等待目标 app 成为前台应用。
    ///
    /// 为什么必须等：`activate` 发出后系统还要切 Space / 处理焦点，
    /// 立刻发 ⌘V 的话事件会落到**切换前**的前台 app 上（就是「粘错地方」那个 bug）。
    ///
    /// - Parameters:
    ///   - bundleID: 目标 app，默认 WorkBuddy。
    ///   - timeout: 最长等待时间（秒）。
    /// - Returns: 超时前已成为前台返回 `true`。
    static func waitUntilFrontmost(bundleID: String = workBuddyBundleID,
                                   timeout: TimeInterval = waitTimeout) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isFrontmost(bundleID: bundleID) { return true }
            waitStep()
        }
        return isFrontmost(bundleID: bundleID)
    }

    /// 目标 app 当前是否前台。
    static func isFrontmost(bundleID: String = workBuddyBundleID) -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID
    }

    /// 当前前台 app 的可读名（仅用于日志/错误文案）。
    static func frontmostName() -> String {
        NSWorkspace.shared.frontmostApplication?.localizedName ?? "未知应用"
    }

    /// 等待一个轮询间隔。
    ///
    /// 主线程上不能 `Thread.sleep`（会冻住 Touch Bar 与菜单），改成泵一会儿 RunLoop；
    /// 但 `run(mode:before:)` 在没有输入源时会立即返回，所以补一次「睡足剩余时间」，
    /// 避免热循环把 1.5s 空转成上万次 AX/Workspace 查询。
    private static func waitStep() {
        guard Thread.isMainThread else {
            Thread.sleep(forTimeInterval: pollInterval)
            return
        }
        let start = Date()
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(pollInterval))
        let spent = Date().timeIntervalSince(start)
        if spent < pollInterval {
            Thread.sleep(forTimeInterval: pollInterval - spent)
        }
    }
}

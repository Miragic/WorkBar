import AppKit
import Foundation

/// 「任务运行时常驻」的看护器：低频重新挂载系统模态 bar。
///
/// ## 为什么不是阻止屏幕休眠
/// 一开始的判断是「Touch Bar 跟随屏幕休眠」，用户实测否定了这个假设：
/// **屏幕还亮着，Touch Bar 自己就熄了**。原因是系统会把长时间无交互的
/// 「系统模态 Touch Bar」回收掉（`presentSystemModalTouchBar` 呈现的 bar 并非永久占用）。
/// 所以正确做法不是拦系统休眠（那会让屏幕也不熄，代价过大且解决不了问题），
/// 而是**低频补挂**：发现该常驻时，每隔一段时间重新 present 一次。
///
/// ## 频率取舍
/// 间隔太短会打断用户（每次 present 都是一次系统合成，可能闪一下）；
/// 太长则熄掉后要等很久才回来。取 20s：体感上「几乎不会真熄」，
/// 又远低于人眼能察觉的「周期性刷新」阈值（3s 级才会被用户点名，之前踩过）。
///
/// - Note: 只在「设置开启 **且** 有任务在跑」时运行。空闲时补挂毫无意义还费电。
final class KeepAwakeService {

    /// 补挂间隔（秒）。`TB_KEEP_AWAKE_INTERVAL` 可覆盖，便于真机调参而不必改代码。
    static let defaultInterval: TimeInterval = 20

    private var timer: Timer?
    private(set) var isRunning = false
    /// 已补挂次数（仅用于日志，便于判断「到底有没有在熄」）。
    private var refreshCount = 0

    deinit {
        stop()
    }

    /// 按策略启停。
    ///
    /// - Parameters:
    ///   - shouldHold: 是否应该保持常驻。
    ///   - onRefresh: 每次到点要执行的补挂动作（由控制器传入 `present()`）。
    /// - Note: 幂等：目标状态与当前一致时什么都不做，避免每次 refresh 都重建定时器。
    func update(shouldHold: Bool, onRefresh: @escaping () -> Void) {
        if shouldHold, !isRunning {
            start(onRefresh)
        } else if !shouldHold, isRunning {
            stop()
        }
    }

    private func start(_ onRefresh: @escaping () -> Void) {
        let raw = ProcessInfo.processInfo.environment["TB_KEEP_AWAKE_INTERVAL"]
        let interval = raw.flatMap(Double.init).map { max(5, $0) } ?? Self.defaultInterval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.refreshCount += 1
            // 关键诊断：补挂时**屏幕到底睡没睡**。
            // 这决定了「Touch Bar 熄」是屏幕休眠导致，还是系统单独回收了系统模态 bar ——
            // 两者的解法完全不同：前者只能阻止屏幕休眠，后者靠补挂。
            // 不再靠猜：让日志自己说话。
            let displayAsleep = CGDisplayIsAsleep(CGMainDisplayID())
            // 补挂是每 20s 一次的例行动作，用 debug 级：默认日志里只留「开启/停止」两条，
            // 免得把真正需要看的错误刷掉。排查「到底熄没熄」时开 TB_DEBUG 即可。
            tbDebugLog("[TB] 常驻补挂第 \(self.refreshCount) 次（间隔 \(Int(interval))s，"
                       + "displayAsleep=\(displayAsleep)）")
            onRefresh()
        }
        // `.common`：菜单打开 / 拖拽等事件跟踪模式下也要继续走，
        // 否则「长时间无操作」恰好就是系统进入事件跟踪态，定时器反而停摆。
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        isRunning = true
        refreshCount = 0
        tbLog("[TB] 常驻已开启：每 \(Int(interval))s 补挂一次，避免系统回收 bar")
    }

    private func stop() {
        guard isRunning else { return }
        timer?.invalidate()
        timer = nil
        isRunning = false
        tbLog("[TB] 常驻已停止：任务结束或设置关闭（期间共补挂 \(refreshCount) 次）")
    }
}

/// 「何时该保持常驻」的纯策略，便于单测。
enum KeepAwakePolicy {

    /// - Parameters:
    ///   - enabled: 用户是否在设置里开启了常驻。
    ///   - hasActiveTasks: 当前是否有进行中的任务（working / active）。
    /// - Returns: 是否应启动补挂定时器。
    /// - Note: 两个条件缺一不可 —— 只在开关打开时全程补挂会白白耗电；
    ///   只在有任务时补挂但不看开关，等于无视用户选择。
    static func shouldHold(enabled: Bool, hasActiveTasks: Bool) -> Bool {
        enabled && hasActiveTasks
    }
}

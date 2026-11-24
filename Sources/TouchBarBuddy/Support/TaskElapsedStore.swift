import Foundation

/// 记录「某个任务本次是从什么时候开始跑的」。
///
/// ## 为什么不能只放在内存里
/// 之前起点存在 controller 的 `runningSince` 字典里，App 一重启就清空 ——
/// 用户看到时间又从 0 开始累加，反馈「又回到了上个版本」。
/// 数据库没有「本次运行起点」字段（`sessions.created_at` 是会话行的创建时间，
/// 当前会话从 11-12 创建，拿它算会得到 173h，不是用户要的「本次任务」），
/// 所以由本工具第一次看见该任务进入进行中时记下，并**持久化到 UserDefaults**。
///
/// ## 为什么不因状态切换而清掉
/// 任务会短暂进入待确认 / 选择态，也会因为轮询抖动从列表里消失一瞬。
/// 那些都不是「任务结束」。只有明确看到任务变成 completed / archived 才清起点。
final class TaskElapsedStore {

    private let keyPrefix = "tb.runStart."
    /// nil = 纯内存模式（单测用），避免测试污染真实 UserDefaults。
    private let defaults: UserDefaults?
    /// 内存镜像：读写都比每次访问 UserDefaults 快，且作为未落盘成功时的兜底。
    private var memory: [String: Date] = [:]

    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
    }

    /// 取（没有就记下 `now` 并持久化）该任务的起点。
    ///
    /// - Important: 一旦记下就不再改。后续每次轮询都返回**同一个** Date，
    ///   所以时长只增不减；有输出、切状态、重启 App 都不会让它归零。
    func start(for id: String, now: Date = Date()) -> Date {
        let key = keyPrefix + id
        if let saved = defaults?.object(forKey: key) as? Date { return saved }
        if let cached = memory[id] { return cached }
        memory[id] = now
        defaults?.set(now, forKey: key)
        return now
    }

    /// 只读取已有起点，**不创建**。用于「此刻没有起点就别显示时长」的场景。
    func startedDate(for id: String) -> Date? {
        if let saved = defaults?.object(forKey: keyPrefix + id) as? Date { return saved }
        return memory[id]
    }

    /// 只在任务真正结束时调用，清掉起点，下次同名任务重新计时。
    func clear(_ id: String) {
        memory.removeValue(forKey: id)
        defaults?.removeObject(forKey: keyPrefix + id)
    }
}

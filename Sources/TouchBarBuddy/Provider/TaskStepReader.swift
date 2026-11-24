import Foundation

/// 某个会话的待办步骤快照。
///
/// ## 数据从哪来
/// `~/.workbuddy/tasks/<session_id>/<n>.json`，每个文件是一条待办：
/// ```json
/// {"subject":"核实博主粉丝数","description":"…","activeForm":"…",
///  "status":"completed|in_progress|pending","id":"1",
///  "createdAt":1793757850188,"updatedAt":1793758141728}
/// ```
/// 目录名**就是** `sessions.id`，因此不需要任何映射表就能对上。
///
/// ## 为什么不用 AX 读对话正文
/// 真机探针实测：AX 能读到助手消息（603 节点 / 0.12 秒），但**判断不了哪条最新** ——
/// 对话是虚拟化的，用户在滚动后「最下面那条」并不是最新回复。
/// 显示错的中间结果比不显示更糟，所以改用这份自带 `status` 与时间戳的步骤清单。
/// 代价：只有用过待办清单的会话才有（实测 16/54），没有的会话这一格自然不显示。
struct TaskStepProgress: Equatable {
    /// 步骤总数。
    let total: Int
    /// 已完成步骤数。
    let done: Int
    /// 当前正在做的步骤名（`status == "in_progress"`）；没有则 nil。
    let current: String?
}

/// 步骤文案的格式化与裁剪规则（纯函数，便于单测）。
enum TaskStep {

    /// 少于这个步数就不显示进度。
    ///
    /// 只有 1 步时「1/1」既不是进度也不提供信息，纯属占宽度。
    static let minimumTotal = 2

    /// 当前步骤名最多显示几个字。
    ///
    /// 实测 subject 中位 16 字、p90 24 字、最长 40 字；8pt 下 24 个汉字约 192pt，
    /// 而整条第二行只有 196pt —— 必须裁。取 8 字（约 64pt）才能和
    /// 「状态 + 3/8 + 上下文 + 时长」一起放下。
    static let maxSubjectLength = 8

    /// 进度与当前步骤的组合文案：`"3/8 核实粉丝数"`。
    ///
    /// - 没有当前步骤（全部完成 / 都还没开始）时只返回 `"3/8"`。
    /// - `total < minimumTotal` 或非法值返回 nil（整段省略，不显示占位符）。
    static func segmentText(_ progress: TaskStepProgress?) -> String? {
        guard let progress = progress, progress.total >= minimumTotal else { return nil }
        let done = min(max(progress.done, 0), progress.total)
        let head = "\(done)/\(progress.total)"
        guard let current = progress.current.map(normalize), !current.isEmpty else {
            return head
        }
        return head + " " + truncate(current)
    }

    /// 进度比例（0...1），与 `segmentText` 用同一套有效性判据。
    ///
    /// - Note: `TaskMetaSegment` 用它决定进度条画多少；文案仍只由 `segmentText` 给出，
    ///   两者不会一个显示、另一个不显示。
    static func progress(_ progress: TaskStepProgress?) -> Double? {
        guard let progress = progress, progress.total >= minimumTotal else { return nil }
        let done = min(max(progress.done, 0), progress.total)
        return Double(done) / Double(progress.total)
    }

    /// 把步骤名裁到 `maxSubjectLength` 个字，超出补 `…`。
    ///
    /// - Note: 裁出来的是 `8 字 + …`，比硬留 8 个字多占一个字宽。
    ///   这是刻意的：没有省略号会被误读成「这个名字就这么长」。
    static func truncate(_ subject: String) -> String {
        guard subject.count > maxSubjectLength else { return subject }
        return String(subject.prefix(maxSubjectLength)) + "…"
    }

    /// 去掉换行与首尾空白：步骤名里混进换行会把单行 label 撑高或显示成空白。
    private static func normalize(_ subject: String) -> String {
        subject
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 读取并缓存「会话 → 待办步骤」。
///
/// ## 为什么要缓存
/// 轮询是 3 秒一次，而单个会话最多有 37 个步骤文件（实测）。每次都重新读 + 解析 JSON
/// 会产生大量无谓 I/O。这里用「文件名 + 修改时间 + 大小」拼成签名：
/// 签名没变就直接返回上次的结果，文件真变了才重新解析。
/// - Note: 不能用目录 mtime 当签名 —— **修改已有文件不会更新父目录的 mtime**，
///   那样会在「某一步从进行中变成已完成」时恰好读到旧值。
final class TaskStepReader {

    /// 步骤文件根目录（`~/.workbuddy/tasks`）。
    ///
    /// 支持 `TB_TASK_STEPS_ROOT` 覆盖，用途与数据库的 `TOUCHBARBUDDY_DB_PATH` 相同：
    /// 真机的待办清单需要用户实际用起来才会产生，造一份副本来验证显示效果最省事，
    /// 也避免往 WorkBuddy 的真实数据目录里塞测试文件。
    static var defaultRoot: String {
        if let override = ProcessInfo.processInfo.environment["TB_TASK_STEPS_ROOT"],
           !override.isEmpty {
            return override
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".workbuddy/tasks")
    }

    private let root: String
    private var cache: [String: (signature: String, progress: TaskStepProgress?)] = [:]
    private let lock = NSLock()

    init(root: String = TaskStepReader.defaultRoot) {
        self.root = root
    }

    /// 读取某会话的步骤进度；没有目录 / 没有合法步骤文件时返回 nil。
    func progress(forSessionID sessionID: String) -> TaskStepProgress? {
        // 目录名直接拼进路径，必须先挡掉路径分隔符，避免 `../` 之类跑到别处。
        guard !sessionID.isEmpty, !sessionID.contains("/"), !sessionID.contains("..") else {
            return nil
        }
        let dir = (root as NSString).appendingPathComponent(sessionID)

        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
            return nil
        }
        // 只认 `<数字>.json`：目录里可能混入别的文件，按数字排序才能保证 n=10 排在 n=9 之后。
        let files = names.compactMap { name -> (order: Int, path: String, name: String)? in
            guard name.hasSuffix(".json") else { return nil }
            let stem = String(name.dropLast(".json".count))
            guard let order = Int(stem) else { return nil }
            return (order, (dir as NSString).appendingPathComponent(name), name)
        }.sorted { $0.order < $1.order }

        guard !files.isEmpty else { return nil }

        var signatureParts: [String] = []
        for file in files {
            let attrs = try? FileManager.default.attributesOfItem(atPath: file.path)
            let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
            signatureParts.append("\(file.name)|\(mtime)|\(size)")
        }
        let signature = signatureParts.joined(separator: ";")

        lock.lock()
        if let hit = cache[sessionID], hit.signature == signature {
            lock.unlock()
            return hit.progress
        }
        lock.unlock()

        let progress = parse(files.map(\.path))

        lock.lock()
        cache[sessionID] = (signature, progress)
        lock.unlock()
        return progress
    }

    // MARK: - 解析

    private func parse(_ paths: [String]) -> TaskStepProgress? {
        var done = 0
        var current: String?
        var currentStamp = Int.min
        var total = 0

        for path in paths {
            guard let data = FileManager.default.contents(atPath: path),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rawSubject = object["subject"] as? String else {
                // 文件可能正在被写入（读到半截），跳过即可 —— 下一轮签名会变、自然重读。
                continue
            }
            let subject = rawSubject.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !subject.isEmpty else { continue }
            total += 1

            switch (object["status"] as? String) ?? "" {
            case "completed":
                done += 1
            case "in_progress":
                // 理论上同时只有一条在跑；真出现多条就取最近更新的那条。
                let stamp = (object["updatedAt"] as? NSNumber)?.intValue ?? 0
                if stamp >= currentStamp {
                    currentStamp = stamp
                    current = subject
                }
            default:
                break
            }
        }

        guard total > 0 else { return nil }
        return TaskStepProgress(total: total, done: done, current: current)
    }
}

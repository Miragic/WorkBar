import Foundation

/// 统一日志输出。
///
/// 输出到标准错误（stderr），带固定前缀便于排障。
/// - 说明：不直接使用 `NSLog`：在本工具链的部分 SDK 下 `NSLog` 变参函数被标记为不可用，
///   且我们无需系统日志归档能力，写 stderr 足够且零依赖。
///
/// - Note: 通过 `open xxx.app` 启动时 stderr 没有终端接住，日志会丢失。
///   排障时用环境变量 `TB_LOG_FILE=/tmp/tb.log` 指定一个文件，日志会同时追加进去
///   （带时间戳）。只在设置了该变量时才打开文件，平时不产生任何磁盘写入。
func tbLog(_ message: @autoclosure () -> String) {
    let text = message()
    if let data = (text + "\n").data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
    TBLogFile.shared.append(text)
}

/// 是否开启调试日志（环境变量 `TB_DEBUG=1` / `TB_DEBUG=true`）。
///
/// 用途：AX 遍历、缓存命中、重建跳过这类高频/冗余信息默认不打印，
/// 只在排障时用 `TB_DEBUG=1 ./WorkBar` 打开，避免每次轮询都刷屏。
let tbDebugEnabled: Bool = {
    guard let raw = ProcessInfo.processInfo.environment["TB_DEBUG"] else { return false }
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return value == "1" || value == "true" || value == "yes"
}()

/// 调试日志：仅当 `TB_DEBUG` 打开时输出。
func tbDebugLog(_ message: @autoclosure () -> String) {
    guard tbDebugEnabled else { return }
    tbLog(message())
}

/// 可选的日志文件落盘。
///
/// 存在的唯一理由：`open app` 启动的进程 stderr 无人接收，"粘贴没反应"这类
/// 只在真机才复现的问题必须有一个事后能读的地方。
///
/// - 默认写 `~/Library/Logs/WorkBar.log`（每次启动清空，不长期堆积）；
/// - `TB_LOG_FILE=<path>` 可改路径；
/// - `TB_LOG_OFF=1` 可彻底关闭文件落盘。
///
/// - Note: 只有真正的"用户动作 + 结果"才写文件（注入、语音、弹层），
///   每秒级的状态轮询都走 `tbDebugLog`，所以文件体积很小。
final class TBLogFile {

    static let shared = TBLogFile()

    private let handle: FileHandle?

    /// 实际使用的日志文件路径；未启用文件落盘时为 nil。
    let path: String?

    private let queue = DispatchQueue(label: "tb.logfile")

    private init() {
        let env = ProcessInfo.processInfo.environment
        if env["TB_LOG_OFF"] == "1" {
            handle = nil
            path = nil
            return
        }
        let resolved: String
        if let custom = env["TB_LOG_FILE"], !custom.isEmpty {
            resolved = custom
        } else {
            let logs = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs", isDirectory: true)
            try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            resolved = logs.appendingPathComponent("WorkBar.log").path
        }
        path = resolved
        FileManager.default.createFile(atPath: resolved, contents: nil)
        handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: resolved))
        // 覆盖写：每次启动清空，避免日志文件无限增长。
        try? handle?.truncate(atOffset: 0)
    }

    /// 追加一行（带时间戳）。未配置 `TB_LOG_FILE` 时是空操作。
    func append(_ text: String) {
        guard let handle = handle else { return }
        let stamp = Self.formatter.string(from: Date())
        guard let data = "[\(stamp)] \(text)\n".data(using: .utf8) else { return }
        // 串行队列：多线程同时写同一个 FileHandle 会交错出乱码。
        queue.async { try? handle.write(contentsOf: data) }
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}

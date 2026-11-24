import Foundation
import SQLite3

/// 数据源协议：展示层与状态机只依赖此协议，便于替换实现 / 注入 Mock。
protocol BuddyStateProvider: AnyObject {
    /// 接入应用展示名。
    var appName: String { get }
    /// 读取一次 sessions 快照（同步；实现内部已做只读打开与失败降级）。
    func fetchSessions() -> [TaskInfo]
    /// 读取空闲态统计（今日完成数 / 今日消耗 / 累计消耗）；实现内部已做失败降级。
    func fetchIdleStats() -> IdleStats
    /// 检测 WorkBuddy 当前是否弹出了选择层（成长计划 / 抽奖 / 确认框）。
    ///
    /// - Note: 同步阻塞（含 0.3s AX 唤醒 + 最长 2.5s 遍历）；**必须在后台队列调用**。
    ///   未授权 / 没有弹层 / 命中安全黑名单返回 nil。
    func detectDialog() -> DialogSnapshot?
}

/// SQLite 读取相关错误。
enum SQLiteSessionError: Error, Equatable {
    case openFailed(String)
    case prepareFailed(String)
}

/// `sessions` 表只读解析器。
///
/// 设计要点（对应 FEASIBILITY.md 风险 R3「schema 随版本变化」）：
/// - 通过 `PRAGMA table_info(sessions)` 动态探测实际列名，**只取存在的列**，缺失列用默认值兜底，
///   避免因版本升级导致列名变化而崩溃。
/// - 只读打开（`SQLITE_OPEN_READONLY`），因为 workbuddy.db 可能被 WorkBuddy 进程占用。
/// - 表不存在 / 文件不存在时返回空数组（由上层降级为空状态），不抛错。
enum SQLiteSessionReader {
    static let tableName = "sessions"

    /// 从已打开的数据库句柄读取 sessions。
    /// - Parameter db: 已打开的 SQLite 句柄（测试可用 `:memory:` 句柄直接调用，无需真实 db）。
    /// - Parameter stepProvider: 按 session id 取待办步骤；nil 表示不读取（默认）。
    ///   只有设置里打开「任务步骤」时 Provider 才传，避免为用不到的会话白读磁盘。
    static func readSessions(from db: OpaquePointer,
                             stepProvider: ((String) -> TaskStepProgress?)? = nil) throws -> [TaskInfo] {
        let available = tableColumns(db: db, table: tableName)
        // 表不存在 / 无列 => 视为空状态，不报错。
        guard !available.isEmpty else { return [] }

        // 主键列：优先 `id`，否则退化为 `rowid`。
        let idColumn = available.contains("id") ? "id" : "rowid"

        // 按「存在才选」的原则拼装 SELECT 列表，规避缺失列。
        // - Note: `updated_at` 也在列表里 —— 它不只是排序键，还是「距上次活动」的候选时间戳之一
        //   （见 `ActivityAge.activityAge(lastActivityRaw:updatedRaw:now:)`）。
        let optionalColumns = [
            "title", "custom_title", "status", "unread",
            "model", "group_id", "group_title", "buddy_binding_json",
            "last_activity_at", "updated_at"
        ].filter { available.contains($0) }

        let selectList = ([idColumn] + optionalColumns).joined(separator: ", ")

        // 动态拼装 WHERE（按列存在性降级）：
        // - 排除软删除行（deleted_at IS NOT NULL 的 18 行中，含 1 条 pending / 1 条 working，
        //   若不排除会让 Touch Bar 永久显示「1 待确认」，用户点进去发现是已删除会话）；
        // - 排除已归档（status <> 'archived'）。
        var conditions: [String] = []
        if available.contains("deleted_at") {
            conditions.append("deleted_at IS NULL")
        }
        if available.contains("status") {
            conditions.append("status <> 'archived'")
        }

        var sql = "SELECT \(selectList) FROM \(tableName)"
        if !conditions.isEmpty {
            sql += " WHERE " + conditions.joined(separator: " AND ")
        }

        // 动态 ORDER BY：优先按最近更新排序，保证「单任务详情 / 横滑」顺序稳定（原无 ORDER BY 行序不确定）。
        if available.contains("updated_at") {
            sql += " ORDER BY updated_at DESC"
        } else if available.contains("last_activity_at") {
            sql += " ORDER BY last_activity_at DESC"
        }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let stmt = statement else {
            throw SQLiteSessionError.prepareFailed(lastErrorMessage(db))
        }
        defer { sqlite3_finalize(stmt) }

        // 列名 -> 列索引映射（不依赖列顺序，便于应对版本差异）。
        var indexByName: [String: Int32] = [:]
        let columnCount = sqlite3_column_count(stmt)
        for i in 0..<columnCount {
            if let cName = sqlite3_column_name(stmt, i) {
                indexByName[String(cString: cName)] = i
            }
        }

        var tasks: [TaskInfo] = []
        // 上下文占用先整表读成字典，再按 session_id 合并。
        //
        // 为什么不去改上面那条动态拼装的 SELECT 加一个 LEFT JOIN：
        // 那条 SQL 靠「列存在才选」逐项降级，再塞一个可选的 JOIN 会让它同时依赖
        // 两张表的列存在性，任何一边的版本差异都会把整条语句变复杂；
        // 单独一条查询失败最多是「没有百分比」，而主查询失败会变成「整个 Touch Bar 空白」。
        // 两张表都是小表（实测 sessions 78 行、session_usage 同量级），多读一次可以忽略。
        let usageBySession = readUsage(from: db)
        // 「现在」只取一次：整个结果集用同一个基准，避免逐行取值导致同一批快照里
        // 各任务的时长基准差几毫秒（虽然肉眼看不出，但会让单测不可复现）。
        let now = Date().timeIntervalSince1970
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = textValue(stmt, indexByName[idColumn]) ?? UUID().uuidString

            // 标题优先级：custom_title（用户重命名）> title；两者皆空 => 占位行，跳过。
            let customTitle = textValue(stmt, indexByName["custom_title"])
            let rawTitle = textValue(stmt, indexByName["title"])
            guard let title = firstNonEmpty([customTitle, rawTitle]) else {
                // 实测存在 custom_title/title 均为空的占位会话（如 active 行），无展示意义，跳过。
                continue
            }

            let status = TaskStatus.from(raw: textValue(stmt, indexByName["status"]))
            let unread = (intValue(stmt, indexByName["unread"]) ?? 0) != 0
            let rawModel = textValue(stmt, indexByName["model"])

            tasks.append(
                TaskInfo(
                    id: id,
                    title: title,
                    status: status,
                    unread: unread,
                    model: rawModel,
                    groupID: textValue(stmt, indexByName["group_id"]),
                    groupTitle: textValue(stmt, indexByName["group_title"]),
                    buddyName: parseBuddyName(textValue(stmt, indexByName["buddy_binding_json"])),
                    modelDisplayName: ModelCatalog.displayName(for: rawModel),
                    modelMultiplier: ModelCatalog.multiplier(for: rawModel),
                    // 两个候选字段都传给 `ActivityAge`，由它归一单位后取**更近的那个**：
                    // `updated_at` 实测恒 ≥ `last_activity_at`（后者是纯滞后指标），
                    // 单看后者会让「可能卡住了」长期误报。列缺失时对应值为 nil 自动跳过。
                    activityAge: ActivityAge.activityAge(
                        lastActivityRaw: intValue(stmt, indexByName["last_activity_at"]),
                        updatedRaw: intValue(stmt, indexByName["updated_at"]),
                        now: now
                    ),
                    // 上下文占用：该会话没有 `session_usage` 行时两个值都是 nil，
                    // `ContextUsage.ratio` 返回 nil → 详情第二行整段省略（不显示占位符）。
                contextUsage: ContextUsage.ratio(
                    used: usageBySession[id]?.used,
                    size: usageBySession[id]?.size
                ),
                // 步骤只在「设置开了」且「这个会话正在跑」时才读盘。
                // 空闲 / 待确认 / 已完成的会话拿不到这一步的信息，避免每轮扫十几个目录。
                stepProgress: (status == .working || status == .active)
                    ? stepProvider?(id) ?? nil
                    : nil
            )
            )
        }
        return tasks
    }

    /// 读取 `session_id -> (used, size)` 的上下文占用映射。
    ///
    /// - 健壮性：`session_usage` 表不存在 / 缺列 / 打开失败时返回空字典，绝不抛错。
    ///   理由与 `readIdleStats` 一致：这一项是「有则更好」的附加信息，
    ///   绝不因为它读不到就让整条 Touch Bar 降级成空白。
    ///
    /// - Parameter db: 已打开的 SQLite 句柄。
    /// - Returns: 会话 ID 到占用原始值的映射；表或列缺失时为空字典。
    static func readUsage(from db: OpaquePointer) -> [String: (used: Int, size: Int)] {
        let columns = tableColumns(db: db, table: "session_usage")
        // 三列缺一不可：少了 size 就算不出比例，少了 used 同理。
        guard columns.contains("session_id"), columns.contains("used"), columns.contains("size") else {
            return [:]
        }

        var statement: OpaquePointer?
        let sql = "SELECT session_id, used, size FROM session_usage"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let stmt = statement else {
            return [:]
        }
        defer { sqlite3_finalize(stmt) }

        var usage: [String: (used: Int, size: Int)] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            // session_id 为 NULL / 空串的行无法与 sessions 关联，直接跳过。
            guard sqlite3_column_type(stmt, 0) != SQLITE_NULL,
                  let cSessionID = sqlite3_column_text(stmt, 0) else { continue }
            let sessionID = String(cString: cSessionID)
            guard !sessionID.isEmpty else { continue }

            // 表定义里 used/size 是 NOT NULL，但旧库 / 手改库仍可能是 NULL：
            // 读成 0 会变成「上下文 0%」，那是在编数据，所以宁可不存这一行。
            guard sqlite3_column_type(stmt, 1) != SQLITE_NULL,
                  sqlite3_column_type(stmt, 2) != SQLITE_NULL else { continue }

            // 数值本身的合法性（负数 / size 为 0）交给 `ContextUsage.ratio` 判定，
            // 这里不重复一套规则 —— 免得两处阈值将来走岔。
            usage[sessionID] = (used: Int(sqlite3_column_int64(stmt, 1)),
                               size: Int(sqlite3_column_int64(stmt, 2)))
        }
        return usage
    }

    /// 以只读方式打开数据库文件并读取 sessions。
    /// - Note: workbuddy.db 可能被 WorkBuddy 进程占用，故使用 `SQLITE_OPEN_READONLY`；
    ///   文件不存在或打开失败时抛错，交由上层（Provider）降级为空状态，保证不崩溃。
    static func readSessions(atPath path: String,
                             stepProvider: ((String) -> TaskStepProgress?)? = nil) throws -> [TaskInfo] {
        guard FileManager.default.fileExists(atPath: path) else { return [] }

        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let handle = db else {
            let message = lastErrorMessage(db)
            if let db = db { sqlite3_close(db) }
            throw SQLiteSessionError.openFailed(message)
        }
        defer { sqlite3_close(handle) }
        return try readSessions(from: handle, stepProvider: stepProvider)
    }

    // MARK: - 积分口径（纯函数，便于单测）

    /// `credit_json` 里解出的一条消耗记录：该 request 的真实时间 + 积分。
    struct CreditEntry {
        let date: Date
        let value: Double
    }

    /// 把 `credit_json` 的 key（UUIDv7）解成 Date。
    ///
    /// UUIDv7 的前 48 bit 是毫秒级 Unix 时间戳，对应 key 的前 12 位 hex；
    /// 实测 `01a1cda8258e7d16b772190cc2ce3f4f` → 2026-11-12 10:48:31（本地 UTC+8）。
    ///
    /// - Returns: 解出的时间；key 太短 / 非十六进制 / 年份不在 2020~2030（旧格式）
    ///   一律返回 nil，让调用方跳过该条，避免把几十年前的会话算进「今日」。
    static func uuidV7Date(forKey key: String) -> Date? {
        let hex = key.replacingOccurrences(of: "-", with: "")
        guard hex.count >= 12 else { return nil }
        let prefix = String(hex.prefix(12))
        guard let millis = UInt64(prefix, radix: 16) else { return nil }
        let date = Date(timeIntervalSince1970: Double(millis) / 1000.0)
        // 旧格式 key 的前 12 位是 ASCII 码，常被解成公元 5 位数年份；
        // 时间上明显不合理的直接丢弃（见实测：178 条旧格式 key 被跳过）。
        let year = Calendar.current.component(.year, from: date)
        guard (2020...2030).contains(year) else { return nil }
        return date
    }

    /// 解析 `credit_json`，返回所有**可识别时间**的消耗条目。
    ///
    /// 容错：`nil` / 非 UTF-8 / 非 JSON 对象 / 单条 value 非数字，都只跳过对应部分，不抛错。
    static func creditEntries(from json: String?) -> [CreditEntry] {
        guard let json = json,
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else { return [] }

        var entries: [CreditEntry] = []
        for (key, value) in dict {
            guard let date = uuidV7Date(forKey: key) else { continue }
            let credit: Double
            if let number = value as? NSNumber {
                credit = number.doubleValue
            } else if let text = value as? String {
                credit = Double(text) ?? 0
            } else {
                credit = 0
            }
            entries.append(CreditEntry(date: date, value: credit))
        }
        return entries
    }

    /// 口径 A：今日各轮之和 —— 只累加本地日期为今天的 request 积分。
    static func creditsToday(from json: String?, now: Date = Date()) -> Double {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let sum = creditEntries(from: json).reduce(0.0) { total, entry in
            calendar.startOfDay(for: entry.date) == today ? total + entry.value : total
        }
        return rounded2(sum)
    }

    /// 口径 B：本轮消耗 —— 时间上最近一条 request 的积分（不是字典顺序的最后一条）。
    static func latestCredit(from json: String?) -> Double {
        guard let latest = creditEntries(from: json).max(by: { $0.date < $1.date }) else {
            return 0
        }
        return rounded2(latest.value)
    }

    /// 金额统一保留两位（与旧 SQL 的 `ROUND(...,2)` 口径一致）。
    private static func rounded2(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    /// 读取空闲态统计（今日完成数 / 今日消耗 / 累计消耗）。
    ///
    /// - 健壮性：`session_usage` 表缺失、`credit_json` 为 NULL 或无法解析时，
    ///   对应字段降级为 0，绝不抛错、不崩溃。
    ///
    /// - Important: 今日消耗不再用「会话 updated_at 是今天就把整个 credit_json 求和」——
    ///   那会把用了 11 天的会话 73 条 request 全算进今日（实测 22835.98）。
    ///   现在按每条 request 的 UUIDv7 时间精确过滤本地「今天」。
    static func readIdleStats(from db: OpaquePointer) -> IdleStats {
        let sessionCols = tableColumns(db: db, table: tableName)
        let usageCols = tableColumns(db: db, table: "session_usage")

        // 今日完成数：sessions 需有 status / updated_at（有 deleted_at 则一并过滤）。
        var todayCompleted = 0
        if sessionCols.contains("status"), sessionCols.contains("updated_at") {
            var conditions = ["status='completed'"]
            if sessionCols.contains("deleted_at") {
                conditions.append("deleted_at IS NULL")
            }
            conditions.append("date(updated_at/1000,'unixepoch','localtime')=date('now','localtime')")
            let sql = "SELECT COUNT(*) FROM sessions WHERE " + conditions.joined(separator: " AND ")
            todayCompleted = scalarInt(db: db, sql: sql) ?? 0
        }

        // 今日消耗 / 本轮消耗：Swift 侧解析 credit_json 的 UUIDv7 时间戳，
        // 按每条 request 的真实时间过滤「今天」。不依赖 SQLite JSON1（json_each），
        // 老库 / 编译期关掉 JSON1 的 SQLite 同样可用。
        var todayCredits: Double = 0
        var latestCreditValue: Double = 0
        if usageCols.contains("credit_json") {
            let now = Date()
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: now)
            var entries: [CreditEntry] = []

            var statement: OpaquePointer?
            let sql = "SELECT credit_json FROM session_usage WHERE credit_json IS NOT NULL"
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
               let stmt = statement {
                defer { sqlite3_finalize(stmt) }
                while sqlite3_step(stmt) == SQLITE_ROW {
                    guard let cText = sqlite3_column_text(stmt, 0) else { continue }
                    entries.append(contentsOf: creditEntries(from: String(cString: cText)))
                }
            }

            // 口径 A：只累加本地日期为今天的条目；一次汇总后统一 round，
            // 避免逐行 round 带来的分位误差。
            let todaySum = entries.reduce(0.0) { total, entry in
                calendar.startOfDay(for: entry.date) == today ? total + entry.value : total
            }
            todayCredits = rounded2(todaySum)
            // 口径 B：时间上最新的一条。
            if let latest = entries.max(by: { $0.date < $1.date }) {
                latestCreditValue = rounded2(latest.value)
            }
        }

        // 累计消耗积分（简化：全表求和）。
        var totalCredits: Double = 0
        if usageCols.contains("credit_json") {
            let sql = "SELECT ROUND(COALESCE(SUM(j.value),0),2) FROM session_usage u, json_each(u.credit_json) j"
            totalCredits = scalarDouble(db: db, sql: sql) ?? 0
        }

        return IdleStats(todayCompleted: todayCompleted,
                         todayCredits: todayCredits,
                         totalCredits: totalCredits,
                         latestCredit: latestCreditValue)
    }

    /// 以只读方式打开数据库文件并读取空闲态统计；文件不存在 / 打开失败返回 `.empty`（不抛错）。
    static func readIdleStats(atPath path: String) -> IdleStats {
        guard FileManager.default.fileExists(atPath: path) else { return .empty }
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let handle = db else {
            if let db = db { sqlite3_close(db) }
            return .empty
        }
        defer { sqlite3_close(handle) }
        return readIdleStats(from: handle)
    }

    // MARK: - 私有工具

    /// 探测某张表的列集合；表不存在时返回空集。
    static func tableColumns(db: OpaquePointer, table: String) -> Set<String> {
        var statement: OpaquePointer?
        let sql = "PRAGMA table_info(\(table))"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let stmt = statement else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        var columns = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            // PRAGMA table_info 结果集第 2 列（索引 1）为列名。
            if let cName = sqlite3_column_text(stmt, 1) {
                columns.insert(String(cString: cName))
            }
        }
        return columns
    }

    private static func textValue(_ stmt: OpaquePointer, _ index: Int32?) -> String? {
        guard let index = index, let cText = sqlite3_column_text(stmt, index) else { return nil }
        let value = String(cString: cText)
        return value.isEmpty ? nil : value
    }

    private static func intValue(_ stmt: OpaquePointer, _ index: Int32?) -> Int? {
        guard let index = index else { return nil }
        // 先判断类型，避免把 NULL 读成 0 造成语义歧义。
        if sqlite3_column_type(stmt, index) == SQLITE_NULL { return nil }
        return Int(sqlite3_column_int64(stmt, index))
    }

    /// 执行只返回单值（整数）的查询；失败 / NULL 返回 nil。
    private static func scalarInt(db: OpaquePointer, sql: String) -> Int? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let stmt = statement else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        if sqlite3_column_type(stmt, 0) == SQLITE_NULL { return nil }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// 执行只返回单值（浮点）的查询；失败 / NULL 返回 nil。
    private static func scalarDouble(db: OpaquePointer, sql: String) -> Double? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let stmt = statement else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        if sqlite3_column_type(stmt, 0) == SQLITE_NULL { return nil }
        return sqlite3_column_double(stmt, 0)
    }

    private static func firstNonEmpty(_ candidates: [String?]) -> String? {
        for case let value? in candidates
        where !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return value
        }
        return nil
    }

    /// 从 buddy_binding_json 中尽力解析 Buddy 名称；解析失败返回 nil（不影响主流程）。
    private static func parseBuddyName(_ json: String?) -> String? {
        guard let json = json,
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return (object["buddy_name"] as? String) ?? (object["name"] as? String)
    }

    private static func lastErrorMessage(_ db: OpaquePointer?) -> String {
        guard let db = db, let cMessage = sqlite3_errmsg(db) else {
            return "unknown sqlite error"
        }
        return String(cString: cMessage)
    }
}

/// 真实数据源：只读本地 WorkBuddy SQLite。
///
/// 任何读取失败都降级为空状态，保证 Touch Bar 不崩溃（短暂显示「空闲」）。
final class WorkBuddyProvider: BuddyStateProvider {
    let appName = "WorkBuddy"
    private let dbPath: String
    /// 带缓存的步骤读取器。放在实例上而不是做成静态单例，便于单测注入临时目录。
    private let stepReader = TaskStepReader()

    /// - Parameter dbPath: 数据库路径，默认 `~/.workbuddy/workbuddy.db`（WorkBuddy 5.9.3 实测存在）。
    init(dbPath: String = WorkBuddyProvider.defaultDBPath) {
        self.dbPath = dbPath
    }

    /// 默认本地数据库路径。
    ///
    /// 支持用环境变量 `TOUCHBARBUDDY_DB_PATH` 覆盖，便于：
    /// - 用数据库副本验证「空闲态」等难以自然触发的状态；
    /// - 排查时指向历史快照，避免影响真实数据。
    static var defaultDBPath: String {
        if let override = ProcessInfo.processInfo.environment["TOUCHBARBUDDY_DB_PATH"],
           !override.isEmpty {
            return override
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".workbuddy/workbuddy.db")
    }

    func fetchSessions() -> [TaskInfo] {
        do {
            // 开关关闭时连目录都不碰；打开时也只查进行中 / 活跃会话（见 readSessions）。
            let provider: ((String) -> TaskStepProgress?)? = Settings.showTaskStep
                ? { [weak self] id in self?.stepReader.progress(forSessionID: id) }
                : nil
            return try SQLiteSessionReader.readSessions(atPath: dbPath, stepProvider: provider)
        } catch {
            tbLog("[WorkBar] 读取 sessions 失败（降级为空状态）: \(error)")
            return []
        }
    }

    func fetchIdleStats() -> IdleStats {
        // 内部已做健壮降级（含表/列/json1 缺失 → 0），不需要 onState 抛错。
        SQLiteSessionReader.readIdleStats(atPath: dbPath)
    }

    /// 弹层检测（转发到 `DialogDetector`）。
    ///
    /// 不做缓存：弹层的生命周期以秒计，缓存只会让「已关闭的弹层」继续挂在 Touch Bar 上。
    /// 调用频率由控制器控制（5 秒一次 + 点击后主动刷新）。
    func detectDialog() -> DialogSnapshot? {
        DialogDetector.detect()
    }
}

/// 轮询调度：固定间隔在主线程触发回调（所有 Touch Bar 刷新统一切回主线程）。
/// - Note: 默认 3s（见团队需求），可通过常量配置；频率越低功耗越低。
final class PollingService {
    /// 默认轮询间隔（秒）。
    static let defaultInterval: TimeInterval = 3.0

    private let interval: TimeInterval
    private let onTick: () -> Void
    private var timer: Timer?

    init(interval: TimeInterval = PollingService.defaultInterval,
         onTick: @escaping () -> Void) {
        self.interval = interval
        self.onTick = onTick
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.onTick()
        }
        // 用 common modes，保证菜单打开 / 滚动时也持续刷新。
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    deinit { stop() }
}

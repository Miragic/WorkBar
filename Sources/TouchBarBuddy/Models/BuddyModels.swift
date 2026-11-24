import Foundation

/// 任务（会话）状态。
///
/// 对齐 WorkBuddy `sessions.status` 实测值域：`working` / `pending` / `completed` / `archived` / `active`
/// （见 docs/FEASIBILITY.md §2.1，以及 2026-11 真机实测分布：completed 67 / archived 7 / working 2 / pending 1 / active 1），
/// 并保留 `.unknown` 作为「列缺失 / 出现未知新值」时的兜底。
///
/// - Note: `active` 行实测为「`title` 与 `custom_title` 均为空、`updated_at` 为 NULL」的占位会话，
///   语义上归入「进行中」一类（状态机里与 `working` 一并收进 working 态）。
/// - Note: `sessions` 表当前没有明确的「失败」列，故 MVP 暂不单独建模失败态。
///   若后续版本新增失败标记，可在此追加 `.failed`，并在状态机里把它排在 pending 之后、working 之前。
enum TaskStatus: String, Equatable {
    case working
    case pending
    case completed
    case archived
    case active
    case unknown

    /// 解析数据库中的原始状态字符串；未知 / 空值统一归为 `.unknown`。
    static func from(raw: String?) -> TaskStatus {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else {
            return .unknown
        }
        return TaskStatus(rawValue: raw) ?? .unknown
    }
}

/// 单条任务（会话）的不可变快照，由 `sessions` 表一行映射而来。
///
/// 字段均可从 `sessions` 表（动态探测列名）取值；缺失列以可选 / 默认值兜底。
struct TaskInfo: Identifiable, Equatable {
    /// 会话唯一标识（优先 `id` 列，缺省时退回 `rowid`）。
    let id: String
    /// 展示标题（优先 `custom_title`，其次 `title`，最后兜底「未命名会话」）。
    let title: String
    /// 归约后的任务状态。
    let status: TaskStatus
    /// 是否未读（`unread != 0`）。
    let unread: Bool
    /// 使用的模型名（可选）。
    let model: String?
    /// 所属分组 ID（可选）。
    let groupID: String?
    /// 所属分组标题（可选）。
    let groupTitle: String?
    /// 绑定的 Buddy 名称（从 `buddy_binding_json` 尽力解析，可选；实测该列 78/78 全为空，恒 nil）。
    let buddyName: String?
    /// 模型可读名（由 `ModelCatalog` 映射；未知值原样返回，空为 nil）。
    let modelDisplayName: String?
    /// 模型倍率（真实倍率拿不到时恒为 nil，见 `ModelCatalog.multiplier(for:)`）。
    let modelMultiplier: Double?
    /// 距上次活动的秒数（来自 `sessions.last_activity_at`；列为 NULL / 无效值时为 nil）。
    ///
    /// 为什么存**已过去多少秒**而不是绝对时间戳：`TaskInfo` 是快照，UI 拿到它时不需要
    /// 再去问「现在几点」就能直接显示；存绝对值的话每个渲染点都要多传一个 now，
    /// 而多传的这个 now 一旦取错（例如跨轮询复用同一个值）反而更容易算错。
    /// 快照会随轮询刷新，所以这个相对值最多旧 3 秒，对「12s / 3m」这种精度足够。
    let activityAge: TimeInterval?

    /// 待办步骤进度（来自 `~/.workbuddy/tasks/<session_id>/*.json`）。
    ///
    /// - Note: 只在「设置里开启任务步骤」**且**该会话是进行中 / 活跃态时才去读盘，
    ///   其余情况恒为 nil —— 所以 nil 同时代表「没开这个功能」和「这个会话没有待办清单」，
    ///   两者在界面上的表现一致（这一格不显示），不需要区分。
    let stepProgress: TaskStepProgress?

    /// 上下文窗口占用比（0...1）；来自 `session_usage.used/size`，无数据时为 nil。
    ///
    /// - Note: 由 `ContextUsage.ratio(used:size:)` 算好再传进来，本结构体不再做任何
    ///   取值校验 —— 「什么算有效」这条规则只写在一处（`ContextUsage`）。
    let contextUsage: Double?

    /// 这条任务是否已经久到「疑似卡住」（超过 `ActivityAge.staleThreshold`）。
    ///
    /// - Important: **单一真源**。判定只写在这里：摘要文案、橙色时长、布局是否重建
    ///   都读它，避免出现「数字已经橙了但摘要还写进行中」这种两处阈值不一致的怪象。
    ///   阈值本身仍在 `ActivityAge.staleThreshold = 120`，不在这里另立数字。
    ///   严格取 `>`：恰好 120 秒不算卡住，和 `TaskStripView` 的橙色判据
    ///   (`seconds > staleThreshold`) 完全一致。
    var isStale: Bool {
        guard let age = activityAge else { return false }
        return age > ActivityAge.staleThreshold
    }

    /// 上下文是否已接近上限（达到 `ContextUsage.tightThreshold`，即 75%）。
    ///
    /// - Important: **单一真源**。第二行文案的警告色、将来的任何提示都读它，
    ///   阈值只在 `ContextUsage.tightThreshold` 里写一次（与 `isStale` 同一套做法）。
    ///   这里委托给 `ContextUsage.isTight`，连「nil 怎么办」的规则也不重复实现。
    var isContextTight: Bool { ContextUsage.isTight(contextUsage) }

    init(id: String,
         title: String,
         status: TaskStatus,
         unread: Bool = false,
         model: String? = nil,
         groupID: String? = nil,
         groupTitle: String? = nil,
         buddyName: String? = nil,
         modelDisplayName: String? = nil,
         modelMultiplier: Double? = nil,
         activityAge: TimeInterval? = nil,
         contextUsage: Double? = nil,
         stepProgress: TaskStepProgress? = nil) {
        self.id = id
        self.title = title
        self.status = status
        self.unread = unread
        self.model = model
        self.groupID = groupID
        self.groupTitle = groupTitle
        self.buddyName = buddyName
        self.modelDisplayName = modelDisplayName
        self.modelMultiplier = modelMultiplier
        self.activityAge = activityAge
        self.contextUsage = contextUsage
        self.stepProgress = stepProgress
    }
}

/// 距上次活动的时长：解析与格式化（纯函数，便于单测）。
///
/// 为什么需要它：`sessions` 表 39 个字段里**没有任何步骤/总步数**，做百分比进度条只能编数据；
/// 而工作态宽度（summary 82 + task 200 + voice 82 = 364pt）本来就超过约 290pt 的可用宽度，
/// 也没有空间新增 item。所以 V13 的「进度」降级成一个**真实可算、且不占额外宽度**的指标：
/// 「距上次活动多久」。它能回答一个原来答不了的问题 ——
/// **这个任务是还在动，还是已经卡住了**。
///
/// - Note: 判据取 `max(last_activity_at, updated_at)`，而不是单看 `last_activity_at`。
///   真机全库实测（78 行）`last_activity_at` **没有一次**比 `updated_at` 新
///   （更新 64 行 / 相等 13 行 / 落后 0 行；working 行平均落后 384 秒，最坏 764 秒），
///   它是个纯滞后指标。单看它会让橙色长期亮着、退化成噪音。
enum ActivityAge {

    /// 超过这个秒数就认为「可能卡住了」，文案转橙色。
    ///
    /// 为什么是 120 秒而不是 60：正常的模型调用 + 工具执行常有 1 分钟以上的空档
    /// （长文件生成、命令都在跑），60 秒就报警会让橙色变成常态，用户很快学会无视它。
    /// 2 分钟以上没有任何活动，才是真的该看一眼了。
    ///
    /// - Note: 这个阈值是**基于 `max(last_activity_at, updated_at)` 判定**的。
    ///   实测库里有 66 行 completed 的 `updated_at` 比 `last_activity_at` 新，
    ///   若单看后者，120 秒会长期误报。误报方向也要选安全侧：
    ///   宁可真卡住时晚 2 分钟才转橙，也不要常态亮橙。
    static let staleThreshold: TimeInterval = 120

    /// 把「已过去秒数」格式化成 Touch Bar 上的耗时文案。
    ///
    /// 规则（与 WorkBuddy 在助手消息下方显示的 `已处理 1m8s` / `已完成 15m42s` 一致）：
    /// - nil / 负数 / 非有限值 → nil（不显示，而不是显示 `-1s` 这种噪音）
    /// - `< 60` → `"12s"`
    /// - `< 3600` → `"15m42s"`（分钟 + 秒都显示，不再把秒截断掉）
    /// - `>= 3600` → `"1h2m3s"`
    ///
    /// - Note: 2026-11-19 用户给截图要求「跟 WorkBuddy 红框里的时间一样」，
    ///   所以分钟档从原来的 `"15m"` 升级成 `"15m42s"`。
    ///   更早还曾把秒数折叠成恒定符号，被用户明确否掉（「时间显示的不要改」）——
    ///   两次反馈方向一致：**他要读到真实秒数**。
    ///   文案变长不触发重建：`TaskStripView` 的时长槽宽度固定，纯文字替换即可。
    ///
    /// - Parameter seconds: 已过去的秒数。
    /// - Returns: 展示文案；不可用时 nil。
    static func formatActivityAge(_ seconds: TimeInterval?) -> String? {
        guard let seconds = seconds, seconds >= 0, seconds.isFinite else { return nil }
        // 先截断再判区间：59.9 秒要落在 `< 60`（显示 `59s`）。
        let value = Int(seconds)
        if value < 60 { return "\(value)s" }
        if value < 3600 { return "\(value / 60)m\(value % 60)s" }
        return "\(value / 3600)h\((value % 3600) / 60)m\(value % 60)s"
    }

    /// 把数据库里的原始时间戳（秒或毫秒）归一成秒级 epoch。
    ///
    /// - Important: 必须先判断单位，否则会差 1000 倍。实测 `last_activity_at` 与
    ///   `updated_at` **都是毫秒**（样本 `1794989959658`，而 `strftime('%s','now')`
    ///   是 `1794990649` 秒）；若按秒处理会显示「56583h」。
    ///   归一方式：按数量级判断 —— 秒级 epoch 距今约 1.7e9、毫秒级约 1.7e12，
    ///   以 1e11 为界（1e11 秒是公元 5138 年，不可能出现），超过就除以 1000。
    ///
    /// - Parameter raw: 数据库原始整数（秒或毫秒）。
    /// - Returns: 秒级时间戳；0 / NULL / 负数 / 不可信区间外的值返回 nil。
    static func normalizedTimestamp(_ raw: Int?) -> TimeInterval? {
        guard let raw = raw, raw > 0 else { return nil }
        let seconds = raw > 100_000_000_000 ? Double(raw) / 1000.0 : Double(raw)
        // 下界守卫（1e9 ≈ 2001-09）：比这更小的"时间戳"几乎一定是**类型不对**读出来的垃圾。
        // 真实存在的场景：某些版本的 `updated_at` 是 ISO 文本（`2026-01-01T00:00:00Z`），
        // 而 `sqlite3_column_int64` 会把开头的 `2026` 当成数字读出来 —— 若不拦，
        // 界面会显示「491764h」。宁可这一项不显示，也不能显示荒谬数字。
        guard seconds >= 1_000_000_000 else { return nil }
        return seconds
    }

    /// 由「上次活动时间」的原始值算出「已过去多少秒」。
    ///
    /// - Parameters:
    ///   - raw: 数据库里的原始整数（秒或毫秒）。
    ///   - now: 当前时间戳（秒），注入以便单测。
    /// - Returns: 已过去秒数；无效值 / 未来时间时为 nil。
    static func activityAge(fromRaw raw: Int?, now: TimeInterval) -> TimeInterval? {
        activityAge(lastActivityRaw: raw, updatedRaw: nil, now: now)
    }

    /// 由两个候选时间戳（`last_activity_at` / `updated_at`）算出「已过去多少秒」，**取更近的那个**。
    ///
    /// 为什么取 `max` 而不是只信 `last_activity_at`：
    /// - 两个字段都是真实数据，`max` 的语义是「**只要有任何一处记录被更新，就说明它没停**」，
    ///   这正好就是我们要回答的问题；
    /// - 实测 `updated_at` 恒 ≥ `last_activity_at`，所以绝大多数情况下等价于用 `updated_at`；
    ///   保留 `max` 是为了防止 WorkBuddy 后续版本改语义（哪天 `last_activity_at` 变得更密了，
    ///   这里一行都不用改）；
    /// - 两者都为无效值时仍返回 nil —— 没数据就不显示，不编一个「0s」出来。
    ///
    /// - Parameters:
    ///   - lastActivityRaw: `sessions.last_activity_at` 原始值。
    ///   - updatedRaw: `sessions.updated_at` 原始值。
    ///   - now: 当前时间戳（秒）。
    /// - Returns: 已过去秒数；两个字段都无效时为 nil。
    static func activityAge(lastActivityRaw: Int?,
                            updatedRaw: Int?,
                            now: TimeInterval) -> TimeInterval? {
        let candidates = [normalizedTimestamp(lastActivityRaw), normalizedTimestamp(updatedRaw)]
            .compactMap { $0 }
        guard let latest = candidates.max() else { return nil }
        let age = now - latest
        // 时钟抖动（DB 写入方时钟略快）会算出很小的负数：直接当无效，
        // 让这一项不显示 —— 总比显示「-1s」或者把人吓一跳的「0s」更诚实。
        guard age >= 0 else { return nil }
        return age
    }
}

/// 上下文窗口占用：解析、格式化与「快满了」判定（纯函数，便于单测）。
///
/// 为什么做这个：`session_usage.used/size` 是真实数据，context 涨满后 WorkBuddy 会
/// **静默压缩上下文**，用户的对话被截断却不知道。在任务详情里常显这个比例，
/// 就能在压缩发生之前自己决定要不要新开会话。
///
/// - Note: 数据源是 `session_usage` 表的 `used`（已用 token）/ `size`（窗口大小）两列，
///   实测当前会话 44609/600000 ≈ 7.4%，历史峰值 158494/300000 ≈ 52.8%。
///   该表按 `session_id` 与 `sessions` 一一对应，所以这是**按任务**的指标，
///   不是全局指标（详情视图正需要按任务看）。
enum ContextUsage {

    /// 超过这个比例就提示「上下文快满了」（转警告色）。
    ///
    /// 取 0.75 而不是 0.9：0.9 时往往已经来不及了（下一轮工具输出就可能顶满），
    /// 留 25% 余量给用户做决定。实测历史峰值 52.8%，所以正常情况下它是安静的。
    static let tightThreshold: Double = 0.75

    /// 上下文段的环形进度符号（按占用比分四档）。
    ///
    /// 用户要求「上下文三个字换成 WorkBuddy 一样的上下文图标」—— WorkBuddy 输入框左侧
    /// 是一个细灰圆环，填充比例代表用量。曾经用 `NSTextAttachment` 画真圆环，
    /// 但 Touch Bar 的 `NSTextField` 对图片附件渲染不稳定：真机表现为**首帧显示、
    /// 之后消失**（日志里附件一直在，只是不画了）。改用纯字符环形符号，
    /// 保证每次就地刷新都稳定可见；精确数值仍由后面的百分比给出。
    ///
    /// - Note: 「宽度裁剪时认出上下文」不依赖这个符号（靠 `TaskMetaSegment.kind`）。
    static let ringGlyphs = ["◔", "◑", "◒", "●"]

    /// 按占用比挑环形符号。
    ///
    /// - `< 25%` → `◔`，`< 50%` → `◑`，`< 75%` → `◒`，`>= 75%` → `●`。
    /// - 用「≤ 不到边界」而不是四舍五入：49% 仍是半环，不会提前显示 3/4 环。
    static func ringGlyph(for ratio: Double) -> String {
        if ratio < 0.25 { return ringGlyphs[0] }
        if ratio < 0.50 { return ringGlyphs[1] }
        if ratio < 0.75 { return ringGlyphs[2] }
        return ringGlyphs[3]
    }

    /// 由 `used` / `size` 原始整数算出占用比（0...1）。
    ///
    /// - 规则：`size <= 0` / `used < 0` / 任一为 nil → nil（不显示）；
    ///   `used == 0` → nil（显示「上下文 0%」是噪音）；
    ///   `used > size`（跨会话复用等脏数据）→ 夹到 1.0，绝不显示 >100%。
    ///
    /// - Parameters:
    ///   - used: 已用 token（`session_usage.used`）。
    ///   - size: 上下文窗口大小（`session_usage.size`）。
    /// - Returns: 占用比；任一输入不可用时 nil。
    static func ratio(used: Int?, size: Int?) -> Double? {
        guard let used = used, let size = size else { return nil }
        // size 为 0 时除法会得到 inf/NaN，必须先拦；负数则是脏数据。
        guard size > 0, used >= 0 else { return nil }
        // 0 是「这个会话还没开始用上下文」，显示出来纯属噪音（且多数是占位行）。
        guard used > 0 else { return nil }
        // 脏数据（例如会话被复用时换了更小的窗口）夹到 1.0：
        // 宁可说「满了」，也不能出现「上下文 117%」这种不可能的数字。
        guard used < size else { return 1.0 }
        return Double(used) / Double(size)
    }

    /// 格式化成 Touch Bar 详情第二行用的短文案：`"上下文 53%"`。
    ///
    /// - 百分比**截断**而非四舍五入：0.999 要显示 99% 而不是 100%，
    ///   否则「显示 100% 但其实还没满」会让人困惑。
    /// - nil / 非法值 → nil（整段省略，不显示占位符）。
    ///
    /// - Parameters:
    ///   - ratio: 占用比（0...1）；> 1 会被夹到 100%。
    ///   - graphic: true 时只返回百分比，圆环及间距由独立视图布局承担。
    /// - Returns: 展示文案；不可用时 nil。
    static func format(_ ratio: Double?, graphic: Bool = false) -> String? {
        guard let ratio = ratio, ratio.isFinite, ratio > 0 else { return nil }
        let clamped = min(ratio, 1.0)
        // 保留 1 位小数：放大到千分位后向下截断，再除以 10。
        // epsilon 的作用同百分数版本：Double 的 0.533 实际是 0.53299999999999995，
        // 乘 1000 直接截断会得到 53.2%，少了一个刻度。1e-6 相对于 1e3 量级是 1e-9，
        // 不会把 99.99% 抬成 100.0%。
        // - Note: 仍然是**截断**而不是四舍五入 —— 0.9999 要显示 99.9%，
        //   而不是显示「100.0% 但其实还没满」。
        let tenths = (clamped * 1000.0 + 1e-6).rounded(.down) / 10.0
        let number = String(format: "%.1f%%", min(max(tenths, 0), 100))
        return graphic ? number : ringGlyph(for: clamped) + " " + number
    }

    /// 是否已达警告阈值（`>= tightThreshold`）。nil → false。
    ///
    /// - Note: 取 `>=`（含等号）：恰好 75% 时就该提醒了 —— 这是「留 25% 余量」的定义，
    ///   写成 `>` 会让边界那一格静默地不报警。
    static func isTight(_ ratio: Double?) -> Bool {
        guard let ratio = ratio else { return false }
        return ratio >= tightThreshold
    }
}

/// Touch Bar 展示状态：由状态机对 sessions 列表做「优先级归约」得到。
///
/// 归约优先级（从高到低）：
/// 待选择(choice) > 待确认(pending) > 进行中(working) > 待读(completed 且 unread) > 空闲(idle)。
/// 每个非 idle 态都携带其对应的任务列表，供 Touch Bar 横滑切换展示。
enum TouchBarState: Equatable {
    case idle
    case pending(tasks: [TaskInfo])
    case working(tasks: [TaskInfo])
    case unread(tasks: [TaskInfo])
    /// WorkBuddy 弹出了选择层：把弹层里的按钮直接铺到 Touch Bar 供点选。
    ///
    /// - Note: 优先级**最高**，因为它意味着「此刻界面卡在一个必须做的选择上」，
    ///   用户不点就推进不下去，比「有几个任务待确认」更紧急。
    case choice(title: String, options: [String])

    /// 当前状态关联的任务列表（空闲态 / 待选择态为空）。
    var tasks: [TaskInfo] {
        switch self {
        case .idle, .choice:
            return []
        case .pending(let tasks), .working(let tasks), .unread(let tasks):
            return tasks
        }
    }

    var isIdle: Bool {
        if case .idle = self { return true }
        return false
    }

    /// 是否处于「弹层待选择」态。
    var choice: (title: String, options: [String])? {
        if case .choice(let title, let options) = self { return (title, options) }
        return nil
    }

    /// 供 Touch Bar 顶部概要区展示的短标签。
    var summaryLabel: String {
        switch self {
        case .idle:
            return "◆ 空闲"
        case .pending(let tasks):
            return "⏳ \(tasks.count) 待确认"
        case .working(let tasks):
            return "🟢 \(tasks.count) 进行中"
        case .unread(let tasks):
            return "📬 \(tasks.count) 待读"
        case .choice(let title, let options):
            return "❓ 待选择 \(title)(\(options.count))"
        }
    }
}

/// 空闲态统计。
///
/// - Important: 这里的三个字段**全部来自本地 SQLite**（`sessions` / `session_usage`），
///   不需要任何界面交互就能算出来。这是本项目唯一的「无感数据源」。
/// - Note: 「剩余积分余额」与「成长计划连登天数」曾经通过按压 WorkBuddy 的头像 / 成长入口
///   读界面文本来获取，但那会在用户眼前弹面板、抢焦点，属于割裂体验，已整体移除
///   （代码留档见 `archive/2026-11-18-intrusive-popover-readers/`）。
///   真要做到无感，只能等 WorkBuddy 提供后台接口；已知 126 个 `/api/` 路径里
///   没有任何账单 / 积分 / 余额端点，故当前版本不展示余额。
struct IdleStats: Equatable {
    /// 今日完成会话数。
    let todayCompleted: Int
    /// 今日消耗积分（口径 A：今天所有轮次之和；注意是消耗，不是余额）。
    let todayCredits: Double
    /// 累计消耗积分（备用）。
    let totalCredits: Double
    /// 本轮消耗积分（口径 B：时间上最近一条 request 的消耗）。
    ///
    /// - Note: 带默认值，兼容已有的三参数初始化（测试 / 预览）；真机由
    ///   `SQLiteSessionReader.readIdleStats` 按 UUIDv7 时间解析后填入。
    let latestCredit: Double

    init(todayCompleted: Int, todayCredits: Double, totalCredits: Double,
         latestCredit: Double = 0) {
        self.todayCompleted = todayCompleted
        self.todayCredits = todayCredits
        self.totalCredits = totalCredits
        self.latestCredit = latestCredit
    }

    static let empty = IdleStats(todayCompleted: 0, todayCredits: 0, totalCredits: 0)

    /// Touch Bar 上展示的短文案（默认口径 A：今日各轮之和）。纯函数，便于单测。
    ///
    /// - Note: 刻意压缩字数。Touch Bar 总宽 685pt 中约 400pt 被 Control Strip 与系统区域占用，
    ///   留给本 app 的宽度只有约 290pt；文案过长会把后面的「语音」按钮挤出可见区
    ///   （真机实测：完整文案 159pt 时语音按钮不显示）。
    var label: String {
        label(mode: .todayTotal)
    }

    /// 按统计口径生成短文案。纯函数：不读全局 `Settings`，便于两种口径都单测。
    /// 真机由 `TouchBarItemFactory` 传入 `Settings.idleCreditsMode`。
    func label(mode: Settings.IdleCreditsMode) -> String {
        switch mode {
        case .todayTotal:
            return "今日\(todayCompleted)完成 · 消耗\(Self.fmt(todayCredits))"
        case .latest:
            // 与口径 A 等长同构：「今日 N 完成」仍保留，只是消耗换成最近一轮。
            return "今日\(todayCompleted)完成 · 本轮\(Self.fmt(latestCredit))"
        }
    }

    private static func fmt(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

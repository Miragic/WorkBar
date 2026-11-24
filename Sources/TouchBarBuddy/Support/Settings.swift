import Foundation

/// 用户可调设置（持久化在 `UserDefaults`）。
///
/// 五项开关：**极简模式**（V8 一瞥型极简）、**默认详情模式**、**任务步骤**、
/// **图形上下文图标**、**常驻显示**；外加一项 **Touch Bar 布局**（显示 / 隐藏 + 顺序），
/// 以及一项 **空闲统计口径**（今日各轮之和 / 本轮消耗）。
/// 为什么放设置而不是写死：不同场景要的信息量不同 —— 专注干活时只看「几个在跑」，
/// 需要细节时才看任务条与时长。让用户自己切，比替他决定更合理。
enum Settings {

    /// 空闲态「消耗」的统计口径（用户在「常规」页切换）。
    ///
    /// - `todayTotal`：今日各轮之和 —— 按每条 request 的真实时间（UUIDv7 时间戳）
    ///   解码，只累加本地日期为今天的积分。
    /// - `latest`：本轮消耗 —— 取时间上最近一条 request 的积分，与工作态详情里的
    ///   `◇ N` 语义一致。
    ///
    /// 默认 `todayTotal`：用户此前看到的是「整个会话全量误算成今日」的错值，
    /// 修复后默认给出正确的今日合计。
    enum IdleCreditsMode: String {
        case todayTotal
        case latest
    }

    /// Touch Bar 上的一个可配置 item。
    ///
    /// - Note: `id` 只认四个固定值（summary / task / stats / voice），
    ///   读配置时 `layoutOrder` 会校验，非法数据一律回退默认值，避免手改 UserDefaults
    ///   导致 bar 缺项（比如把 voice 配没了）。
    struct LayoutItem: Codable, Equatable {
        let id: String
        var enabled: Bool
    }

    /// 默认布局：当前线上顺序，四项全开。
    static let defaultLayoutOrder: [LayoutItem] = [
        LayoutItem(id: "summary", enabled: true),
        LayoutItem(id: "task", enabled: true),
        LayoutItem(id: "stats", enabled: true),
        LayoutItem(id: "voice", enabled: true)
    ]

    /// 合法 id 集合（单一真源，getter 校验与预览 / 工厂共用）。
    static let layoutItemIDs: Set<String> = ["summary", "task", "stats", "voice"]

    /// 设置变更通知（`.object` 为 nil，payload 在 `userInfo` 里）。
    ///
    /// 用通知而不是直接持有控制器引用：`Settings` 是纯粹的数据层，
    /// 让它反过来依赖 UI 层会把依赖方向搞乱，也不利于单测。
    static let didChangeNotification = Notification.Name("tb.settingsDidChange")

    /// `userInfo` 里表示「哪一项变了」的键。
    static let changedKeyKey = "key"

    private enum Key {
        static let minimalMode = "tb.minimalMode"
        static let keepAwake = "tb.keepAwake"
        static let taskDetailByDefault = "tb.taskDetailByDefault"
        static let showTaskStep = "tb.showTaskStep"
        static let graphicContextIcon = "tb.graphicContextIcon"
        static let layoutOrder = "tb.layoutOrder"
        static let idleCreditsMode = "tb.idleCreditsMode"
    }

    /// 空闲统计口径，默认「今日各轮之和」。
    ///
    /// 用字符串存 rawValue 而非 Bool：将来若加第三种口径（如「本周」）无需迁移旧值；
    /// 读到未知值时回退默认值，保证手改 UserDefaults 也不会让统计消失。
    static var idleCreditsMode: IdleCreditsMode {
        get {
            guard let raw = UserDefaults.standard.string(forKey: Key.idleCreditsMode),
                  let mode = IdleCreditsMode(rawValue: raw) else {
                return .todayTotal
            }
            return mode
        }
        set {
            guard newValue != idleCreditsMode else { return }
            UserDefaults.standard.set(newValue.rawValue, forKey: Key.idleCreditsMode)
            NotificationCenter.default.post(name: didChangeNotification,
                                            object: nil,
                                            userInfo: [changedKeyKey: Key.idleCreditsMode])
        }
    }

    /// 图形上下文图标：用独立自绘视图 `ContextRingView` 替代环形字符 `◔◑◒●`。
    ///
    /// - Note: 默认 `true`。
    ///   ⚠️ V14 修正：上一版注释里「自绘 `NSTextAttachmentCell` 已验证持续显示」是**错的** ——
    ///   实测仍会在详情第二行重写几次后消失（Touch Bar 的 `NSTextFieldCell` 只画首帧附件）。
    ///   现在圆环是**独立子视图**（`ContextRingView`），不挂在富文本里，才真正稳定。
    ///   关掉即退回字符环（纯文本，永远可用）。
    static var graphicContextIcon: Bool {
        get {
            // 未写过时返回 true：`UserDefaults.bool` 对缺失键返回 false，
            // 所以这里要显式判断键是否存在。
            guard UserDefaults.standard.object(forKey: Key.graphicContextIcon) != nil else {
                return true
            }
            return UserDefaults.standard.bool(forKey: Key.graphicContextIcon)
        }
        set {
            guard newValue != graphicContextIcon else { return }
            UserDefaults.standard.set(newValue, forKey: Key.graphicContextIcon)
            NotificationCenter.default.post(name: didChangeNotification,
                                            object: nil,
                                            userInfo: [changedKeyKey: Key.graphicContextIcon])
        }
    }

    /// 任务步骤：详情第二行显示「当前做到第几步 + 这一步在做什么」，如 `3/8 核实粉丝数`。
    ///
    /// 数据来自 `~/.workbuddy/tasks/<session_id>/*.json`（WorkBuddy 自己写的待办清单）。
    /// - Note: 默认 `false`。两个原因：① 只有用过待办清单的会话才有这份数据（实测 16/54），
    ///   没数据的会话这一格是空的，默认开启会让「有没有这一格」显得随机；
    ///   ② 它会给第二行加约 70pt 压力，常态下会把模型名挤掉。
    ///   用户明确需要「知道 Buddy 现在在做哪一步」时才值得付这个宽度代价。
    static var showTaskStep: Bool {
        get { UserDefaults.standard.bool(forKey: Key.showTaskStep) }
        set {
            guard newValue != showTaskStep else { return }
            UserDefaults.standard.set(newValue, forKey: Key.showTaskStep)
            NotificationCenter.default.post(name: didChangeNotification,
                                            object: nil,
                                            userInfo: [changedKeyKey: Key.showTaskStep])
        }
    }

    /// 默认详情模式：任务条一出现就是两行详情（状态 · 模型 · 上下文 · 时长），不用再点。
    ///
    /// - Note: 开启后**点一下仍然可以收起** —— 它只是改变初始态，不是锁死。
    /// - Note: 默认 `false`。紧凑态是「一眼看几个任务在跑」的默认视角，
    ///   打开详情会占掉右侧时长槽、并把标题压到 12pt，属于用户明确表达偏好后才该生效的变化。
    /// - Note: 极简模式下任务条整体隐藏，本项不生效（不需要额外判断，
    ///   因为隐藏是 `identifiers(for:...)` 里的另一条分支）。
    static var taskDetailByDefault: Bool {
        get { UserDefaults.standard.bool(forKey: Key.taskDetailByDefault) }
        set {
            guard newValue != taskDetailByDefault else { return }
            UserDefaults.standard.set(newValue, forKey: Key.taskDetailByDefault)
            NotificationCenter.default.post(name: didChangeNotification,
                                            object: nil,
                                            userInfo: [changedKeyKey: Key.taskDetailByDefault])
        }
    }

    /// 常驻显示：**后台有任务执行时**保持屏幕（进而 Touch Bar）不休眠，
    /// 并在唤醒 / 切回后重新挂载 bar，避免被别的应用顶掉。
    ///
    /// - Important: Touch Bar 的亮灭跟随**屏幕休眠**，系统没有「只让 Touch Bar 常亮」的公开接口。
    ///   所以开启后，任务运行期间**屏幕也不会自动熄灭** —— 这是必须让用户知道的代价。
    ///   设置面板的说明文字里已写明。
    /// - Note: 默认 `false`。默认开启等于替用户阻止系统休眠，属于改变系统行为，不能默认。
    static var keepAwake: Bool {
        get { UserDefaults.standard.bool(forKey: Key.keepAwake) }
        set {
            guard newValue != keepAwake else { return }
            UserDefaults.standard.set(newValue, forKey: Key.keepAwake)
            NotificationCenter.default.post(name: didChangeNotification,
                                            object: nil,
                                            userInfo: [changedKeyKey: Key.keepAwake])
        }
    }

    /// 极简模式：Touch Bar 只显示「状态摘要 + 语音」，隐藏任务条与统计。
    ///
    /// - Note: 默认 `false`（完整视图）。用户已习惯当前布局，
    ///   改默认值等于替他做了一次无声的界面变更。
    static var minimalMode: Bool {
        get { UserDefaults.standard.bool(forKey: Key.minimalMode) }
        set {
            guard newValue != minimalMode else { return }
            UserDefaults.standard.set(newValue, forKey: Key.minimalMode)
            NotificationCenter.default.post(name: didChangeNotification,
                                            object: nil,
                                            userInfo: [changedKeyKey: Key.minimalMode])
        }
    }

    /// Touch Bar 布局：显示 / 隐藏 + 顺序（宽度不放开，task 仍固定 200pt）。
    ///
    /// - Important: **get 必须容错**。手改 UserDefaults / 旧版本残留 / 半写入都可能让
    ///   数组缺 id、重复 id 或带未知 id；此时回退默认值，保证 bar 永远有完整四项。
    ///   只做「集合恰好等于四个合法 id 且无重复」这一条校验，顺序与 enabled 原样保留。
    static var layoutOrder: [LayoutItem] {
        get {
            guard let data = UserDefaults.standard.data(forKey: Key.layoutOrder),
                  let decoded = try? JSONDecoder().decode([LayoutItem].self, from: data),
                  Set(decoded.map(\.id)) == layoutItemIDs,
                  decoded.count == layoutItemIDs.count else {
                return defaultLayoutOrder
            }
            return decoded
        }
        set {
            guard newValue != layoutOrder else { return }
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: Key.layoutOrder)
            }
            NotificationCenter.default.post(name: didChangeNotification,
                                            object: nil,
                                            userInfo: [changedKeyKey: Key.layoutOrder])
        }
    }
}

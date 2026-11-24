import Foundation

/// 权限确认弹窗里的一项权限。
///
/// - Note: `label` 一律是**从 AX 读到的真实标签**（文件操作 / 终端命令 / 访问互联网），
///   不允许为了界面对齐而编造文案 —— 用户要点的东西必须和 WorkBuddy 界面上的勾选项同名。
struct PermissionItem: Equatable {
    /// 真实标签（来自 checkbox 的可读文本）。
    let label: String
    /// 当前是否已勾选。
    let granted: Bool

    init(label: String, granted: Bool) {
        self.label = label
        self.granted = granted
    }
}

/// 从弹窗快照里识别出的「允许完全访问」请求。
struct PermissionRequest: Equatable {
    /// 弹窗标题（拿不到时用 `PermissionParser.fallbackTitle`）。
    let title: String
    /// 权限项（最多 `PermissionParser.maxItems` 项，保持界面上的原始顺序）。
    let items: [PermissionItem]

    init(title: String, items: [PermissionItem]) {
        self.title = title
        self.items = items
    }
}

/// 「允许完全访问」弹窗的识别与展示文案（全部是纯函数，可单测）。
///
/// 为什么要把识别单独抽出来：真实的权限弹窗**无法主动触发** —— 只有 WorkBuddy 真的
/// 要读文件 / 跑命令 / 联网时才会弹。也就是说整条链路上，除了这里的判定与文案裁剪，
/// 其余部分都无法在单测里验证。既然如此，就把能确定的逻辑全部挤进这个纯函数里，
/// 用构造数据把规则钉死；AX 那一侧只留最少量的胶水。
enum PermissionParser {

    /// 标题缺失时的兜底文案。
    static let fallbackTitle = "允许完全访问"

    /// 最多识别几项权限。
    ///
    /// 依据：真机弹窗只有三样（文件操作 / 终端命令 / 访问互联网），而 Touch Bar 可用宽度
    /// 约 290pt，一个权限按钮约 62pt —— 3 个正好，第 4 个开始必然挤掉「返回」。
    static let maxItems = 3

    /// 权限按钮标签的默认截断长度（字符数）。
    ///
    /// 5 个字是有依据的取舍：真实标签最长的是「访问互联网」（5 字），
    /// 截到 5 就无需截断；再长就必须出 `…`，否则一行放不下 3 个按钮。
    static let labelLimit = 5

    /// 主按钮语义（按文本匹配 WorkBuddy 的按钮，见 `matchOption(_:in:)`）。
    static let allowLabel = "允许"
    /// 次按钮语义。
    static let cancelLabel = "取消"

    /// 从 checkbox 候选里判断是不是权限弹窗，并组装请求。
    ///
    /// 判定规则（顺序即优先级）：
    /// 1. `label` 为空白 → 丢弃该项（读不到标签的勾选框没法给用户看，更没法回点）；
    /// 2. 清洗后不足 2 项 → 返回 nil。
    ///    **这一条是刻意保守**：单个 checkbox 在普通页面里到处都是（「记住我的选择」
    ///    「不再提示」），把它们当成权限弹窗会让 Touch Bar 在毫无风险的时刻突然换成
    ///    「允许 / 取消」两个按钮 —— 用户一旦误触就是替 WorkBuddy 授权。宁可漏识别
    ///    （退回原有的按钮铺排），也不能误识别。
    /// 3. 多于 `maxItems` 项 → 只取前 3 项（宽度只够 3 个）；
    /// 4. `title` 为空白 → `fallbackTitle`。
    ///
    /// - Parameters:
    ///   - title: 弹窗标题（可为 nil / 空白 / 已带前导空格）。
    ///   - checkboxes: 遍历顺序的勾选框（标签可为空白，会被丢弃）。
    ///   - fallbackTitle: 标题缺失时使用；若它本身也是空白，退回 `fallbackTitle` 常量。
    /// - Returns: 识别成功返回请求；不构成权限弹窗返回 nil。
    static func parse(title: String?,
                      checkboxes: [(label: String, granted: Bool)],
                      fallbackTitle: String) -> PermissionRequest? {
        // 先清洗再数数：空白标签的勾选框既不能显示也不能回点，
        // 计入数量只会让「≥2」这条门槛失效。
        var items: [PermissionItem] = []
        for checkbox in checkboxes {
            let label = checkbox.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty else { continue }
            items.append(PermissionItem(label: label, granted: checkbox.granted))
            if items.count >= maxItems { break }
        }

        // 保守门槛，见上面规则 2 的说明。
        guard items.count >= 2 else { return nil }

        let rawTitle = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let rawFallback = fallbackTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle: String
        if !rawTitle.isEmpty {
            resolvedTitle = rawTitle
        } else if !rawFallback.isEmpty {
            resolvedTitle = rawFallback
        } else {
            // 调用方传了空兜底也要有东西上屏（标题为空时 Touch Bar 上会是一块空白按钮）。
            resolvedTitle = Self.fallbackTitle
        }

        return PermissionRequest(title: resolvedTitle, items: items)
    }

    /// Touch Bar 上单个权限按钮的文案：勾选态前缀 + 截断标签。
    ///
    /// - Parameters:
    ///   - item: 权限项。
    ///   - labelLimit: 标签最多保留几个字符，超出加 `…`。
    /// - Returns: 形如 `✅ 文件操作` / `☐ 终端命令`。
    /// - Note: 勾选态用 `✅` / `☐` 两个字符表达，而不是靠颜色 —— Touch Bar 上颜色信息
    ///   在强光/斜视角下不可靠，字形本身才是一眼可辨的。
    static func itemTitle(_ item: PermissionItem, labelLimit: Int = PermissionParser.labelLimit) -> String {
        let mark = item.granted ? "✅ " : "☐ "
        let label = truncate(item.label, limit: labelLimit)
        // 标签被清洗后为空（理论上 parse 已丢弃）时给个占位，避免按钮变成只有前缀。
        return mark + (label.isEmpty ? "—" : label)
    }

    /// 按字符数截断，超出部分用单个 `…` 表示。
    ///
    /// - Note: 用 `…`（一个字符）而不是 `...`（三个字符）：Touch Bar 上每个字符都要算宽度，
    ///   省略号的三种写法里只有单字符版本不额外吃掉 2 个字符的位置。
    /// - Parameters:
    ///   - label: 原始标签。
    ///   - limit: 保留字符数；`<= 0` 时不做截断。
    /// - Returns: 截断后的标签（已去掉首尾空白）。
    static func truncate(_ label: String, limit: Int) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard limit > 0, trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "…"
    }

    /// 在弹窗选项里找语义等价的按钮文本（先精确相等，再退化为包含）。
    ///
    /// 为什么需要：`DialogDetector.pressOption` 只按**精确文本**在已铺出的选项里匹配，
    /// 而真实界面上的主按钮常带装饰（「允许 ✓」「取消 (Esc)」）。若直接传「允许」，
    /// 一旦界面文案不是干净的两个字，这一步就会失败 —— 而失败的表现只是「点了没反应」。
    ///
    /// - Parameters:
    ///   - target: 语义标签（如「允许」）。
    ///   - options: 当前弹窗的按钮文本（遍历顺序）。
    /// - Returns: 可直接交给 `pressOption` 的真实文本；找不到返回 nil。
    static func matchOption(_ target: String, in options: [String]) -> String? {
        let wanted = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return nil }
        if let exact = options.first(where: { $0 == wanted }) { return exact }
        return options.first(where: { $0.contains(wanted) })
    }
}

import Foundation

/// 读出「用户在 WorkBuddy 界面里选中了哪个会话」。
///
/// ## 数据源（AX 只读）
/// WorkBuddy 是 Electron。侧边栏每个会话是一个 `AXButton`，其 `AXDOMClassList` 里
/// **当前选中的那一个**带 `_selected_xxx` 类名（实测如 `_selected_1ufy3_20`），
/// 未选中的没有。取该按钮的 `AXTitle` 即选中会话标题。
///
/// - Note: 侧边栏 title 常带时间尾巴（「… 1分钟前」/「… 刚刚」），
///   匹配任务时先由 `primaryTitle(from:)` 去掉尾巴，再做双向包含。
/// - Important: 纯只读：不写 AX、不点击、不弹窗。AX 遍历本身有唤醒开销，
///   由调用方放在后台队列，并与已有遍历合并（见 `TurnDurationReader.read()`）。
enum SelectedSessionReader {

    /// `_selected_` 类名判定。兼容 `AXDOMClassList` 的两种可能形态：空格分隔的字符串 / 字符串数组。
    static func isSelected(_ classList: Any?) -> Bool {
        if let text = classList as? String {
            return text.contains("_selected_")
        }
        if let list = classList as? [String] {
            return list.contains { $0.contains("_selected_") }
        }
        return false
    }

    /// 去掉侧边栏标题尾部的时间词，取出主标题。
    ///
    /// 例：`"为 WorkBuddy Touchbar 应用设计图标 1分钟前"` → `"为 WorkBuddy Touchbar 应用设计图标"`。
    /// 解析失败（空串 / 去掉尾巴后为空）返回 nil，绝不把噪音当标题。
    static func primaryTitle(from raw: String?) -> String? {
        guard let raw = raw else { return nil }
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let pattern = #"(刚刚|\d+\s*(秒|分钟|分|小时|天|周|个月|年)前|昨天|前天)$"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let ns = text as NSString
            if let match = regex.firstMatch(in: text,
                                            range: NSRange(location: 0, length: ns.length)) {
                text = String(ns.substring(to: match.range.location))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return text.isEmpty ? nil : text
    }

    /// 任务标题与 AX 选中标题是否指同一个会话（双向包含，容忍一侧多出前缀 / 后缀）。
    static func matches(taskTitle: String, selectedTitle: String) -> Bool {
        guard let a = primaryTitle(from: taskTitle),
              let b = primaryTitle(from: selectedTitle) else { return false }
        return a.contains(b) || b.contains(a)
    }
}

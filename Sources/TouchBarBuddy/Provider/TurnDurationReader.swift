import Foundation
import ApplicationServices
import AppKit

/// 读取 WorkBuddy 自己显示的「本轮耗时」。
///
/// ## 为什么不用自己算
/// 用户给截图明确指出要 Touch Bar 显示 WorkBuddy 界面上的那个值
/// （助手消息下方的 `已处理 1m8s` / `已完成 15m42s`）。
/// 数据库的 `created_at` / `updated_at` 都算不出这个数：
/// 前者是会话行创建时间，后者每次输出都刷新；待办步骤里也没有轮次时间戳。
/// 所以只能读界面文本 —— 这也是**唯一**一个我们只读不写的 AX 数据点。
///
/// ## 为什么只读「已处理」
/// `已完成 15m42s` 是**上一轮**的耗时。当前正在跑的那一轮会显示 `已处理 …`，
/// 两者同时存在于树里。取错会显示一个停在原地的旧数字。
enum TurnDurationReader {

    /// 一趟 AX 遍历读到的全部数据（三者在同一次遍历、同一时刻取得）。
    struct Reading {
        let seconds: TimeInterval?
        let credits: Double?
        /// 侧边栏当前选中会话的主标题（已去掉「N分钟前」尾巴）；读不到为 nil。
        let selectedSessionTitle: String?
    }

    /// 把 WorkBuddy 的耗时文案解析成秒。
    ///
    /// 接受 `1m8s` / `15m42s` / `1h2m3s` / `42s`（也接受带 `已处理 ` 前缀的整句）。
    /// - Returns: 秒数；格式不对返回 nil，绝不把解析失败当成 0。
    static func parse(_ text: String) -> TimeInterval? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.hasSuffix("s"),
              let regex = try? NSRegularExpression(pattern: #"(\d+)([hms])"#) else { return nil }

        var hours = 0, minutes = 0, seconds = 0, matched = false
        let ns = cleaned as NSString
        for match in regex.matches(in: cleaned, range: NSRange(location: 0, length: ns.length)) {
            guard match.numberOfRanges == 3 else { continue }
            let number = ns.substring(with: match.range(at: 1))
            let unit = ns.substring(with: match.range(at: 2))
            guard let value = Int(number) else { continue }
            switch unit {
            case "h": hours = value
            case "m": minutes = value
            case "s": seconds = value
            default: continue
            }
            matched = true
        }
        guard matched, hours >= 0, minutes >= 0, seconds >= 0 else { return nil }
        return TimeInterval(hours * 3600 + minutes * 60 + seconds)
    }

    /// 从按 AX 遍历顺序排列的「已处理」候选中挑当前轮耗时。
    ///
    /// - Important: 取**第一个**（遍历中最先遇到的），不是最后一个。
    ///   真机实测 AX 里「已处理 25s」当前轮排在前面，「已处理 8m34s」历史轮排在后面；
    ///   历史那条恒定不动，当前那条随秒增长。取最后会把旧轮次的耗时当成当前轮的。
    ///   这一条与积分的取值方向**相反**（积分取最后），切勿统一成一个规则。
    ///
    /// - Parameter candidates: 按 AX 遍历顺序收集的「已处理 X」原文。
    /// - Returns: 第一个解析成功的秒数；全失败时 nil。
    static func currentTurnSeconds(from candidates: [String]) -> TimeInterval? {
        for text in candidates where text.hasPrefix("已处理 ") {
            if let seconds = parse(text) { return seconds }
        }
        return nil
    }

    /// 把积分值格式化成 Touch Bar 文案：`◇ 10.56`（与 WorkBuddy 一致，保留 2 位小数）。
    ///
    /// - 0 / nil / 非有限值 → nil（不显示「◇ 0.00」，那是噪音）。
    /// - 用 `◇` 这个字符还原 WorkBuddy 界面上的菱形图标。
    static func formatCredits(_ value: Double?) -> String? {
        guard let value = value, value.isFinite, value > 0 else { return nil }
        return "◇ " + String(format: "%.2f", value)
    }

    /// 一趟遍历同时取「已处理 X」的秒数、本轮已消耗积分与侧边栏选中会话标题。
    ///
    /// 合并的原因：三者都在同一棵 AX 树里，分开遍历等于把 0.12s 的成本付两遍，
    /// 而它们本来就该在同一时刻被读到（同一条消息的「已处理 3m1s」与「已消耗 ◇ 252.49」）。
    ///
    /// - Important: 调用方必须在**后台队列**调用（同步遍历，真机约 0.12s）。
    static func read() -> Reading {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName == "WorkBuddy" || $0.bundleIdentifier?.contains("workbuddy") == true
        }) else { return Reading(seconds: nil, credits: nil, selectedSessionTitle: nil) }

        let root = AXUIElementCreateApplication(app.processIdentifier)
        var queue: [AXUIElement] = [root]
        var visited = 0
        // 时长先收集全部候选再取第一个（当前轮），不要边遍历边覆盖。
        var durationCandidates: [String] = []
        var credits: Double?
        var selectedTitle: String?
        // 上限保护：界面异常时不要让一次遍历卡住后台队列。
        while !queue.isEmpty, visited < 3000 {
            let element = queue.removeFirst()
            visited += 1

            // 侧边栏选中会话：AXButton + AXDOMClassList 含 `_selected_` → 取 AXTitle。
            // 与时长 / 积分共用这一趟遍历，不额外唤醒 AX。
            if selectedTitle == nil {
                var roleValue: CFTypeRef?
                if AXUIElementCopyAttributeValue(element,
                                                 kAXRoleAttribute as CFString,
                                                 &roleValue) == .success,
                   (roleValue as? String) == "AXButton" {
                    var classValue: CFTypeRef?
                    if AXUIElementCopyAttributeValue(element,
                                                     "AXDOMClassList" as CFString,
                                                     &classValue) == .success,
                       SelectedSessionReader.isSelected(classValue) {
                        var titleValue: CFTypeRef?
                        if AXUIElementCopyAttributeValue(element,
                                                         kAXTitleAttribute as CFString,
                                                         &titleValue) == .success {
                            selectedTitle = SelectedSessionReader.primaryTitle(from: titleValue as? String)
                        }
                    }
                }
            }

            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
               let text = value as? String {
                if text.hasPrefix("已处理 ") {
                    // 先收集，遍历结束后由 currentTurnSeconds 取第一个（当前轮）。
                    // 与积分相反：积分取最后，时长取第一，切勿统一。
                    durationCandidates.append(text)
                } else if text == "已消耗" {
                    // - Important: **不要遇到第一个就返回**。历史消息里每一轮都有「已消耗」，
                    //   消息列表按时间顺序排列（旧 → 新），第一个是几条消息前的旧值。
                    //   实测取第一个读到 946.39，而界面此刻已经是 1103.5。
                    //   一直覆盖下去，最后留下的才是最新那条消息的值。
                    if let number = siblingNumber(of: element) {
                        credits = number
                    }
                }
            }
            var childrenValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(element,
                                             kAXChildrenAttribute as CFString,
                                             &childrenValue) == .success,
               let children = childrenValue as? [AXUIElement] {
                queue.append(contentsOf: children)
            }
        }
        return Reading(seconds: currentTurnSeconds(from: durationCandidates),
                       credits: credits,
                       selectedSessionTitle: selectedTitle)
    }

    /// 取 AX 元素后面第一个「纯数字」兄弟节点的值。
    ///
    /// - 真机结构：`已消耗` 与数值是同一父节点下的相邻 `AXStaticText`。
    /// - Returns: 解析出的数值；没有 / 不是数字时 nil。
    private static func siblingNumber(of element: AXUIElement) -> Double? {
        var parentValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element,
                                            kAXParentAttribute as CFString,
                                            &parentValue) == .success,
              let parent = parentValue else { return nil }
        let parentElement = unsafeBitCast(parent, to: AXUIElement.self)

        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parentElement,
                                            kAXChildrenAttribute as CFString,
                                            &childrenValue) == .success,
              let siblings = childrenValue as? [AXUIElement] else { return nil }

        // 用 CFEqual 找自己：AXUIElement 是 CF 类型，`===` 不可靠。
        guard var index = siblings.firstIndex(where: { CFEqual($0, element) }) else { return nil }
        index += 1
        guard index < siblings.count else { return nil }

        var nextValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(siblings[index],
                                            kAXValueAttribute as CFString,
                                            &nextValue) == .success,
              let text = nextValue as? String else { return nil }
        return Double(text.trimmingCharacters(in: .whitespaces))
    }
}

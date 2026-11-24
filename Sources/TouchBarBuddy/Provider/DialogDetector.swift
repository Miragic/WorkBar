import AppKit
import ApplicationServices
import Foundation

/// 一个 WorkBuddy 弹层的快照：标题 + 可直接点选的选项。
///
/// 来源是真机的「成长计划」弹层：
/// ```
/// AX[117] d10 AXGroup/AXApplicationDialog :: 成长计划
/// AX[124] d17 AXButton :: 关闭
/// AX[125] d17 AXButton :: 奖品
/// AX[215] d17 AXButton :: 抽奖(0)
/// ```
struct DialogSnapshot: Equatable {
    /// 弹层标题（拿不到时用 `DialogDetector.fallbackTitle`）。
    let title: String
    /// 可点选项文本（按遍历顺序，最多 3 个，已去重去空）。
    let options: [String]
    /// 识别到的「允许完全访问」权限请求；不是权限弹窗时为 nil。
    ///
    /// - Note: 默认 nil，这样既有构造点（含 27 个单测）不用改一行。
    let permissions: PermissionRequest?

    init(title: String, options: [String], permissions: PermissionRequest? = nil) {
        self.title = title
        self.options = options
        self.permissions = permissions
    }
}

/// 弹层检测与点选。
///
/// 目的：WorkBuddy 弹出的选择层（成长计划 / 抽奖 / 确认框）原本必须切到窗口里用鼠标点，
/// 本类型把它「铺」到 Touch Bar 上，点一下等于点那个按钮。
///
/// 三条安全/正确性约束：
/// 1. **只认三种弹层容器**（subrole `AXApplicationDialog` / role `AXSheet` / role `AXDialog`），
///    否则会把普通页面里的 `AXButton` 全铺出来；
/// 2. **命中安全黑名单直接放弃整个弹层**（退出登录 / 关机 / 删除账号 …）——
///    Touch Bar 是电容触摸，误触代价极高，宁可不提供也不能误按；
/// 3. **按压前必须重新检测**：AX 元素会随界面刷新立即失效，缓存 `AXUIElement` 只会按空。
///
/// - Note: 所有方法内部都有 AX 遍历（最长 `AXTraversal.maxDuration`），
///   **必须在后台队列调用**，不要在主线程序列上跑。
enum DialogDetector {

    // MARK: - 常量

    /// 最多铺几个选项（Touch Bar 宽度有限，3 个已是上限）。
    static let optionLimit = 3

    /// 选择框的按钮数上限：**超过即视为内容页**，整个弹层不铺到 Touch Bar。
    ///
    /// 语义不是「UI 细节」而是**产品判据**：真正需要用户做决策的弹窗（权限确认、
    /// 危险操作确认）按钮数一定落在 2~4；13 个按钮的成长计划/活动页是导航，
    /// 铺到 Touch Bar 上既无用又占满整条 bar。
    ///
    /// - Note: 支持 `TB_DIALOG_MAX_BUTTONS` 覆盖，仅用于在内容页上验证「铺出选项 +
    ///   按压生效」这条链路（真机上唯一能稳定复现的多按钮弹层就是成长计划）。
    ///   生产默认 4。
    static let maxChoiceButtons: Int = parsedMaxChoiceButtons(
        ProcessInfo.processInfo.environment["TB_DIALOG_MAX_BUTTONS"]
    )

    /// 阈值默认值（生产值）。
    static let defaultMaxChoiceButtons = 4

    /// 解析阈值：非数字 / 非正数 / 空串一律回落到默认值。
    ///
    /// - Parameter raw: 环境变量原文（可为 nil）。
    /// - Returns: 可用的阈值。
    static func parsedMaxChoiceButtons(_ raw: String?) -> Int {
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty,
              let value = Int(text),
              value > 0 else {
            return defaultMaxChoiceButtons
        }
        return value
    }

    /// 标题缺失时的兜底文案（不允许出现空标题项）。
    static let fallbackTitle = "待选择"

    /// 标题在 Touch Bar 上的截断长度（超过则加 `…`）。
    static let titleDisplayLimit = 8

    static let buttonRole = "AXButton"
    static let headingRole = "AXHeading"
    static let staticTextRole = "AXStaticText"

    /// 勾选框角色：权限弹窗的「文件操作 / 终端命令 / 访问互联网」都是它。
    static let checkboxRole = "AXCheckBox"

    /// V9 原文采样的去重键：同一个权限标题只记一次，避免 5 秒轮询刷屏。
    private static var lastSampledPermissionTitle: String?

    /// 弹层容器的**子角色**（真机实测就长在 `AXGroup` 上）。
    static let dialogSubrole = "AXApplicationDialog"

    /// 弹层容器的**角色**（除 subrole 之外的两种标准写法）。
    static let dialogRoles: Set<String> = ["AXSheet", "AXDialog"]

    /// 可能携带 `AXApplicationDialog` 子角色的容器角色。
    ///
    /// 只对这些角色读 subrole：整棵树 1000+ 节点，给每个叶子都多读一次 subrole
    /// 会白花上百毫秒，而 dialog 子角色不可能出现在文本/按钮这类叶子上。
    static let subroleCarrierRoles: Set<String> = ["AXGroup", "AXWindow", "AXSheet", "AXDialog", "AXUnknown"]

    /// 最多试几个 dialog 候选（Chromium 会把已关闭弹层的空壳留在树里）。
    static let maxDialogCandidates = 8

    /// 安全黑名单：任意按钮文本**包含**其中一项，整个弹层都不铺到 Touch Bar。
    ///
    /// - Note: 用 `contains` 而不是相等：真实文案常带修饰（「确认退出登录」「立即注销」），
    ///   按相等判断会漏。
    static let dangerOptions = ["退出登录", "关机", "重新启动", "强制退出", "删除账号", "注销"]

    /// `TB_DIALOG_DUMP=1` 时每次检测都打印命中的标题与选项。
    static let dumpEnabled: Bool = {
        guard let raw = ProcessInfo.processInfo.environment["TB_DIALOG_DUMP"] else { return false }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value == "1" || value == "true" || value == "yes"
    }()

    // MARK: - 对外入口

    /// 检测当前是否有可铺到 Touch Bar 的弹层。
    ///
    /// - Returns: 命中且安全时返回快照；没有弹层 / 未授权 / 命中黑名单返回 nil。
    /// - Note: 同步阻塞（含 0.3s AX 唤醒 + 最长 2.5s 遍历），**必须在后台队列调用**。
    static func detect() -> DialogSnapshot? {
        locate()?.snapshot
    }

    /// 点击弹层里文本等于 `label` 的按钮。
    ///
    /// 流程：**重新检测**（绝不复用上次的元素）→ 在快照里确认该选项仍然存在 →
    /// 找到同文本的 `AXButton` → `AXPress`。
    ///
    /// - Parameter label: 要点的按钮文本（铺到 Touch Bar 上的那一串）。
    /// - Returns: 按压成功 `true`；弹层消失 / 选项不在 / 按压失败 `false`（调用方必须给出可见提示）。
    static func pressOption(_ label: String) -> Bool {
        let target = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else {
            tbLog("[TB] 弹层按压跳过：选项文本为空")
            return false
        }

        guard let located = locate() else {
            tbLog("[TB] 弹层按压失败：当前没有可识别的弹层（或命中安全黑名单）")
            return false
        }

        // 只允许按快照里真实铺出去的选项：避免按到被截断掉的第 4 个按钮、
        // 或按到界面上存在但没展示给用户的隐藏按钮。
        guard located.snapshot.options.contains(target) else {
            tbLog("[TB] 弹层按压失败：选项里没有「\(target)」"
                   + "（当前：\(located.snapshot.options.joined(separator: "/"))）")
            return false
        }

        guard let match = matchButton(target, in: located.buttons) else {
            tbLog("[TB] 弹层按压失败：没找到文本为「\(target)」的按钮元素")
            return false
        }

        let error = AXUIElementPerformAction(match.element, kAXPressAction as CFString)
        guard error == .success else {
            tbLog("[TB] 弹层按压失败：AXPress err=\(error.rawValue)（\(match.text)）")
            return false
        }
        tbLog("[TB] 弹层按压命中：\(match.text) -> ok")
        return true
    }

    /// 点击权限弹窗里标签等于 `label` 的**勾选框**（切换该项的勾选态）。
    ///
    /// - Parameter label: 勾选框的真实标签（如「终端命令」）。
    /// - Returns: 按压成功 `true`；弹层消失 / 不是权限弹窗 / 找不到该项 / 按压失败 `false`。
    /// - Note: **绝不复用缓存的 `AXUIElement`**，每次重新 `locate()` —— 弹层每次重绘都会
    ///   让旧元素失效，缓存后按下去是静默失败（这个坑在本项目已经踩过一次）。
    /// - Note: 调用方必须**重新读取**勾选态，不能本地翻转：真实状态以 WorkBuddy 为准，
    ///   本地翻转会让界面显示「已勾」而实际没勾（反过来一样）。
    static func pressCheckbox(_ label: String) -> Bool {
        let target = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else {
            tbLog("[TB] 勾选框按压跳过：标签为空")
            return false
        }

        guard let located = locate() else {
            tbLog("[TB] 勾选框按压失败：当前没有可识别的弹层（或命中安全黑名单）")
            return false
        }

        // 只在**识别成权限弹窗**的弹层上按勾选框：
        // 普通页面里也有勾选框（「记住我的选择」），那类不该被 Touch Bar 点到。
        guard let permissions = located.snapshot.permissions else {
            tbLog("[TB] 勾选框按压失败：当前弹层不是权限弹窗")
            return false
        }

        // 只允许按**真实铺出去**的那几项（最多 3 项），不要按到没显示给用户的第 4 项。
        guard permissions.items.contains(where: { $0.label == target }) else {
            tbLog("[TB] 勾选框按压失败：权限项里没有「\(target)」"
                   + "（当前：\(permissions.items.map { $0.label }.joined(separator: "/"))）")
            return false
        }

        guard let match = matchCheckbox(target, in: located.checkboxes) else {
            tbLog("[TB] 勾选框按压失败：没找到文本为「\(target)」的 AXCheckBox 元素")
            return false
        }

        let error = AXUIElementPerformAction(match.element, kAXPressAction as CFString)
        guard error == .success else {
            tbLog("[TB] 勾选框按压失败：AXPress err=\(error.rawValue)（\(match.text)）")
            return false
        }
        tbLog("[TB] 勾选框按压命中：\(match.text) -> ok")
        return true
    }

    // MARK: - 纯函数：快照构建（可单测）

    /// 由「标题 + 按钮文本列表」构建快照，负责去空、去重、截断与安全黑名单。
    ///
    /// 规则（顺序即优先级）：
    /// 1. 按钮文本 trim 后为空 → 丢弃；
    /// 2. **任一**按钮文本包含黑名单词 → 返回 nil（整个弹层不铺）；
    /// 3. 重复文本只保留第一次出现的；
    /// 4. 最多取前 `optionLimit` 个；
    /// 5. 一个有效按钮都没有 → nil；
    /// 6. 标题为空 → `fallbackTitle`；过长 → 截断加 `…`。
    ///
    /// - Parameters:
    ///   - title: 弹层标题（可为 nil）。
    ///   - buttons: 遍历顺序的按钮文本（允许含空串与重复）。
    ///   - checkboxes: 遍历顺序的勾选框（默认空 —— 既有调用点与 27 个单测都不传它）。
    /// - Returns: 可展示的快照；不安全或不构成弹层时 nil。
    static func buildSnapshot(title: String?,
                              buttons: [String],
                              checkboxes: [(label: String, granted: Bool)] = []) -> DialogSnapshot? {
        // 只读取样（V9 前置调研）：在任何过滤/阈值判定**之前**把 AX 读到的原文写进日志。
        // 用途是确认真实权限弹窗里到底有没有「文件路径 / 命令 / 域名」可供 V9 做文案模板。
        // - Important: 必须放在最前面 —— 超过按钮阈值或命中黑名单的弹窗会提前 return，
        //   只记最终快照会恰好漏掉最值得研究的那一类。
        // - Note: 只在 `TB_DEBUG=1` 时输出，生产默认无额外开销、不改变任何判定与交互。
        let rawButtons = buttons.joined(separator: " / ")
        let rawCheckboxes = checkboxes.map { item in
            item.label + (item.granted ? "=✓" : "=☐")
        }.joined(separator: " / ")
        tbDebugLog("[TB] 弹层原文采样：title=\(title ?? "<nil>") buttons=[\(rawButtons)] checkboxes=[\(rawCheckboxes)]")

        // 先做全量清洗（去空白项），注意这里**还没有**做占位过滤 ——
        // 按钮数阈值必须按「去掉空文本后的原始 AXButton 数」判断，见下面的说明。
        var cleaned: [String] = []
        for raw in buttons {
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            cleaned.append(text)
        }

        // 判据一：**按钮数超过阈值 = 内容页，不是选择框**。
        //
        // 为什么需要这条（真机依据）：成长计划弹层里有 13 个 `AXButton`
        // （关闭/奖品/查看活动规则/兑换奖励/全年活跃记录/…/抽奖(0)/…），
        // 那是活动页的导航，不是「需要用户做决策」的弹窗。需求 ③ 只该处理
        // 权限确认、危险操作确认这类按钮数 2~4 的框 —— 把 13 个导航按钮铺到
        // Touch Bar 上既没用又占满整条 bar。
        //
        // - Note: 位置必须在占位过滤**之前**，且用原始数量：内容页按钮多，
        //   即便过滤掉纯数字也还是多；用原始数更不容易把「刚好 4 个真按钮 +
        //   一堆空白」的选择框误判成内容页（空白已在上面剔除）。
        guard cleaned.count <= maxChoiceButtons else {
            tbLog("[TB] 弹层候选按钮数 \(cleaned.count) 超过阈值 \(maxChoiceButtons)，视为内容页，忽略")
            return nil
        }

        // 判据二：安全黑名单（对**全部**按钮生效，不能只看会铺出去的前 3 个）。
        if let danger = cleaned.first(where: containsDanger) {
            tbLog("[TB] 弹层检测：命中安全黑名单（\(danger)），整个弹层不铺到 Touch Bar")
            return nil
        }

        // 判据三：占位/编号按钮不参与铺出（纯数字格子编号、超长说明句）。
        let meaningful = cleaned.filter { !isPlaceholderOption($0) }

        var seen = Set<String>()
        var options: [String] = []
        for text in meaningful {
            guard seen.insert(text).inserted else { continue }
            options.append(text)
            if options.count >= optionLimit { break }
        }

        // 0 个有效按钮 => 不是可点弹层。
        // 这条同时兜住「空壳弹层」：弹层关掉后 Chromium 会留下一个只剩标题、
        // 0 个按钮的 `AXApplicationDialog`，绝不能因为「0 ≤ 阈值」就当成合法选择框。
        guard !options.isEmpty else { return nil }

        let rawTitle = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // 截断只在「上屏」时做（见 `displayTitle`），快照里保留完整标题，
        // 免得日志/后续逻辑里看不出弹层到底是什么。
        let resolvedTitle = rawTitle.isEmpty ? fallbackTitle : rawTitle

        // 权限识别：注意传的是**原始标题**而不是 `resolvedTitle`。
        // 因为权限弹窗标题缺失时要用「允许完全访问」，若先被兜底成「待选择」，
        // 屏 1 的标题就会变成「🙋 待选择」—— 用户完全不知道自己在授权什么。
        let permissions = PermissionParser.parse(title: title,
                                                 checkboxes: checkboxes,
                                                 fallbackTitle: PermissionParser.fallbackTitle)

        // V9 前置调研：权限弹窗**无条件**采样一次（每个标题只记一次，避免轮询每 5 秒刷屏）。
        // 普通弹层仍只在 TB_DEBUG=1 时记，见函数开头的 debug 版采样。权限弹窗很少出现，
        // 且它是 V9 唯一需要真实文本的对象，所以值得落进默认日志，用户不必改启动方式。
        if permissions == nil {
            Self.lastSampledPermissionTitle = nil
        } else if let title = permissions?.title, title != Self.lastSampledPermissionTitle {
            Self.lastSampledPermissionTitle = title
            tbLog("[TB] 权限弹窗原文采样：title=\(rawTitle) buttons=[\(rawButtons)] checkboxes=[\(rawCheckboxes)]")
        }

        return DialogSnapshot(title: resolvedTitle, options: options, permissions: permissions)
    }

    /// Touch Bar 上展示的标题文案（超长截断加 `…`）。纯函数，便于单测。
    static func displayTitle(_ title: String, limit: Int = titleDisplayLimit) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallbackTitle }
        guard limit > 0, trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "…"
    }

    // MARK: - 检测实现

    /// 检测结果：快照 + 与快照选项对应的按钮元素（按压时要元素，展示时只要文本）+ 勾选框元素。
    struct Located {
        let snapshot: DialogSnapshot
        let buttons: [(text: String, element: AXUIElement)]
        /// 勾选框（文本可能为空串，由 `PermissionParser` 决定要不要用）。
        var checkboxes: [(text: String, granted: Bool, element: AXUIElement)] = []
    }

    /// 真正干活的地方：唤醒 AX → 找弹层容器 → 采集标题与按钮 → 构建快照。
    static func locate() -> Located? {
        guard AXIsProcessTrusted() else {
            tbDebugLog("[TB] 弹层检测跳过：未授权辅助功能")
            return nil
        }
        // 仅测试用：把 AX 检测目标改到指定 PID，用来在真机上验证「弹层原文采样」。
        // 生产不设这个变量时行为完全不变（仍只检测 WorkBuddy）。
        let forcedPID = ProcessInfo.processInfo.environment["TB_DIALOG_APP_PID"]
            .flatMap(Int32.init)
        let pid: pid_t
        if let forcedPID, forcedPID > 0 {
            pid = forcedPID
            tbDebugLog("[TB] 弹层检测目标被测试钩子覆盖：pid=\(forcedPID)")
        } else {
            guard let runningPID = AppActivation.runningApplication()?.processIdentifier else {
                tbDebugLog("[TB] 弹层检测跳过：WorkBuddy 未在运行")
                return nil
            }
            pid = runningPID
        }

        let app = AXUIElementCreateApplication(pid)
        // 必须唤醒：Chromium/Electron 不唤醒根本不构建 web 内容 AX 树，
        // 弹层永远检测不到（未唤醒时只能看到菜单栏那 143 个节点）。
        AXTraversal.enableWebAccessibility(on: app)
        if AXTraversal.webAXWarmup > 0 {
            Thread.sleep(forTimeInterval: AXTraversal.webAXWarmup)
        }

        let start = DispatchTime.now().uptimeNanoseconds
        let dialogs = findDialogs(in: app, start: start)
        guard !dialogs.isEmpty else {
            tbDebugLog("[TB] 弹层检测：当前没有弹层")
            return nil
        }

        // 关键：**逐个候选试**，而不是「拿到第一个 dialog 容器就算命中」。
        // 真机实测：弹层被关掉后，Chromium 会把那个 `AXGroup/AXApplicationDialog`
        // 空壳留在树里（只剩标题、没有按钮）。只看第一个会永远误判成「有弹层但没按钮」，
        // 而真正的弹层可能是后面那个候选。
        for (index, dialog) in dialogs.enumerated() {
            let collected = collect(from: dialog, start: start)
            let buttonTexts = collected.buttons.map { $0.text }
            let checkboxPairs = collected.checkboxes.map { (label: $0.text, granted: $0.granted) }
            guard let snapshot = buildSnapshot(title: collected.title,
                                              buttons: buttonTexts,
                                              checkboxes: checkboxPairs) else {
                if dumpEnabled {
                    tbLog("[TB] 弹层候选 #\(index + 1)/\(dialogs.count) 不可铺"
                           + "（标题=\(collected.title ?? "nil") 按钮数=\(buttonTexts.count)"
                           + " 勾选框数=\(checkboxPairs.count)）")
                    if buttonTexts.isEmpty && index == 0 {
                        // 排障：把候选子树原样打出来，用于确认按钮挂在哪个角色/哪一层下。
                        dumpSubtree(dialog)
                    }
                }
                continue
            }

            if dumpEnabled {
                tbLog("[TB] ---- 弹层检测 命中（候选 #\(index + 1)/\(dialogs.count)）----")
                tbLog("[TB] 弹层 title=\(snapshot.title)")
                tbLog("[TB] 弹层 按钮(原始 \(buttonTexts.count) 个)=\(buttonTexts.joined(separator: " | "))")
                tbLog("[TB] 弹层 options=\(snapshot.options.joined(separator: " | "))")
                let checkboxTexts = collected.checkboxes.map {
                    "\($0.text.isEmpty ? "?" : $0.text)=\($0.granted ? "✓" : "☐")"
                }
                tbLog("[TB] 弹层 勾选框(\(checkboxTexts.count) 个)=\(checkboxTexts.joined(separator: " | "))")
                if let permissions = snapshot.permissions {
                    tbLog("[TB] 权限弹窗：title=\(permissions.title) items="
                           + permissions.items.map { "\($0.label)/\($0.granted)" }.joined(separator: " | "))
                }
            }
            return Located(snapshot: snapshot,
                           buttons: collected.buttons,
                           checkboxes: collected.checkboxes)
        }

        tbDebugLog("[TB] 弹层检测：\(dialogs.count) 个 dialog 容器都不构成可点弹层")
        return nil
    }

    /// 深度优先收集所有弹层容器（subrole `AXApplicationDialog` 或 role `AXSheet`/`AXDialog`）。
    ///
    /// - Note: 为什么是「所有」而不是「第一个」：Chromium 会把已关闭弹层的空壳留在树里，
    ///   第一个候选经常是空壳；必须逐个验证内容才能找到真正在显示的那个。
    /// - Note: 上限 `maxDialogCandidates` 防止异常树里出现几十个容器把预算耗光。
    private static func findDialogs(in app: AXUIElement, start: UInt64) -> [AXUIElement] {
        var result: [AXUIElement] = []
        var stack: [(element: AXUIElement, depth: Int)] = [(app, 0)]
        var visited = 0

        while let current = stack.popLast() {
            if AXTraversal.elapsed(since: start) > AXTraversal.maxDuration {
                tbLog("[TB] 弹层检测：AX 遍历超时（>\(AXTraversal.maxDuration)s），放弃本次检测")
                break
            }
            if visited >= AXTraversal.maxNodes {
                tbLog("[TB] 弹层检测：AX 节点数达上限 \(AXTraversal.maxNodes)，放弃本次检测")
                break
            }
            if result.count >= maxDialogCandidates { break }
            visited += 1

            let role = AXTraversal.role(of: current.element)
            var isDialog = dialogRoles.contains(role)
            if !isDialog, subroleCarrierRoles.contains(role),
               AXTraversal.subrole(of: current.element) == dialogSubrole {
                isDialog = true
            }
            if isDialog {
                tbDebugLog("[TB] 弹层候选 #\(result.count + 1)：role=\(role) 深度=\(current.depth)")
                result.append(current.element)
            }

            guard current.depth < AXTraversal.maxDepth else { continue }
            // ⚠️ 不要改成 `.reversed()`。正序入栈 + `popLast` 才是界面上从上到下的顺序。
            //
            // 原因：Chromium 的 `AXChildren` 是**自下而上**返回的（真机实测），
            // 于是「正序入栈、后进先出」正好抵消，得到文档顺序（关闭 / 奖品 / … 在最前）。
            // 曾经按直觉写成 `.reversed()` 入栈，结果选项整体倒过来（`查看活动规则` 跑到第一），
            // 两种写法都用真机日志验证过，这里才是对的那一种。
            for child in AXTraversal.children(of: current.element) {
                stack.append((child, current.depth + 1))
            }
        }
        return result
    }

    /// 在弹层子树里采集标题、所有 `AXButton` 与所有 `AXCheckBox`。
    ///
    /// 标题优先级：弹层自身文本 → 第一个 `AXHeading` → 第一个 `AXStaticText`。
    /// （真机上标题就在弹层容器的 description 里：`AXGroup/AXApplicationDialog :: 成长计划`。）
    ///
    /// - Important: checkbox **绝不混进 `buttons` 数组**。`buttons` 的数量参与
    ///   `buildSnapshot` 里的 `maxChoiceButtons = 4` 判据（那是「内容页 vs 选择框」的分界），
    ///   而 `options` 的语义是「可点的决策按钮」。把 3 个权限勾选框塞进去会让
    ///   权限弹窗（2 按钮 + 3 勾选）自己顶到 5 个，被误判成内容页，整条链路直接失效。
    private static func collect(from dialog: AXUIElement,
                                start: UInt64) -> (title: String?,
                                                   buttons: [(text: String, element: AXUIElement)],
                                                   checkboxes: [(text: String, granted: Bool, element: AXUIElement)]) {
        // 弹层自身的文本：title / description / value 依次尝试。
        let rootTitle = textLike(of: dialog)

        var stack: [(element: AXUIElement, depth: Int)] = [(dialog, 0)]
        var visited = 0
        var buttons: [(text: String, element: AXUIElement)] = []
        var checkboxes: [(text: String, granted: Bool, element: AXUIElement)] = []
        var headingTitle: String?
        var staticTextTitle: String?

        while let current = stack.popLast() {
            if AXTraversal.elapsed(since: start) > AXTraversal.maxDuration {
                tbLog("[TB] 弹层采集超时，使用已收集到的 \(buttons.count) 个按钮、"
                       + "\(checkboxes.count) 个勾选框")
                break
            }
            if visited >= AXTraversal.maxNodes {
                tbLog("[TB] 弹层采集节点数达上限，使用已收集到的 \(buttons.count) 个按钮、"
                       + "\(checkboxes.count) 个勾选框")
                break
            }
            visited += 1

            switch AXTraversal.role(of: current.element) {
            case buttonRole:
                // 这里**不做**占位过滤：按钮数阈值必须按原始 `AXButton` 数量判断
                // （见 `buildSnapshot`），过滤统一放在那里，避免两处判据打架。
                if let text = buttonText(of: current.element) {
                    buttons.append((text: text, element: current.element))
                }
            case checkboxRole:
                // 标签读不到也照样收集（label 为一）—— 让 `PermissionParser` 统一负责
                // 「丢弃空标签、丢弃后不足两项就放弃」的判定，避免判定逻辑散落两处。
                checkboxes.append((text: textLike(of: current.element) ?? "",
                                   granted: checkboxGranted(current.element),
                                   element: current.element))
            case headingRole:
                if headingTitle == nil { headingTitle = textLike(of: current.element) }
            case staticTextRole:
                if staticTextTitle == nil { staticTextTitle = textLike(of: current.element) }
            default:
                break
            }

            guard current.depth < AXTraversal.maxDepth else { continue }
            // 同 `findDialogs`：正序入栈 + `popLast` 才与界面顺序一致（见那里的说明）。
            for child in AXTraversal.children(of: current.element) {
                stack.append((child, current.depth + 1))
            }
        }

        let title = [rootTitle, headingTitle, staticTextTitle].compactMap { $0 }.first
        return (title, buttons, checkboxes)
    }

    /// 读勾选框的勾选态。
    ///
    /// - Note: 两套来源都要试 —— 标准 AppKit 勾选框把状态放在 `kAXValueAttribute`（0/1），
    ///   而 Chromium 的 web 勾选框有时**只**更新 `AXSelected`。任一为真即算勾选：
    ///   这里宁可判成「已勾」（界面会显示 ✅，用户点一下就能核对）也不要误判成「未勾」
    ///   而让用户以为没授权成功。
    /// - Parameter element: 勾选框元素。
    /// - Returns: 是否已勾选。
    static func checkboxGranted(_ element: AXUIElement) -> Bool {
        if let number = AXTraversal.copyAttribute(element, kAXValueAttribute) as? NSNumber {
            return number.intValue != 0
        }
        if let selected = AXTraversal.copyAttribute(element, kAXSelectedAttribute) as? NSNumber {
            return selected.boolValue
        }
        return false
    }

    /// 按钮文本优先级：`description` → `title` → `value`。
    ///
    /// - Note: 顺序与 `AXTraversal.strings(of:)` 不同（它先 value）——
    ///   这里要的是「人看到的标签」，Chromium 里按钮的可读文案通常在 description/title 上。
    private static func buttonText(of element: AXUIElement) -> String? {
        for attribute in [kAXDescriptionAttribute, kAXTitleAttribute, kAXValueAttribute] {
            if let text = AXTraversal.text(element, attribute) { return text }
        }
        return nil
    }

    /// 通用文本优先级：`title` → `description` → `value`（用于标题）。
    private static func textLike(of element: AXUIElement) -> String? {
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
            if let text = AXTraversal.text(element, attribute) { return text }
        }
        return nil
    }

    /// 在采集到的按钮里找文本匹配项：先精确相等，再退化为包含。
    ///
    /// - Note: 包含匹配是为了容忍真实界面文案里的尾部装饰（如「关闭 ✕」），
    ///   但**只在快照确认过的选项之间**找，不会跨到别的按钮。
    private static func matchButton(_ label: String,
                                    in buttons: [(text: String, element: AXUIElement)]) -> (text: String, element: AXUIElement)? {
        if let exact = buttons.first(where: { $0.text == label }) { return exact }
        return buttons.first(where: { $0.text.contains(label) })
    }

    /// 在采集到的勾选框里找标签匹配项：先精确相等，再退化为包含。
    ///
    /// 与 `matchButton` 同规则，但**只在勾选框里匹配** —— 混着找会按到同名按钮
    /// （比如勾选框叫「文件操作」而旁边有个「查看文件操作说明」的按钮）。
    private static func matchCheckbox(_ label: String,
                                      in checkboxes: [(text: String, granted: Bool, element: AXUIElement)])
        -> (text: String, element: AXUIElement)? {
        if let exact = checkboxes.first(where: { $0.text == label }) {
            return (text: exact.text, element: exact.element)
        }
        guard let loose = checkboxes.first(where: { $0.text.contains(label) }) else { return nil }
        return (text: loose.text, element: loose.element)
    }

    /// 按钮文本是否是「占位/编号」而非真正可选项（在 `buildSnapshot` 里过滤）。
    ///
    /// 真机「成长计划」弹层里除导航按钮外还有 `15` `14` `9` `8` `7` `1` 这类抽奖格子编号 ——
    /// 它们能被点，但把 `15` 铺到 Touch Bar 上对用户毫无意义，还会挤掉真正的选项。
    /// 规则刻意保守：只排除「纯数字」与「超长文本」，不做语义猜测。
    static func isPlaceholderOption(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        if trimmed.allSatisfy({ $0.isNumber || $0 == " " }) { return true }
        return trimmed.count > optionTextMaxLength
    }

    /// 选项文本长度上限（超过视为说明性长句，不是按钮标签）。
    static let optionTextMaxLength = 16

    /// 文本是否命中安全黑名单。
    static func containsDanger(_ text: String) -> Bool {
        dangerOptions.contains { text.contains($0) }
    }

    // MARK: - 排障

    /// 把弹层子树（角色 + 文本）原样打印，最多 80 行。
    ///
    /// 只在 `TB_DIALOG_DUMP=1` 且「弹层存在但一个按钮都没采到」时调用 ——
    /// 这是排查「按钮明明在界面上，AX 里却取不到」的唯一有效手段
    /// （Chromium 的子节点可能只挂在 `AXVisibleChildren` 上）。
    private static func dumpSubtree(_ dialog: AXUIElement) {
        let start = DispatchTime.now().uptimeNanoseconds
        var stack: [(element: AXUIElement, depth: Int)] = [(dialog, 0)]
        var printed = 0
        tbLog("[TB] ---- 弹层子树转储 开始 ----")
        while let current = stack.popLast() {
            if printed >= 80 || AXTraversal.elapsed(since: start) > AXTraversal.maxDuration {
                tbLog("[TB] ---- 弹层子树转储 截断（已打印 \(printed) 行）----")
                break
            }
            printed += 1
            let role = AXTraversal.role(of: current.element)
            let subrole = AXTraversal.subrole(of: current.element)
            var texts: [String] = []
            for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
                if let text = AXTraversal.text(current.element, attribute) { texts.append(text) }
            }
            let body = texts.isEmpty ? "" : " :: " + texts.joined(separator: " | ")
            let childCount = AXTraversal.children(of: current.element).count
            let visibleCount = (AXTraversal.copyAttribute(current.element, kAXVisibleChildrenAttribute) as? [Any])?.count ?? -1
            tbLog("[TB] dlg d\(current.depth) \(role.isEmpty ? "?" : role)"
                   + (subrole.isEmpty ? "" : "/\(subrole)")
                   + " children=\(childCount) visible=\(visibleCount)\(body)")
            guard current.depth < AXTraversal.maxDepth + 6 else { continue }
            for child in AXTraversal.children(of: current.element) {
                stack.append((child, current.depth + 1))
            }
        }
        tbLog("[TB] ---- 弹层子树转储 结束 ----")
    }
}

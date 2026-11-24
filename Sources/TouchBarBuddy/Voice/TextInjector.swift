import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// 文字注入结果。
///
/// - `ok == true`：注入流程已走完，剪贴板 → ⌘V 已发出。
/// - `ok == false`：**没有**可信地填入（未授权 / 进程不在 / 找不到输入框 / 粘贴未生效），
///   调用方必须把 `reason` 显式报给用户，不允许静默吞掉。
/// - `reason` 在 `ok == true` 时也可能非空 —— 那表示「填入了，但有降级情况」
///   （例如等不到 WorkBuddy 成为前台、或无法回读校验）。
struct InjectResult: Equatable {
    let ok: Bool
    let reason: String?

    init(ok: Bool, reason: String? = nil) {
        self.ok = ok
        self.reason = reason
    }
}

/// 把一段文字填进 WorkBuddy 的输入框（语音识别结果的落地环节）。
///
/// 为什么需要它：点 Touch Bar 语音按钮时，前台可能是终端 / 访达，
/// 旧实现直接写剪贴板 + ⌘V，文字就粘到那个 app 里去了。所以正确顺序是：
/// **授权检查 → 激活 WorkBuddy → 确认它真的是前台 → 聚焦输入框 → 光标移到末尾
/// → 剪贴板 + ⌘V → 回读校验**。
///
/// - Note: 写入手段**只有**粘贴这一条。`AXUIElementSetAttributeValue(kAXValueAttribute)`
///   在 Chromium 里可能返回 success 但界面不更新 —— 那是「看起来成功」的静默失败，
///   而粘贴是肉眼可验证的。故本类型不提供 AX 写值路径。
///
/// - Important: `insert` 是**阻塞**的（最长约 4s，含前台等待、AX 遍历、粘贴后回读与重试），
///   必须在后台队列调用。它阻塞住在主线程的话 Touch Bar 会僵住。
enum TextInjector {

    /// 多行输入框角色（WorkBuddy 聊天输入框实测是 `AXTextArea`）。
    static let textAreaRole = "AXTextArea"

    /// 单行输入框角色（兜底：搜索框 / 标题输入）。
    static let textFieldRole = "AXTextField"

    /// 视为「可输入元素」的角色集合。
    static let inputRoles: Set<String> = [textAreaRole, textFieldRole]

    /// 物理键码：`V`（用于投递 ⌘V）。
    private static let keyCodeV: CGKeyCode = 0x09

    /// 物理键码：`↓`（用于投递 ⌘↓，把插入点送到内容末尾）。
    private static let keyCodeDownArrow: CGKeyCode = 0x7D

    /// 粘贴后**保持剪贴板内容**的时长（秒），此后才恢复用户原剪贴板。
    ///
    /// - Important: 这里踩过坑。原来是 0.15s，实测太短：
    ///   ⌘V 是经 `cghidEventTap` 异步投递的，Electron 还要跨进程把快捷键事件转成
    ///   渲染进程的 paste 处理，再回头读剪贴板；等它读的时候我们已经把剪贴板清空/还原，
    ///   于是它粘到的是**旧内容或空内容** —— 表现就是「说了话，输入框什么都没多」。
    ///   0.6s 是留足余量又不至于明显侵占用户剪贴板的折中。
    static let pasteboardHoldDelay: TimeInterval = 0.6

    /// 粘贴后等待「目标 app 真正把内容写进输入框」的时长（秒）。
    static let verifyDelay: TimeInterval = 0.45

    /// 兜底「⌘↓」投递后等待目标 app 处理按键的时长（秒）。
    ///
    /// - Note: 与 `pasteboardHoldDelay` 同理，按键是经 `cghidEventTap` 异步投递的，
    ///   Chromium 还要跨进程把它转成渲染进程的 `move caret to end`，立刻回读只会读到旧值。
    static let caretEndKeyDelay: TimeInterval = 0.08

    /// 光标未确认到末尾 / 长度校验判定疑似覆盖时的短提示（会显示在 Touch Bar 上）。
    ///
    /// - Important: Touch Bar 可用宽度约 290pt，**必须控制在 24 个汉字以内**，
    ///   否则后面的按钮会被挤出可见区。当前 23 字，只剩 1 字余量。
    static let appendUnconfirmedReason = "已填入，但光标未能移到末尾，可能覆盖了原有内容"

    /// 候选节点数量上限（与 `maxNodes` 分开：我们只需要找输入框）。
    static let maxCandidates = 2000

    /// 最多铺几个输入框候选（用于日志与选择，不会真的全部尝试）。
    static let maxInputCandidates = 8

    // MARK: - 对外入口

    /// 把文字填进目标 app 的输入框。
    ///
    /// 步骤（顺序不可换）：
    /// 1. 空文本直接返回失败（没有写入的意义）；
    /// 2. `AXIsProcessTrusted()`：没授权时 CGEvent 会被系统丢弃，必须提前报失败；
    /// 3. 激活目标 app；
    /// 4. 轮询等待它成为 `frontmostApplication`（最多 1.5s，等不到也继续并标注）；
    /// 5. AX 聚焦输入框（已有焦点就用它，否则在子树里找）；
    /// 6. **光标移到内容末尾**（⌘V 作用于当前选区，光标落在选区上就是覆盖）；
    /// 7. 剪贴板写入 + ⌘V，保持 0.6s；
    /// 8. **回读输入框内容校验是否真的落进去了 / 是追加还是覆盖**，没落就重试一次。
    ///
    /// - Parameters:
    ///   - text: 要填入的文字。
    ///   - bundleID: 目标 app，默认 WorkBuddy。
    /// - Returns: 注入结果（失败时 `reason` 必须被调用方展示）。
    /// - Note: 阻塞调用，必须在后台队列执行。
    static func insert(_ text: String, bundleID: String = AppActivation.workBuddyBundleID) -> InjectResult {
        guard !text.isEmpty else {
            tbLog("[TB] 注入跳过：识别结果为空")
            return InjectResult(ok: false, reason: "识别结果为空，未填入")
        }

        tbLog("[TB] 注入开始：\(text.count) 字 → \(bundleID)")

        // 无「辅助功能」权限时 CGEvent 键盘事件会被系统直接丢弃 → 表现为静默粘贴失败。
        // - Note: 这里最常见的坑不是「用户没开开关」，而是**开关看着是开的、授权其实已失效**：
        //   TCC 记录若绑定的是旧构建的 cdhash（早先自签证书尚未被系统认可为有效签名身份时，
        //   记录按 cdhash 精确匹配），重编后 cdhash 变了、记录不匹配，但设置里那一行仍显示为开。
        //   故 reason 明确提示「重新授权」，而不是笼统的「需授权」——后者会让用户去检查一个
        //   本来就显示为开的开关，白转一圈。
        // - Important: `reason` 会显示在 Touch Bar 上，可用宽度约 290pt，**控制在 24 个汉字内**，
        //   否则后面的按钮会被挤出可见区。
        guard AXIsProcessTrusted() else {
            tbLog("[TB] 注入失败：AXIsProcessTrusted()=false（CGEvent 会被系统丢弃；"
                  + "设置里开关显示为开也可能是绑定了旧 cdhash 的失效记录）")
            return InjectResult(ok: false,
                                reason: "授权已失效，请重新授权（开关为开可能是旧记录）")
        }

        guard AppActivation.activate(bundleID: bundleID) else {
            return InjectResult(ok: false, reason: "WorkBuddy 未在运行，无法填入")
        }

        // 等前台切换完成。等不到**不放弃**：还是往下走（用户可能刚切回来），
        // 但把这件事记进 reason，让 Touch Bar 能给出可见提示。
        var warning: String?
        if AppActivation.waitUntilFrontmost(bundleID: bundleID) {
            tbLog("[TB] 注入前已确认 WorkBuddy 为前台")
        } else {
            let current = AppActivation.frontmostName()
            let currentID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
            warning = "WorkBuddy 未在 \(Int(AppActivation.waitTimeout))s 内成为前台（当前：\(current)），已尝试直接填入"
            tbLog("[TB] 前台等待超时：期望 \(bundleID)，实际 \(currentID)（\(current)）")
        }

        guard let pid = AppActivation.runningApplication(bundleID: bundleID)?.processIdentifier else {
            return InjectResult(ok: false, reason: "WorkBuddy 进程已退出，无法填入")
        }

        let start = DispatchTime.now().uptimeNanoseconds
        guard let target = resolveInput(pid: pid, start: start) else {
            // 找不到输入框时仍然发一次 ⌘V（Chromium 偶尔不暴露输入区，但焦点可能已在里面），
            // 但结果报 fail：宁可弹出「没找到输入框」，也不要让用户以为粘上了其实没粘。
            tbLog("[TB] 注入降级：未找到输入框节点，盲发一次 ⌘V")
            paste(text)
            return InjectResult(ok: false, reason: "没找到 WorkBuddy 的输入框")
        }

        // 第一次尝试：聚焦 → 光标到末尾 → 粘贴 → 回读。
        let first = attemptPaste(text: text, target: target, pid: pid, hold: pasteboardHoldDelay)
        if first.ok {
            // - Important: 必须把 attemptPaste 自己的 reason 带上（「光标没到末尾 / 疑似覆盖」），
            //   否则那条警告会被这里的 overall `warning` 顶掉，Touch Bar 上永远看不到。
            return InjectResult(ok: true, reason: first.reason ?? warning)
        }

        // 重试前再确认一次：如果其实已经写进去了（只是回读对象/时序抖动），
        // 绝不能再粘第二遍 —— 那会造成用户真机看到的「你好你好」。
        if let current = freshValueText(pid: pid), current.contains(text) {
            tbLog("[TB] 重试前复查：文字其实已经写入，放弃重试（避免重复粘贴）")
            return InjectResult(ok: true, reason: warning)
        }

        // 第二次尝试：重新聚焦再粘一次（有时首帧 AXPress 还没把焦点交出去）。
        tbLog("[TB] 注入第 1 次未生效（\(first.reason ?? "未知")），重试一次")
        let second = attemptPaste(text: text, target: target, pid: pid, hold: pasteboardHoldDelay + 0.4)
        if second.ok {
            return InjectResult(ok: true,
                                reason: second.reason ?? warning ?? "首次粘贴未生效，重试后填入")
        }

        return InjectResult(ok: false, reason: second.reason ?? "粘贴未生效（输入框内容没有变化）")
    }

    // MARK: - 单次粘贴 + 回读校验

    /// 一次「聚焦 → 光标到末尾 → 粘贴 → 回读校验」。
    ///
    /// - Returns: `ok == true` 表示确认写入了（或无法回读、只能按已发出处理）。
    private static func attemptPaste(text: String,
                                     target: InputTarget,
                                     pid: pid_t,
                                     hold: TimeInterval) -> InjectResult {
        // - Important: 写入目标**必须是遍历挑出来的那个聊天输入框**，绝不能「当前焦点是谁就写谁」。
        //   2026-11-19 真机 bug：用户焦点停在 README 预览面板时，内容被写进了 README —
        //   因为上一版为了拿到「未过期的 AX 引用」而盲信 `kAXFocusedUIElement`。
        //   现在的规则：按下目标 → 校验焦点确实落在它身上 → 才信焦点；否则退回目标本身。
        if !press(target.element) {
            tbLog("[TB] 输入框聚焦失败（AXPress / AXFocused 均未成功），仍尝试粘贴")
        }
        let writeTarget: AXUIElement
        if let focused = focusedInputElement(pid: pid),
           isSameElement(focused, target.element) {
            // 焦点确实在目标输入框上，用它（引用最新，回读最准）。
            writeTarget = focused
        } else {
            // 焦点没交出去（或被别的面板占着）：坚持写目标输入框，绝不写到当前焦点上。
            tbLog("[TB] 焦点未落在目标输入框，仍按目标写入（不跟随当前焦点）")
            writeTarget = target.element
        }

        // 粘贴前先记下「即将写入的那个元素」的内容，粘贴后与它比较才有意义。
        let focusedBefore = valueText(of: writeTarget)

        // 光标先移到末尾：⌘V 作用于**当前选区**，光标若落在一个有内容的选区上（尤其全选 /
        // 用户上次是「全选后替换」），粘贴就是覆盖。实测故障就是这样：原有 27 字被 6 字替换。
        // - Note: 失败**不阻断**粘贴 —— 用户宁可文字覆盖，也不要「点了说话什么都没发生」。
        //   但要把这件事塞进 reason，让 Touch Bar 上看得见。
        let caretAtEnd = moveCaretToEnd(writeTarget)
        if !caretAtEnd {
            tbLog("[TB] 光标未能确认在末尾，仍继续粘贴（可能覆盖原有内容）")
        }

        // 比较基准用「即将写入的那个元素」的粘贴前内容（与回读同源，才不会苹果比橘子）。
        let before = focusedBefore ?? valueText(of: writeTarget)
        let beforeLen = contentLength(of: before)
        let roleName = CFEqual(writeTarget, target.element) ? target.role : "目标元素"
        tbLog("[TB] 粘贴前输入框内容长度=\(beforeLen) role=\(roleName) depth=\(target.depth)")

        paste(text, hold: hold)

        // 给目标 app 时间把内容真正写进 DOM。
        wait(verifyDelay)

        // 回读：优先读「当前焦点」——但**只有当焦点仍是我们的写入目标时**才信它。
        // 2026-11-19 两次真机 bug 的平衡点：
        //   · 只读旧引用 → 引用过期，内容恒为 1 字，误判失败 → 重试 → 「你好你好」；
        //   · 只读当前焦点 → 焦点在 README 面板时会读到 README，误判成功或写错地方。
        // 所以：焦点 == 目标 → 读焦点（最新）；否则读目标本身。
        let focusedNow = focusedInputElement(pid: pid)
        let focusedMatchesTarget = focusedNow.map { isSameElement($0, writeTarget) } ?? false
        let after: String?
        if focusedMatchesTarget, let focusedNow = focusedNow {
            after = valueText(of: focusedNow) ?? valueText(of: writeTarget)
        } else {
            after = valueText(of: writeTarget)
        }
        guard let after = after else {
            tbLog("[TB] 无法回读输入框内容（AXValue 不可读），按「已发出 ⌘V」处理")
            return InjectResult(ok: true,
                                reason: caretAtEnd ? "无法回读校验，请确认输入框"
                                                   : appendUnconfirmedReason)
        }

        let afterLen = contentLength(of: after)
        let textLen = (text as NSString).length
        tbLog("[TB] 粘贴后输入框内容长度=\(afterLen)")

        // 追加校验：光标确实在末尾时，粘贴只会让内容变长，长度应约等于 before + text；
        // 明显短了就是有内容被覆盖了。这一步是「追加是否真成立」的唯一客观证据，
        // 光看「回读包含原文」是不够的 —— 覆盖时原文照样在（原内容前缀 + 新文字）。
        var overwriteSuspected = !caretAtEnd
        if beforeLen >= 0 {
            let appended = isAppendSatisfied(beforeLength: beforeLen,
                                             afterLength: afterLen,
                                             textLength: textLen)
            tbLog("[TB] 追加校验：before=\(beforeLen) after=\(afterLen) text=\(textLen) "
                  + "判定=\(appended ? "追加成立" : "疑似覆盖")")
            if !appended { overwriteSuspected = true }
        } else {
            tbLog("[TB] 追加校验：粘贴前长度不可读，跳过判定 "
                  + "（before=-1 after=\(afterLen) text=\(textLen)）")
        }
        let overwriteWarning: String? = overwriteSuspected ? appendUnconfirmedReason : nil

        if after.contains(text) {
            tbLog("[TB] 回读校验通过：文字已确认落入输入框")
            return InjectResult(ok: true, reason: overwriteWarning)
        }
        if let before = before, after == before {
            tbLog("[TB] 回读校验失败：输入框内容没有变化")
            return InjectResult(ok: false, reason: "粘贴未生效（输入框内容没有变化）")
        }
        // 内容变了但没包含原文（自动纠错 / 丢了标点 / 只进了部分），仍算成功。
        tbLog("[TB] 回读校验：内容有变化但未精确包含原文，按成功处理")
        return InjectResult(ok: true, reason: overwriteWarning ?? "内容有变化，但未精确匹配原文")
    }

    // MARK: - 输入框选择（纯函数，便于单测）

    /// 从「遍历顺序的（角色, 深度）」里挑出该当作输入框的那个下标。
    ///
    /// 规则（顺序即优先级）：
    /// 1. 优先 `AXTextArea`（WorkBuddy 的聊天输入框就是它）；
    /// 2. 没有 `AXTextArea` 时退回第一个 `AXTextField`；
    /// 3. 两者都没有 → nil（不要在按钮 / 正文节点上乱按）。
    ///
    /// - Parameter candidates: 按遍历顺序排列的候选节点。
    /// - Returns: 被选中候选的下标；没有可输入元素时为 nil。
    /// 从真正遍历到的元素里挑「可编辑且内容最短」的输入框。
    ///
    /// 为什么不能只按角色挑：2026-11-19 真机实测，WorkBuddy 页面里
    /// **第一个 AXTextArea 是 7382 字的对话历史区**（只读），真正的聊天输入框排在后面。
    /// 只按「第一个 AXTextArea」会在长度校验上「看起来成功」（历史区长度也会涨），
    /// 用户却看到输入框是空的 —— 这是最难排查的一类静默错位。
    ///
    /// 判据（优先级从高到低）：
    /// 1. `AXEditable == true` 且内容最短（聊天输入框通常为空或只有几个字）；
    /// 2. 没有可编辑标记时，退回「角色是 AXTextArea/AXTextField 且内容最短」；
    /// 3. 都不可读 → nil，交给兜底规则。
    ///
    /// - Parameter candidates: 按遍历顺序排列的（角色, 深度）。
    /// - Parameter elements: 与 `candidates` 同序的 AX 元素。
    /// - Returns: 被选中候选的下标；没有合适元素时为 nil。
    static func pickEditableInput(candidates: [(role: String, depth: Int)],
                                  elements: [AXUIElement]) -> Int? {
        guard candidates.count == elements.count else { return nil }

        var bestIndex: Int?
        var bestLength = Int.max
        var bestEditable = false
        var bestY = -CGFloat.greatestFiniteMagnitude

        for (index, candidate) in candidates.enumerated() {
            guard candidate.depth >= 0 else { continue }
            guard inputRoles.contains(candidate.role) else { continue }

            let element = elements[index]
            let editable = (AXTraversal.copyAttribute(element, "AXEditable") as? Bool) ?? false
            let length = contentLength(of: valueText(of: element))
            // 只读且内容很长 → 几乎必然是对话历史区，直接跳过。
            if !editable, length > Self.readOnlyHistoryThreshold {
                tbDebugLog("[TB] 注入：跳过疑似历史区 role=\(candidate.role) len=\(length) editable=\(editable)")
                continue
            }

            // 位置：聊天输入框通常在窗口**底部**（macOS 屏幕坐标 y 向下增大）。
            // 这是排除「侧边面板 / 顶部搜索框」最稳的一条 —— 它们同样可编辑、同样短。
            let y = frameOriginY(of: element)

            // 排序优先级：可编辑 > 更靠下 > 内容更短。
            let better: Bool
            if editable != bestEditable {
                better = editable
            } else if abs(y - bestY) > 8 {
                better = y > bestY
            } else {
                better = length < bestLength
            }
            if better {
                bestIndex = index
                bestLength = length
                bestEditable = editable
                bestY = y
                tbDebugLog("[TB] 注入：候选 role=\(candidate.role) editable=\(editable) len=\(length) y=\(Int(y))")
            }
        }
        return bestIndex
    }

    /// 「只读且长度超过这个值」就当作对话历史区排除（约 200 字，正常输入框远达不到）。
    static let readOnlyHistoryThreshold = 200

    /// 读元素的屏幕位置（AXPosition 的 y）。读不到返回 `-∞`，排序时自然排最后。
    private static func frameOriginY(of element: AXUIElement) -> CGFloat {
        guard let raw = AXTraversal.copyAttribute(element, kAXPositionAttribute),
              CFGetTypeID(raw) == AXValueGetTypeID() else {
            return -CGFloat.greatestFiniteMagnitude
        }
        let axValue = unsafeBitCast(raw, to: AXValue.self)
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else {
            return -CGFloat.greatestFiniteMagnitude
        }
        return point.y
    }

    static func pickInputElement(from candidates: [(role: String, depth: Int)]) -> Int? {
        var textFieldIndex: Int?
        for (index, candidate) in candidates.enumerated() {
            // 负深度没有意义，直接跳过（防御式：避免调用方传错）。
            guard candidate.depth >= 0 else { continue }
            if candidate.role == textAreaRole { return index }
            if candidate.role == textFieldRole, textFieldIndex == nil {
                textFieldIndex = index
            }
        }
        return textFieldIndex
    }

    // MARK: - 光标位置 / 追加校验（纯函数，便于单测）

    /// 内容长度（nil 视为不可读，返回 -1）。
    ///
    /// - Important: 长度**必须**用 `NSString.length`（UTF-16 单位），不能用 `String.count`。
    ///   AX 的 range 偏移是 UTF-16 计量：`"今天多少号"` 两者都是 5，但含 emoji 时
    ///   `count` 会把一个 emoji 算 1、`NSString.length` 算 2（代理对），差一点光标就落不到末尾。
    /// - Parameter value: `kAXValueAttribute` 读到的字符串。
    /// - Returns: UTF-16 长度；`value == nil`（回读不可用）时为 -1。
    /// - Note: 故意不设为 `private` —— 它是「UTF-16 计量」这一约定的唯一实现，
    ///   单测要能直接钉住它（emoji 的代理对是这块最容易算错的地方）。
    static func contentLength(of value: String?) -> Int {
        guard let value = value else { return -1 }
        return (value as NSString).length
    }

    /// 判断一个选区起点是否已经位于内容末尾（用于验证「光标移到末尾」是否真的生效）。
    ///
    /// 规则：`location >= contentLength` 即视为到位。
    /// - 允许**大于**：部分 app 会把插入点钳到合法范围（`length+1` 之类），
    ///   或在末尾追加了换行占位，位置略超也应算到位，不必吹毛求疵；
    /// - 空内容时只接受 0（此时「末尾」唯一）；
    /// - 负数或负的内容长度是异常值，一律不算到位（防御式：宁可走兜底 ⌘↓ 也不要误判成功）。
    ///
    /// - Parameters:
    ///   - location: 回读到的选区起点（UTF-16 偏移）。
    ///   - contentLength: 输入框内容长度（UTF-16，见 `contentLength(of:)`）。
    /// - Returns: 是否已在本内容末尾。
    static func isCaretAtEnd(location: Int, contentLength: Int) -> Bool {
        guard location >= 0, contentLength >= 0 else { return false }
        if contentLength == 0 { return location == 0 }
        return location >= contentLength
    }

    /// 判断粘贴是否构成「追加」（而不是覆盖了原有内容）。
    ///
    /// 依据：光标在末尾时粘贴不替换任何字符，长度应等于 `beforeLength + textLength`。
    /// 实测故障是 `before=27 after=6 text=6` —— 长度反而变短，一眼就是覆盖。
    ///
    /// - Note: 留 `tolerance` 的亏空：app 的自动纠错 / 末尾空白裁剪可能吞掉一两个字，
    ///   卡严格相等会把正常追加误报成覆盖，Touch Bar 上天天弹提示。
    /// - Parameters:
    ///   - beforeLength: 粘贴前长度（UTF-16）。
    ///   - afterLength: 粘贴后长度（UTF-16）。
    ///   - textLength: 粘贴文本长度（UTF-16）。
    /// - Returns: 追加成立返回 true；长度明显短于预期（或被覆盖）返回 false。
    static func isAppendSatisfied(beforeLength: Int, afterLength: Int, textLength: Int) -> Bool {
        guard beforeLength >= 0, afterLength >= 0, textLength > 0 else {
            // 空文本不该走到粘贴；长度不可读（-1）也没有判定依据，按失败处理由调用方决定是否提示。
            return false
        }
        let tolerance = min(2, textLength)
        return afterLength >= beforeLength + textLength - tolerance
    }

    // MARK: - 定位输入框

    /// 定位结果。
    struct InputTarget {
        let element: AXUIElement
        let role: String
        let depth: Int
        /// 是否还需要主动按一下才能拿到焦点（焦点已经在它身上时为 false）。
        let needsPress: Bool
    }

    /// 找到要写入的输入框元素。
    ///
    /// - Note: 优先用 `kAXFocusedUIElement`：用户往往刚在聊天框里打过字，
    ///   直接沿用它最稳，也避免「按一下别的输入框把焦点搬走」。
    private static func resolveInput(pid: pid_t, start: UInt64) -> InputTarget? {
        let app = AXUIElementCreateApplication(pid)

        // 焦点快捷路径默认**关闭**：2026-11-19 真机确认它在「系统模态 bar 持有键盘焦点」
        // 时会拿到一个内容陈旧/不可写的 AXTextArea（日志特征：粘贴前后长度都是 27、
        // depth=-1、⌘V 完全无效）。而 DFS 路径选出的是真正可见的输入框
        // （日志特征：depth=20、内容长度会随粘贴变化）。
        // 需要临时排查时可设 TB_FOCUS_SHORTCUT=1 打开。
        let allowFocusShortcut = ProcessInfo.processInfo.environment["TB_FOCUS_SHORTCUT"] == "1"
        if allowFocusShortcut,
           let raw = AXTraversal.copyAttribute(app, kAXFocusedUIElementAttribute),
           let focused = AXTraversal.asElement(raw) {
            let role = AXTraversal.role(of: focused)
            tbDebugLog("[TB] 当前焦点元素 role=\(role)")
            if inputRoles.contains(role) {
                // - Important: 即使 AX 认为焦点已在输入框，**仍然要按一下**。
                //   这是 2026-11-19 真机定位到的注入失效根因：
                //   本工具的常驻 bar 是**系统模态**的，它会持有键盘焦点；
                //   AX 的「焦点元素」还停在输入框上，但 ⌘V 实际投递到了 Touch Bar，
                //   表现就是「粘贴前后内容长度完全不变」。
                //   执行一次 AXPress 能把键盘焦点真正交还给输入框。
                //   `needsPress=false` 的旧写法只有在 WorkBuddy 自己刚打过字时才成立，不可靠。
                tbLog("[TB] 焦点已在输入框（role=\(role)），仍按一次以夺回键盘焦点")
                return InputTarget(element: focused, role: role, depth: -1, needsPress: true)
            }
        }

        return firstInputElement(in: app, start: start).map { found in
            InputTarget(element: found.element, role: found.role, depth: found.depth, needsPress: true)
        }
    }

    /// DFS 找可输入元素，同时把看到的所有候选打进日志。
    ///
    /// - Note: 深度 / 节点数 / 耗时三重保护沿用 `AXTraversal` 的常量，
    ///   保证「换一个陌生页面也绝不会卡住」。
    private static func firstInputElement(in app: AXUIElement,
                                          start: UInt64) -> (element: AXUIElement, role: String, depth: Int)? {
        var stack: [(element: AXUIElement, depth: Int)] = [(app, 0)]
        var visited = 0
        // 与 `elements` 同序：候选 (role, depth) 及其对应元素。
        var candidates: [(role: String, depth: Int)] = []
        var elements: [AXUIElement] = []

        AXTraversal.enableWebAccessibility(on: app)
        wait(AXTraversal.webAXWarmup)

        while let current = stack.popLast() {
            if AXTraversal.elapsed(since: start) > AXTraversal.maxDuration {
                tbLog("[TB] 注入：AX 遍历超时（>\(AXTraversal.maxDuration)s），放弃寻找输入框")
                break
            }
            if visited >= AXTraversal.maxNodes {
                tbLog("[TB] 注入：AX 节点数达上限 \(AXTraversal.maxNodes)，放弃寻找输入框")
                break
            }
            if candidates.count >= maxCandidates { break }
            visited += 1

            let currentRole = AXTraversal.role(of: current.element)
            if !currentRole.isEmpty {
                candidates.append((role: currentRole, depth: current.depth))
                elements.append(current.element)
                // - Important: 这里**曾经**是「遇到第一个 AXTextArea 就 break」。
                //   2026-11-19 真机踩坑：WorkBuddy 改版后，页面里第一个 AXTextArea 是
                //   **7382 字的对话历史区**（只读大文本），真正的聊天输入框在后面。
                //   于是每轮都把文字粘进历史区，用户看到的是「输入框里什么都没有」，
                //   而回读校验却因为长度涨了 16 而判定成功 —— 静默错位，极难发现。
                //   改为收集全部候选，由 `pickEditableInput` 结合「可编辑 / 内容较短」挑。
            }

            guard current.depth < AXTraversal.maxDepth else { continue }
            for child in AXTraversal.children(of: current.element) {
                stack.append((child, current.depth + 1))
            }
        }

        tbLog("[TB] 注入：遍历 \(visited) 个节点，\(candidates.count) 个带角色")

        // 优先：可编辑 + 内容较短的那个 AXTextArea（真输入框）。
        // 兜底：老的 `pickInputElement`（保持既有单测与行为不变）。
        if let index = pickEditableInput(candidates: candidates, elements: elements) {
            let picked = candidates[index]
            tbLog("[TB] 注入：选中可编辑输入框 role=\(picked.role) depth=\(picked.depth) index=\(index)")
            return (elements[index], picked.role, picked.depth)
        }

        guard let index = pickInputElement(from: candidates), index < elements.count else {
            tbLog("[TB] 注入：未发现 AXTextArea / AXTextField")
            return nil
        }
        let picked = candidates[index]
        tbLog("[TB] 注入：选中输入框（兜底规则）role=\(picked.role) depth=\(picked.depth) index=\(index)")
        return (elements[index], picked.role, picked.depth)
    }

    /// 让元素获得焦点：先 `AXPress`，失败再退回「只设焦点」。
    ///
    /// - Note: 退回路径**只**写 `kAXFocusedAttribute`，绝不写 `kAXValueAttribute` ——
    ///   Chromium 对后者的返回值不可信，会变成静默失败甚至改坏输入框内容。
    @discardableResult
    private static func press(_ element: AXUIElement) -> Bool {
        let error = AXUIElementPerformAction(element, kAXPressAction as CFString)
        if error == .success { return true }
        tbDebugLog("[TB] AXPress 未成功（err=\(error.rawValue)），改用只设焦点")
        let fallback = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        return fallback == .success
    }

    /// 读输入框当前文本（用于粘贴前后对比校验）。
    private static func valueText(of element: AXUIElement) -> String? {
        AXTraversal.copyAttribute(element, kAXValueAttribute) as? String
    }

    /// 读「当前焦点元素」的文本。
    ///
    /// 为什么需要：⌘V 只会落到**当前焦点**，而我们在遍历阶段拿到的 `AXUIElement`
    /// 可能已经过期或指向只读历史区。用焦点元素回读才能真实反映粘贴结果。
    /// - Returns: 焦点元素的文本；焦点不是输入类元素或不可读时为 nil。
    private static func freshValueText(pid: pid_t) -> String? {
        guard let focused = focusedInputElement(pid: pid) else { return nil }
        return valueText(of: focused)
    }

    /// 重新解析「当前真正接收键盘输入的焦点元素」。
    ///
    /// ⌘V 只作用于焦点，而遍历阶段拿到的引用可能已过期或指向只读历史区。
    /// 操作光标、回读校验都必须基于它，否则会出现「粘贴成功了却判失败 → 重试 → 重复粘贴」。
    /// 判断两个 AX 元素是否指向同一个界面元素。
    ///
    /// 用途：`press` 之后要确认「焦点真的落在我们选的那个输入框上」，
    /// 而不是被别的面板（例如 README 预览）占着。只看 role 不够 —— 两个面板都是 AXTextArea。
    private static func isSameElement(_ lhs: AXUIElement, _ rhs: AXUIElement) -> Bool {
        CFEqual(lhs, rhs)
    }

    private static func focusedInputElement(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        guard let raw = AXTraversal.copyAttribute(app, kAXFocusedUIElementAttribute),
              let focused = AXTraversal.asElement(raw) else { return nil }
        let role = AXTraversal.role(of: focused)
        guard inputRoles.contains(role) else { return nil }
        return focused
    }

    /// 读输入框当前选区（`kAXSelectedTextRangeAttribute`）；读不到返回 nil。
    ///
    /// - Note: 必须先校验 `CFTypeID` 再 `unsafeBitCast`。直接 `as? AXValue` 对
    ///   CoreFoundation 类型会被判为「必然成功」（编译告警），且可能拿到非 AXValue 对象崩溃。
    private static func selectedRange(of element: AXUIElement) -> CFRange? {
        guard let raw = AXTraversal.copyAttribute(element, kAXSelectedTextRangeAttribute),
              CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeBitCast(raw, to: AXValue.self)
        var out = CFRange(location: 0, length: 0)
        guard AXValueGetValue(axValue, .cfRange, &out) else { return nil }
        return out
    }

    /// 把光标（插入点）移到输入框内容末尾，返回是否**确认**到位。
    ///
    /// 为什么必须做：⌘V 作用于当前选区。光标若落在一个有内容的选区上（尤其全选），
    /// 粘贴就是**覆盖**。真机日志实证过这个问题：
    /// `粘贴前输入框内容长度=27 / 粘贴后输入框内容长度=6`，用户的 6 字替换掉了原有 27 字。
    ///
    /// 做法（优先 AX 写入，失败再打快捷键）：
    /// 1. 首选写 `kAXSelectedTextRangeAttribute` 为 `(location: length, length: 0)` —— 不模拟按键，
    ///    不抢焦点，最干净；
    /// 2. **但 Chromium 会返回 success 却不生效**（本项目已踩过这个坑），所以必须回读
    ///    `kAXSelectedTextRangeAttribute` 实测位置；
    /// 3. 回读不到位 → 兜底投递一次 ⌘↓（Mac 上「插入点移到末尾」的标准快捷键），
    ///    等 `caretEndKeyDelay` 后再回读一次；
    /// 4. 仍不到位 → 返回 false，由调用方记降级日志但**继续粘贴**。
    ///
    /// - Parameter element: 已聚焦的输入框元素。
    /// - Returns: 是否确认光标已在末尾（内容为空或不可读时返回 true —— 无从覆盖）。
    private static func moveCaretToEnd(_ element: AXUIElement) -> Bool {
        guard let value = valueText(of: element) else {
            // 读不到内容 = 算不出长度，也就无从判断会不会覆盖；按「无内容」放行，
            // 让粘贴照常进行（粘贴后的回读校验还会再兜一次）。
            tbDebugLog("[TB] 光标移末尾：AXValue 不可读，按空内容处理")
            return true
        }

        let length = (value as NSString).length
        guard length > 0 else {
            tbDebugLog("[TB] 光标移末尾：输入框为空，光标天然在末尾")
            return true
        }

        // 首选：AX 写选区。range 的偏移是 UTF-16，故 length 用 NSString.length。
        var range = CFRange(location: length, length: 0)
        if let axValue = AXValueCreate(.cfRange, &range) {
            let error = AXUIElementSetAttributeValue(element,
                                                     kAXSelectedTextRangeAttribute as CFString,
                                                     axValue)
            if error == .success,
               let actual = selectedRange(of: element),
               isCaretAtEnd(location: actual.location, contentLength: length) {
                tbDebugLog("[TB] 光标已到末尾（AX 写入生效）：caret=\(actual.location) len=\(length)")
                return true
            }
            let readBack = selectedRange(of: element).map { "\($0.location)" } ?? "读不到"
            // 「写了但没到位」正是 Chromium 静默失败的典型形态 —— 日志要把它记清楚。
            tbDebugLog("[TB] 光标移末尾：AX 写入 err=\(error.rawValue) 回读 caret=\(readBack) "
                       + "len=\(length)，改走 ⌘↓")
        } else {
            tbDebugLog("[TB] 光标移末尾：AXValueCreate(.cfRange) 失败，改走 ⌘↓")
        }

        // 兜底：⌘↓。与 ⌘V 走同一条 CGEvent 通道。
        postCommandKey(keyCode: keyCodeDownArrow, label: "⌘↓")
        wait(caretEndKeyDelay)

        guard let after = selectedRange(of: element) else {
            tbDebugLog("[TB] 光标移末尾：⌘↓ 后仍回读不到选区，按未确认处理")
            return false
        }
        let reachEnd = isCaretAtEnd(location: after.location, contentLength: length)
        tbDebugLog("[TB] 光标移末尾：⌘↓ 后 caret=\(after.location) len=\(length) 到位=\(reachEnd)")
        return reachEnd
    }

    // MARK: - 剪贴板 + ⌘V

    /// 剪贴板写入 → 模拟 ⌘V → 延迟恢复原剪贴板。
    ///
    /// - Parameters:
    ///   - text: 要粘贴的文字。
    ///   - hold: 保持剪贴板的时长（秒），期间不恢复，保证目标 app 读到的就是我们写的内容。
    /// - Note: 仅保存/恢复纯文本，富文本 / 图片等剪贴板内容会被覆盖（MVP 限制）。
    /// - Note: 恢复时**不再** `clearContents()`。原先那样写在「原剪贴板为空」时会把剪贴板
    ///   清成空，目标 app 若读得稍晚就什么都粘不到。
    private static func paste(_ text: String, hold: TimeInterval = pasteboardHoldDelay) {
        let pasteboard = NSPasteboard.general
        let savedString = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        let wrote = pasteboard.setString(text, forType: .string)
        tbLog("[TB] 剪贴板写入=\(wrote) changeCount=\(pasteboard.changeCount)")
        simulateCommandV()
        tbLog("[TB] 已投递 ⌘V，保持剪贴板 \(String(format: "%.2f", hold))s")

        if Thread.isMainThread {
            DispatchQueue.main.asyncAfter(deadline: .now() + hold) {
                restore(pasteboard: pasteboard, to: savedString)
            }
        } else {
            Thread.sleep(forTimeInterval: hold)
            restore(pasteboard: pasteboard, to: savedString)
        }
    }

    /// 恢复用户原剪贴板：原先有文本才写回，原先为空就保持空 —— 但**绝不**用
    /// `clearContents()` 去「恢复」，那会在竞态里把刚写的内容抹掉。
    private static func restore(pasteboard: NSPasteboard, to saved: String?) {
        pasteboard.clearContents()
        if let saved = saved {
            pasteboard.setString(saved, forType: .string)
        }
        tbDebugLog("[TB] 剪贴板已恢复（原有文本=\(saved != nil)）")
    }

    /// 模拟按下 ⌘V。
    private static func simulateCommandV() {
        postCommandKey(keyCode: keyCodeV, label: "⌘V")
    }

    /// 投递一个「⌘ + 某键」的按下 / 抬起事件。
    ///
    /// 抽成 helper 的唯一理由：⌘V（粘贴）与 ⌘↓（光标到末尾）必须是**完全相同**的投递方式
    /// （同一 `CGEventSource`、同一 `.cghidEventTap`、同样带 `.maskCommand`）。两处各写一份
    /// 必然漂移 —— 之前就出现过「一处忘了设 flags，快捷键变成裸键」这类静默失效。
    ///
    /// - Parameters:
    ///   - keyCode: 物理键码（`CGKeyCode`）。
    ///   - label: 日志里显示的组合键名（如 `"⌘V"`）。
    private static func postCommandKey(keyCode: CGKeyCode, label: String) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            tbLog("[TB] 无法创建 CGEventSource，\(label) 未发出")
            return
        }
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    /// 阻塞等待（主线程上泵 RunLoop，后台线程直接 sleep），避免冻结 Touch Bar。
    private static func wait(_ seconds: TimeInterval) {
        guard Thread.isMainThread else {
            Thread.sleep(forTimeInterval: seconds)
            return
        }
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: deadline)
        }
    }
}

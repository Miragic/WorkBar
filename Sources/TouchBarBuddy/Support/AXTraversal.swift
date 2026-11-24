import ApplicationServices
import Foundation

/// AX 元素读取的共用工具（`copyAttribute` / 子节点 / 角色 / 转换 / 计时 / 遍历上限）。
///
/// 抽出来的原因：`TextInjector` 与 `DialogDetector` 都要遍历 WorkBuddy 的 AX 树，
/// 这类「CFArray → AXUIElement」「读 role」的样板逻辑各写一份必然漂移 ——
/// 比如一处用 `as?` 一处用 `CFGetTypeID` 校验，后者崩前者静默，很难发现。
///
/// - Note: 原先这些常量和 `enableWebAccessibility` 挂在 `AccessibilityReader` 上。
///   该类型（余额 / 成长状态读取）已整体移除 —— 它会按压账号弹窗，属于侵入式操作，
///   产品上决定不再做。现在这里是唯一来源。
enum AXTraversal {

    /// 遍历深度上限。
    ///
    /// - Note: 不能用 14。Electron 的层级是
    ///   `AXApplication(d0) → AXWindow(d1) → AXGroup(d2..d5) → AXWebArea(d6) → AXGroup(d7..d13) → 实际控件(d14+)`，
    ///   深度 14 正好卡在第一个真实控件上。
    static let maxDepth = 40
    /// 遍历节点数上限（防止异常树把进程拖死，正常界面远达不到）。
    static let maxNodes = 15000
    /// 单次遍历总耗时上限（秒）。
    static let maxDuration: TimeInterval = 2.5

    /// 唤醒 web 内容 AX 树后的等待时间（秒）。
    ///
    /// Chromium 收到「增强界面」标志后是**异步**构建 AX 树的，立刻遍历只能拿到旧快照。
    static let webAXWarmup: TimeInterval = 0.3

    /// 促使 Chromium/Electron 构建完整 AX 树。
    ///
    /// 不调这一步只能读到菜单栏 —— 实测未唤醒时 143 个节点全是菜单项，web 内容一个都没有。
    /// - `AXEnhancedUserInterface`：VoiceOver 的标准路径，部分进程不实现（返回 -25208）；
    /// - `AXManualAccessibility`：Chromium 专有入口，Electron 上实测有效。
    /// 两者都试，失败静默忽略（最差退回「只读到菜单栏」，与不调用等效）。
    static func enableWebAccessibility(on app: AXUIElement) {
        for attributeName in ["AXEnhancedUserInterface", "AXManualAccessibility"] {
            AXUIElementSetAttributeValue(app, attributeName as CFString, kCFBooleanTrue)
        }
    }

    /// 安全读取单个 AX 属性；失败返回 nil。
    static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success else { return nil }
        return value
    }

    /// 读取字符串属性；空串按 nil 处理（AX 里空串与不存在等价，混用会让上层判断变复杂）。
    static func text(_ element: AXUIElement, _ attribute: String) -> String? {
        guard let raw = copyAttribute(element, attribute) as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : raw
    }

    /// 元素角色（`AXButton` / `AXGroup` …）；读不到返回空串。
    static func role(of element: AXUIElement) -> String {
        text(element, kAXRoleAttribute) ?? ""
    }

    /// 元素子角色（`AXApplicationDialog` …）；读不到返回空串。
    static func subrole(of element: AXUIElement) -> String {
        text(element, kAXSubroleAttribute) ?? ""
    }

    /// 子节点数组；失败 / 类型不符返回空数组。
    static func children(of element: AXUIElement) -> [AXUIElement] {
        guard let raw = copyAttribute(element, kAXChildrenAttribute),
              let list = raw as? [Any] else { return [] }
        return list.compactMap(asElement)
    }

    /// CFArray 元素 → `AXUIElement`；先校验 CFTypeID 再转换。
    ///
    /// - Note: 不能写 `item as? AXUIElement` —— 对 CoreFoundation 类型那样写会被判为
    ///   「必然成功」（编译告警）并可能拿到非元素对象，运行时崩溃。
    static func asElement(_ item: Any) -> AXUIElement? {
        let value = item as CFTypeRef
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    /// 自起始单调时间戳以来的秒数。
    static func elapsed(since start: UInt64) -> TimeInterval {
        TimeInterval(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
    }
}

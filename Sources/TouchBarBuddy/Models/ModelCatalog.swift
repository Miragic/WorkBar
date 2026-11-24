import Foundation

/// 模型目录：把 `sessions.model` 的真实取值（id）映射为可读名 / 倍率。
///
/// 取值来源：WorkBuddy 5.9.x 真机实测的 `model` 值（共 10 种 + 空串）：
/// `deepseek-v4.1-flash` / `deepseek-v4-flash` / `deepseek-v4-pro` / `hy3` / `hy4std` /
/// `hy4-preview` / `glm-5.2` / `fast-model` / `auto` / `space-bunny`。
///
/// - Important: 实测 id 与早期设计稿的倍率表（GLM-5.3-Flash / DeepSeek-V4.1-Flash / Kimi 3.1 Pro）**完全对不上**，
///   以真机实测为准，不要用设计稿里的模型名做映射。
enum ModelCatalog {

    /// 真实 id -> 可读展示名；未知值原样返回（去除首尾空白后），空值返回 nil。
    static func displayName(for raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return names[raw.lowercased()] ?? raw
    }

    /// 模型倍率。
    /// - Important: **刻意一律返回 nil**。真实倍率无法从本地库拿到，
    ///   宁可不显示倍率徽标，也绝不展示错误数字；待后续从 WorkBuddy 本地 IPC / 后端接口取到真实倍率再补全。
    static func multiplier(for raw: String?) -> Double? {
        // 保留参数以稳定签名，当前无条件返回 nil。
        return nil
    }

    /// 实测 id（小写）-> 可读名。
    private static let names: [String: String] = [
        "deepseek-v4.1-flash": "DeepSeek V4.1 Flash",
        "deepseek-v4-flash": "DeepSeek V4 Flash",
        "deepseek-v4-pro": "DeepSeek V4 Pro",
        "hy3": "混元 3",
        "hy4std": "混元 4",
        "hy4-preview": "混元 4 Preview",
        "glm-5.2": "GLM-5.2",
        "fast-model": "极速模型",
        "auto": "自动",
        "space-bunny": "Space Bunny"
    ]
}

import AppKit

/// 深浅色自适应配色（PRD P2-3）。
///
/// ## 为什么需要
/// 设计稿给的是固定 hex：错误红 `#E05B5B`、确认青绿 `#3DDC97`。这两个值在**深色**
/// Touch Bar 上对比度正好，但换到浅色外观就偏亮、发白，文字读不清。
/// 语义色（`labelColor` / `secondaryLabelColor` / `systemOrange`）系统已经自适应，
/// 唯独这两个「品牌语义色」是硬编码 —— 这里把它们做成动态色：
/// **深色沿用设计原值，浅色改用同色系加深版本**，色相不变、语义不变。
///
/// ## 测试
/// `Palette` 里所有取值都是纯函数（`rgb(dark:)`），可以直接比较两种外观下的亮度，
/// 不必真的切换系统外观。`PaletteTests` 钉住了「浅色版必须更暗」这一条。
enum Palette {

    /// 是否深色外观。
    ///
    /// - Note: 用 `bestMatch` 而不是比较名称：`NSAppearance.Name` 还有
    ///   `accessibilityHighContrastDarkAqua`、`vibrantDark` 等变体，
    ///   只有 `bestMatch` 能一次覆盖全部深色变体。
    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    // MARK: - 错误红

    /// 错误红在指定外观下的 RGB（0~255）。
    ///
    /// - 深色：`#E05B5B` —— 设计稿原值，深底上足够亮。
    /// - 浅色：`#C0392B` —— 同色相加深，保证浅底上不「糊」。
    static func errorRGB(dark: Bool) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        dark ? (0xE0, 0x5B, 0x5B) : (0xC0, 0x39, 0x2B)
    }

    /// 错误红（动态色，随外观自动切换）。
    static var error: NSColor {
        dynamic(name: "tb.error") { dark in
            let c = errorRGB(dark: dark)
            return NSColor(srgbRed: c.r / 255, green: c.g / 255, blue: c.b / 255, alpha: 1)
        }
    }

    // MARK: - 确认青绿

    /// 确认青绿在指定外观下的 RGB（0~255）。
    ///
    /// - 深色：`#3DDC97` —— 设计稿原值。
    /// - 浅色：`#12855A` —— 同色相加深，浅底上仍然一眼可辨「我收到了」。
    static func acknowledgeRGB(dark: Bool) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        dark ? (0x3D, 0xDC, 0x97) : (0x12, 0x85, 0x5A)
    }

    /// 确认青绿（动态色，随外观自动切换）。
    static var acknowledge: NSColor {
        dynamic(name: "tb.acknowledge") { dark in
            let c = acknowledgeRGB(dark: dark)
            return NSColor(srgbRed: c.r / 255, green: c.g / 255, blue: c.b / 255, alpha: 1)
        }
    }

    // MARK: - 工具

    /// 相对亮度（WCAG 公式，只用 R/G/B 线性化后的加权和）。
    ///
    /// 用途：单测比较「浅色版是否确实更暗」。不追求完整对比度计算 ——
    /// 背景色由系统 bezel 决定，我们拿不到确定值，比「相对更暗」是可靠且可测的判据。
    static func relativeLuminance(r: CGFloat, g: CGFloat, b: CGFloat) -> CGFloat {
        func linear(_ value: CGFloat) -> CGFloat {
            let v = value / 255
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    /// 由「深色与否」构造动态色。
    private static func dynamic(name: String,
                                _ make: @escaping (_ dark: Bool) -> NSColor) -> NSColor {
        NSColor(name: NSColor.Name(name)) { appearance in
            make(isDark(appearance))
        }
    }
}

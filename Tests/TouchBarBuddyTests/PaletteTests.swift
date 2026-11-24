import AppKit
import XCTest
@testable import TouchBarBuddy

/// 深浅色自适应配色单测（PRD P2-3）。
///
/// 为什么必须自动化：颜色对不对**只在真机切换外观时才看得出来**，
/// 而回归时没人会每次都去切一遍系统外观。这里用纯函数比较亮度——
/// 判据不是「好看」，而是「浅色版必须比深色版更暗」这一条客观事实：
/// 浅底上放亮色必然读不清，这条能挡住「把深色值原样搬到浅色」的退化。
final class PaletteTests: XCTestCase {

    /// 错误红：浅色版必须更暗。
    func testErrorColorIsDarkerInLightAppearance() {
        let dark = Palette.errorRGB(dark: true)
        let light = Palette.errorRGB(dark: false)
        let darkLum = Palette.relativeLuminance(r: dark.r, g: dark.g, b: dark.b)
        let lightLum = Palette.relativeLuminance(r: light.r, g: light.g, b: light.b)
        XCTAssertTrue(lightLum < darkLum,
                      "浅色错误红应更暗：light=\(lightLum) dark=\(darkLum)")
    }

    /// 确认青绿：浅色版必须更暗。
    func testAcknowledgeColorIsDarkerInLightAppearance() {
        let dark = Palette.acknowledgeRGB(dark: true)
        let light = Palette.acknowledgeRGB(dark: false)
        let darkLum = Palette.relativeLuminance(r: dark.r, g: dark.g, b: dark.b)
        let lightLum = Palette.relativeLuminance(r: light.r, g: light.g, b: light.b)
        XCTAssertTrue(lightLum < darkLum,
                      "浅色确认绿应更暗：light=\(lightLum) dark=\(darkLum)")
    }

    /// 深色版必须仍然是设计稿原值，不能被顺手改掉。
    func testDarkVariantsKeepDesignTokens() {
        let err = Palette.errorRGB(dark: true)
        XCTAssertEqual(err.r, 0xE0)
        XCTAssertEqual(err.g, 0x5B)
        XCTAssertEqual(err.b, 0x5B)

        let ack = Palette.acknowledgeRGB(dark: true)
        XCTAssertEqual(ack.r, 0x3D)
        XCTAssertEqual(ack.g, 0xDC)
        XCTAssertEqual(ack.b, 0x97)
    }

    /// 红与绿在任何外观下都必须是两种颜色（语义不能串）。
    func testErrorAndAcknowledgeNeverCollapse() {
        for dark in [true, false] {
            let e = Palette.errorRGB(dark: dark)
            let a = Palette.acknowledgeRGB(dark: dark)
            XCTAssertFalse(e.r == a.r && e.g == a.g && e.b == a.b,
                           "dark=\(dark) 时错误红与确认绿变成了同一个颜色")
        }
    }

    /// 外观判定：深色变体都要被判为 dark，浅色判为 light。
    func testAppearanceDetection() {
        XCTAssertTrue(Palette.isDark(NSAppearance(named: .darkAqua)!))
        XCTAssertTrue(Palette.isDark(NSAppearance(named: .vibrantDark)!))
        XCTAssertFalse(Palette.isDark(NSAppearance(named: .aqua)!))
        XCTAssertFalse(Palette.isDark(NSAppearance(named: .vibrantLight)!))
        // 高对比深色是 darkAqua 的变体，必须同样归入深色，否则会出现「高对比下用浅色值」。
        XCTAssertTrue(Palette.isDark(NSAppearance(named: .accessibilityHighContrastDarkAqua)!))
    }
}

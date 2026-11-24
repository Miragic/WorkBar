import XCTest
@testable import TouchBarBuddy

/// WorkBuddy 侧边栏「当前选中会话」解析的纯函数单测（不依赖真机 AX）。
final class SelectedSessionReaderTests: XCTestCase {

    /// 侧边栏 title 带时间尾巴时要提取主标题；空标题返回 nil。
    func testPrimaryTitleStripsTimeSuffix() {
        XCTAssertEqual(
            SelectedSessionReader.primaryTitle(from: "为 WorkBuddy Touchbar 应用设计图标 1分钟前"),
            "为 WorkBuddy Touchbar 应用设计图标")
        XCTAssertEqual(SelectedSessionReader.primaryTitle(from: "任务 A 刚刚"), "任务 A")
        XCTAssertEqual(SelectedSessionReader.primaryTitle(from: "任务 B 3 小时前"), "任务 B")
        XCTAssertEqual(SelectedSessionReader.primaryTitle(from: "任务 C"), "任务 C")
        XCTAssertNil(SelectedSessionReader.primaryTitle(from: nil))
        XCTAssertNil(SelectedSessionReader.primaryTitle(from: "   "))
    }

    /// `_selected_` 类名判定：字符串 / 字符串数组两种 AXDOMClassList 形态都要认。
    func testSelectedClassListDetection() {
        XCTAssertTrue(SelectedSessionReader.isSelected("_selected_1ufy3_20 other-class"))
        XCTAssertTrue(SelectedSessionReader.isSelected(["normal", "_selected_abc"]))
        XCTAssertFalse(SelectedSessionReader.isSelected("normal other-class"))
        XCTAssertFalse(SelectedSessionReader.isSelected(["normal"]))
        XCTAssertFalse(SelectedSessionReader.isSelected(nil))
    }

    /// 任务标题与 AX 标题双向包含（容忍尾巴与一侧多字）。
    func testMatchesTaskTitleWithSelectedTitle() {
        XCTAssertTrue(SelectedSessionReader.matches(
            taskTitle: "为 WorkBuddy Touchbar 应用设计图标",
            selectedTitle: "为 WorkBuddy Touchbar 应用设计图标 1分钟前"))
        XCTAssertTrue(SelectedSessionReader.matches(
            taskTitle: "任务",
            selectedTitle: "任务 A 2分钟前"))
        XCTAssertFalse(SelectedSessionReader.matches(
            taskTitle: "任务 A",
            selectedTitle: "完全不同的会话"))
        XCTAssertFalse(SelectedSessionReader.matches(
            taskTitle: "",
            selectedTitle: "任务 A"))
    }
}

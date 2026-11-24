import Foundation
import AppKit
import XCTest
@testable import TouchBarBuddy

/// 「默认详情模式」开关的单测。
///
/// 为什么钉这里：这一项改的是**初始态**，写错方向不会崩、不会报错，
/// 只会让所有人打开 App 就看到另一副样子 —— 属于最难靠肉眼发现的那类失效。
/// 因此至少要把「默认值是 false」「值能存住」「变更会发通知」三件事钉死。
final class TaskDetailModeTests: XCTestCase {

    private let key = "tb.taskDetailByDefault"
    private var original: Any?

    override func setUp() {
        super.setUp()
        original = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
    }

    override func tearDown() {
        if let original = original {
            UserDefaults.standard.set(original, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        super.tearDown()
    }

    /// 默认必须是关闭：紧凑态才是「一眼看几个任务在跑」的默认视角。
    ///
    /// 若哪天有人把默认值改成 `true`，这条会立刻失败 —— 这是有意的。
    func testDefaultIsOff() {
        XCTAssertFalse(Settings.taskDetailByDefault, "默认详情模式不该默认开启")
    }

    /// 值能持久化并被读回。
    func testSettingRoundTrips() {
        Settings.taskDetailByDefault = true
        XCTAssertTrue(Settings.taskDetailByDefault)
        Settings.taskDetailByDefault = false
        XCTAssertFalse(Settings.taskDetailByDefault)
    }

    /// 变更会发通知（控制器靠它立即重建，而不是等下一轮 3 秒轮询）。
    func testChangePostsNotification() {
        var received: [String] = []
        let token = NotificationCenter.default.addObserver(
            forName: Settings.didChangeNotification,
            object: nil,
            queue: nil
        ) { note in
            if let key = note.userInfo?[Settings.changedKeyKey] as? String {
                received.append(key)
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        Settings.taskDetailByDefault = true
        XCTAssertEqual(received, [key], "变更没有发出带正确 key 的通知")
    }

    /// 写同一个值不该发通知 —— 否则每次打开设置面板同步开关状态都会触发一次重建。
    func testSameValueDoesNotPostNotification() {
        Settings.taskDetailByDefault = true
        var count = 0
        let token = NotificationCenter.default.addObserver(
            forName: Settings.didChangeNotification,
            object: nil,
            queue: nil
        ) { _ in count += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        Settings.taskDetailByDefault = true
        XCTAssertEqual(count, 0, "重复写同值不该发通知")
    }

    /// 「任务步骤」默认关闭：它只对 16/54 个会话有数据，默认开会让这一格时有时无。
    func testShowTaskStepDefaultsOff() {
        let stepKey = "tb.showTaskStep"
        let saved = UserDefaults.standard.object(forKey: stepKey)
        UserDefaults.standard.removeObject(forKey: stepKey)
        defer {
            if let saved = saved {
                UserDefaults.standard.set(saved, forKey: stepKey)
            } else {
                UserDefaults.standard.removeObject(forKey: stepKey)
            }
        }
        XCTAssertFalse(Settings.showTaskStep, "任务步骤不该默认开启")

        var posted = 0
        let token = NotificationCenter.default.addObserver(
            forName: Settings.didChangeNotification,
            object: nil,
            queue: nil
        ) { note in
            if note.userInfo?[Settings.changedKeyKey] as? String == stepKey { posted += 1 }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        Settings.showTaskStep = true
        XCTAssertTrue(Settings.showTaskStep)
        XCTAssertEqual(posted, 1, "任务步骤开关没发出正确的变更通知")
    }

    /// 图形环已是默认（真机验证圆环持续存在）；缺省键时必须返回 true。
    func testGraphicContextIconDefaultsOn() {
        let key = "tb.graphicContextIcon"
        let saved = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        defer {
            if let saved = saved {
                UserDefaults.standard.set(saved, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        XCTAssertTrue(Settings.graphicContextIcon, "缺省时应为图形模式")
        Settings.graphicContextIcon = false
        XCTAssertFalse(Settings.graphicContextIcon, "必须能关掉退回字符模式")
    }

    /// 双栏设置面板：左侧导航 + 右侧分组卡片，所有控件分属不同层级。
    /// 这里递归检查整棵视图树：全部在窗口内、开关数量与语义分组正确、开关统一右对齐。
    func testSettingsPanelLayoutFitsWindow() {
        let controller = SettingsWindowController()
        guard let content = controller.window?.contentView else {
            return XCTFail("设置窗口没有 contentView")
        }

        // 卡片化后控件嵌在 card → tabView → contentView 里，需递归收集。
        let views = TaskDetailModeTests.descendants(of: content)
        let allSwitches = views.compactMap { $0 as? NSSwitch }
        XCTAssertEqual(allSwitches.count, 10, "5 个常规 + 4 个 DIY + 1 个预览模式开关应保持不变")

        let actionName: (NSView) -> String = { view in
            guard let control = view as? NSControl, let action = control.action else { return "" }
            return NSStringFromSelector(action)
        }
        let generalActions: Set<String> = [
            "minimalModeToggled", "taskDetailModeToggled", "showTaskStepToggled",
            "graphicIconToggled", "keepAwakeToggled"
        ]
        let general = allSwitches.filter { generalActions.contains(actionName($0)) }
        let diy = allSwitches.filter { actionName($0) == "layoutToggle:" }
        let preview = allSwitches.filter { actionName($0) == "previewModeToggled:" }
        XCTAssertEqual(general.count, 5, "常规页 5 个开关应保持不变")
        XCTAssertEqual(diy.count, 4, "DIY 布局应有 4 个开关")
        XCTAssertEqual(preview.count, 1, "应有 1 个预览空闲态开关")

        // 所有子视图（含隐藏的分类页）都必须在窗口内；frame 要从父视图坐标系换算到 content。
        for view in views {
            guard let parent = view.superview else { continue }
            let frame = content.convert(view.frame, from: parent)
            XCTAssertTrue(frame.minX >= -0.5, "控件左边越界：\(frame)")
            XCTAssertTrue(frame.maxX <= content.bounds.width + 0.5, "控件右边越界：\(frame)")
            XCTAssertTrue(frame.minY >= -0.5, "控件下边越界：\(frame)")
            XCTAssertTrue(frame.maxY <= content.bounds.height + 0.5, "控件上边越界：\(frame)")
        }

        // 重构要求：所有开关右对齐到统一 x，不再出现 x=116 / x=300 的错位。
        let switchXs = allSwitches.compactMap { view -> CGFloat? in
            guard let parent = view.superview else { return nil }
            return content.convert(view.frame, from: parent).minX
        }
        let distinctXs = Set(switchXs.map { Int($0.rounded()) })
        XCTAssertEqual(distinctXs.count, 1, "所有开关应右对齐到统一 x，实际：\(switchXs)")

        // 常规页 5 行的 y 必须严格递减且不贴边，说明每行都独立占位。
        let ys = general.map { view -> CGFloat in
            guard let parent = view.superview else { return view.frame.midY }
            return content.convert(view.frame, from: parent).midY
        }.sorted(by: { $0 > $1 })
        for i in 1..<ys.count {
            XCTAssertTrue(ys[i-1] - ys[i] >= 40, "第 \(i) 行与上一行挨得太近：\(ys)")
        }
        XCTAssertTrue(ys.last! > 30, "最后一行贴到窗口底部：\(ys)")
    }

    private static func descendants(of view: NSView) -> [NSView] {
        var result: [NSView] = []
        for subview in view.subviews {
            result.append(subview)
            result.append(contentsOf: descendants(of: subview))
        }
        return result
    }
}

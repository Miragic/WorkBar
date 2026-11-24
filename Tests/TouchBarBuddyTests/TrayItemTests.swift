import AppKit
import XCTest
@testable import TouchBarBuddy

/// Control Strip（Touch Bar 最右侧系统栏）里的 WorkBar logo 单测。
///
/// 为什么钉这里：这个 logo 是用户「用 × 关掉之后唯一的再打开入口」。
/// 它有两个极易被顺手改坏的属性：
/// 1. **不能进应用区**（一进去就白吃约 30pt，本工具可用宽度只有约 290pt）；
/// 2. **必须有非零尺寸**（Touch Bar 对 0×0 自定义视图的表现是整块不渲染，
///    真机上等于「入口消失」，而不报任何错）。
/// 两者都不会崩、也不会让既有测试变红，所以必须单独守住。
final class TrayItemTests: XCTestCase {

    /// 标识符必须能被 `kind(of:)` 解析成 `tray`，否则 `makeItem` 走不进 tray 分支，
    /// 系统来要 item 时拿到 nil，格子里会是空白。
    func testTrayIdentifierResolvesToTrayKind() {
        XCTAssertEqual(TouchBarItemFactory.kind(of: TouchBarItemFactory.trayIdentifier), "tray")
    }

    /// **回归守卫**：tray 绝不能出现在任何一条应用区布局里。
    ///
    /// 覆盖工作态 / 空闲态 / 待确认态 / 弹层态 / 权限屏 / 极简，逐个断言。
    func testTrayNeverAppearsInAppBar() {
        let task = TaskInfo(id: "t", title: "任务", status: .working)
        let idleStats = IdleStats(todayCompleted: 3, todayCredits: 1.5, totalCredits: 0)
        let permission = PermissionRequest(
            title: "允许访问",
            items: [PermissionItem(label: "项目", granted: true)]
        )

        let cases: [(String, TouchBarState, Bool)] = [
            ("工作态", .working(tasks: [task]), false),
            ("空闲态", .idle, false),
            ("待确认态", .pending(tasks: [task]), false),
            ("工作态极简", .working(tasks: [task]), true),
            ("空闲态极简", .idle, true),
        ]
        for (name, state, minimal) in cases {
            let ids = TouchBarItemFactory.identifiers(
                for: state,
                generation: 1,
                notice: nil,
                idleStats: idleStats,
                minimalMode: minimal,
                layoutOrder: Settings.defaultLayoutOrder
            )
            XCTAssertFalse(ids.contains(TouchBarItemFactory.trayIdentifier),
                           "\(name)的应用区不应含 tray（会白吃宽度）")
        }

        // 弹层态与权限屏（含屏 2）也不能含 tray。
        let choiceState = TouchBarState.choice(title: "选择", options: ["A", "B"])
        for detail in [false, true] {
            let ids = TouchBarItemFactory.identifiers(
                for: choiceState,
                generation: 1,
                notice: nil,
                idleStats: idleStats,
                permissions: permission,
                permissionDetailShown: detail,
                layoutOrder: Settings.defaultLayoutOrder
            )
            XCTAssertFalse(ids.contains(TouchBarItemFactory.trayIdentifier),
                           "权限屏(detail=\(detail))不应含 tray")
        }
    }

    /// tray item 必须造得出来，且视图有非零固有尺寸 ——
    /// 0×0 在 Touch Bar 上等于「静默不渲染」。
    func testTrayItemHasNonZeroIntrinsicSize() {
        let handlers = TouchBarItemFactory.Handlers(
            onJump: {},
            onVoiceToggle: {},
            onSwipe: { _ in },
            onDialogOption: { _ in },
            onPermissionDetail: {},
            onPermissionToggle: { _ in },
            onPermissionAllow: {},
            onPermissionCancel: {}
        )
        let item = TouchBarItemFactory.makeItem(
            identifier: TouchBarItemFactory.trayIdentifier,
            state: .idle,
            focusedIndex: 0,
            isListening: false,
            notice: nil,
            face: .idle,
            faceTransition: nil,
            idleStats: IdleStats(todayCompleted: 0, todayCredits: 0, totalCredits: 0),
            handlers: handlers
        )
        guard let custom = item as? NSCustomTouchBarItem else {
            XCTAssertTrue(false, "tray 应产出 NSCustomTouchBarItem")
            return
        }
        let size = custom.view.intrinsicContentSize
        XCTAssertTrue(size.width > 0, "tray 视图宽度必须非零（0 会被静默不渲染）")
        XCTAssertTrue(size.height > 0, "tray 视图高度必须非零")
        // 图标不能是空的：空白格会让用户以为「关掉就再也打不开了」。
        if let button = custom.view as? NSButton {
            XCTAssertTrue(button.image != nil, "tray 按钮必须有图标")
        } else {
            XCTAssertTrue(false, "tray 视图应为 NSButton")
        }
    }

    /// 图标加载不能依赖资源名恰好叫对：三条兜底路径任一命中都要出图。
    ///
    /// - Note: 这里**不**断言 `isTemplate`。图标是否标记为模板取决于运行环境里
    ///   哪一份资源被解析到（测试二进制旁边没有 png 时会落到自绘兜底，那是非模板的），
    ///   断言它会把「换资源」和「改逻辑」两件事绑死。
    ///   模板图在 Control Strip 深底上会不会看不见，是用离屏渲染探针单独验的
    ///   （darkAqua 下像素最大亮度约 0.70，明显亮于底色 0.18）。
    func testTrayIconAlwaysProducesImage() {
        let icon = TouchBarItemFactory.trayIcon()
        XCTAssertTrue(icon.size.width > 0, "tray 图标宽度必须非零")
        XCTAssertTrue(icon.size.height > 0, "tray 图标高度必须非零")
        XCTAssertTrue(icon.tiffRepresentation != nil, "tray 图标必须能实际绘制出来")
    }

    /// 点击回调必须真的被接上（否则 logo 只是个装饰，用户点了没反应）。
    func testTrayTapFiresHandler() {
        var fired = 0
        let handlers = TouchBarItemFactory.Handlers(
            onJump: {},
            onVoiceToggle: {},
            onSwipe: { _ in },
            onDialogOption: { _ in },
            onPermissionDetail: {},
            onPermissionToggle: { _ in },
            onPermissionAllow: {},
            onPermissionCancel: {},
            onTrayTap: { fired += 1 }
        )
        let item = TouchBarItemFactory.makeItem(
            identifier: TouchBarItemFactory.trayIdentifier,
            state: .idle,
            focusedIndex: 0,
            isListening: false,
            notice: nil,
            face: .idle,
            faceTransition: nil,
            idleStats: IdleStats(todayCompleted: 0, todayCredits: 0, totalCredits: 0),
            handlers: handlers
        )
        guard let button = (item as? NSCustomTouchBarItem)?.view as? NSButton else {
            XCTAssertTrue(false, "tray 视图应为 NSButton")
            return
        }
        button.performClick(nil)
        XCTAssertEqual(fired, 1, "点 logo 必须触发 onTrayTap（唯一的重开入口）")
    }
}

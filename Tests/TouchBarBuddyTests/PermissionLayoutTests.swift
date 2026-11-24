import AppKit
import XCTest
@testable import TouchBarBuddy

/// 权限两屏的**布局契约**单测。
///
/// 为什么值得测：这两屏没法在真机上随时复现（要 WorkBuddy 真的请求权限），
/// 而「该铺哪些 item」完全是纯函数 —— 一旦顺序或 kind 写错，表现是「屏幕上是别的东西」
/// 或「点不了」，靠肉眼排查代价极高。
final class PermissionLayoutTests: XCTestCase {

    private let request = PermissionRequest(
        title: "允许完全访问",
        items: [
            PermissionItem(label: "文件操作", granted: true),
            PermissionItem(label: "终端命令", granted: false),
            PermissionItem(label: "访问互联网", granted: true)
        ]
    )

    private let choiceState = TouchBarState.choice(title: "允许完全访问",
                                                   options: ["取消", "允许"])

    /// 从 identifier 里抽出 kind 列表，便于断言顺序。
    private func kinds(_ ids: [NSTouchBarItem.Identifier]) -> [String] {
        ids.compactMap { TouchBarItemFactory.kind(of: $0) }
    }

    /// 屏 1：标题 + 允许 + 取消（+ 语音，`.choice` 态下它 priority 为 0，会被宽度挤掉）。
    func testPermissionScreenOneLayout() {
        let ids = TouchBarItemFactory.identifiers(for: choiceState,
                                                  generation: 1,
                                                  notice: nil,
                                                  idleStats: .empty,
                                                  permissions: request,
                                                  permissionDetailShown: false,
                                                  layoutOrder: Settings.defaultLayoutOrder)
        XCTAssertEqual(kinds(ids), ["ptitle", "pallow", "pcancel", "voice"])
    }

    /// 屏 2：三个勾选项 + 返回，**不再有允许/取消**（避免两屏按钮语义混淆）。
    func testPermissionDetailLayout() {
        let ids = TouchBarItemFactory.identifiers(for: choiceState,
                                                  generation: 1,
                                                  notice: nil,
                                                  idleStats: .empty,
                                                  permissions: request,
                                                  permissionDetailShown: true,
                                                  layoutOrder: Settings.defaultLayoutOrder)
        XCTAssertEqual(kinds(ids), ["pcb0", "pcb1", "pcb2", "pback", "voice"])
    }

    /// 只有两项权限时，屏 2 只铺两个勾选项（不多铺空壳）。
    func testPermissionDetailWithTwoItems() {
        let two = PermissionRequest(title: "允许完全访问",
                                    items: [PermissionItem(label: "文件操作", granted: true),
                                            PermissionItem(label: "终端命令", granted: false)])
        let ids = TouchBarItemFactory.identifiers(for: choiceState,
                                                  generation: 1,
                                                  notice: nil,
                                                  idleStats: .empty,
                                                  permissions: two,
                                                  permissionDetailShown: true,
                                                  layoutOrder: Settings.defaultLayoutOrder)
        XCTAssertEqual(kinds(ids), ["pcb0", "pcb1", "pback", "voice"])
    }

    /// 不是权限弹窗时，`.choice` 必须退回原来的「标题 + 选项」布局。
    func testNonPermissionDialogKeepsOriginalLayout() {
        let ids = TouchBarItemFactory.identifiers(for: choiceState,
                                                  generation: 1,
                                                  notice: nil,
                                                  idleStats: .empty,
                                                  permissions: nil,
                                                  permissionDetailShown: false,
                                                  layoutOrder: Settings.defaultLayoutOrder)
        XCTAssertEqual(kinds(ids), ["dtitle", "dopt0", "dopt1", "voice"])
    }

    /// 有瞬时提示时，提示位排在权限屏之前，且两屏的 item 数量不会因此改变。
    func testNoticePrecedesPermissionItems() {
        let notice = TransientNotice(text: "按钮已消失", style: .error)
        let screenOne = TouchBarItemFactory.identifiers(for: choiceState,
                                                        generation: 1,
                                                        notice: notice,
                                                        idleStats: .empty,
                                                        permissions: request,
                                                        permissionDetailShown: false,
                                                  layoutOrder: Settings.defaultLayoutOrder)
        XCTAssertEqual(kinds(screenOne), ["error", "ptitle", "pallow", "pcancel", "voice"])
    }

    /// 非 `.choice` 态下即使带着权限请求也不走权限布局（弹窗已关、状态机还在别处）。
    func testPermissionLayoutRequiresChoiceState() {
        let ids = TouchBarItemFactory.identifiers(for: .idle,
                                                  generation: 1,
                                                  notice: nil,
                                                  idleStats: .empty,
                                                  permissions: request,
                                                  permissionDetailShown: false,
                                                  layoutOrder: Settings.defaultLayoutOrder)
        XCTAssertEqual(kinds(ids), ["summary", "stats", "voice"])
    }
}

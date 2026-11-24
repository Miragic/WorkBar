import AppKit
import XCTest
@testable import TouchBarBuddy

/// Touch Bar DIY 布局：持久化容错 + 标识符顺序 / 互斥 + 预览数据。
/// 只测纯函数与视图的数据属性，不依赖真实绘制像素。
final class LayoutSettingsTests: XCTestCase {

    private let key = "tb.layoutOrder"
    private var savedData: Data?

    override func setUp() {
        savedData = UserDefaults.standard.data(forKey: key)
    }

    override func tearDown() {
        if let savedData = savedData {
            UserDefaults.standard.set(savedData, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private func item(_ id: String, _ enabled: Bool = true) -> Settings.LayoutItem {
        Settings.LayoutItem(id: id, enabled: enabled)
    }

    private func store(_ items: [Settings.LayoutItem]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private func kinds(_ order: [Settings.LayoutItem],
                       state: TouchBarState,
                       minimal: Bool = false) -> [String] {
        let ids = TouchBarItemFactory.identifiers(for: state,
                                                  generation: 1,
                                                  notice: nil,
                                                  idleStats: .empty,
                                                  minimalMode: minimal,
                                                  layoutOrder: order)
        return ids.compactMap { TouchBarItemFactory.kind(of: $0) }
    }

    private var working: TouchBarState {
        .working(tasks: [TaskInfo(id: "t", title: "T", status: .working)])
    }

    /// 默认值：四项全开、顺序与当前线上一致。
    func testDefaultLayoutOrder() {
        let expected = ["summary", "task", "stats", "voice"]
        XCTAssertEqual(Settings.defaultLayoutOrder.map(\.id), expected)
        for item in Settings.defaultLayoutOrder {
            XCTAssertTrue(item.enabled, "默认四项应全部启用：\(item.id)")
        }
    }

    /// 非法配置（重复 / 缺失 / 未知 id / 非 JSON）读取时一律回退默认。
    func testInvalidStoredLayoutFallsBackToDefault() {
        let invalid: [[Settings.LayoutItem]] = [
            [item("summary"), item("summary"), item("stats"), item("voice")], // 重复
            [item("summary"), item("task"), item("stats")],                   // 缺失 voice
            [item("summary"), item("task"), item("stats"), item("voice"), item("extra")] // 未知
        ]
        for list in invalid {
            store(list)
            XCTAssertEqual(Settings.layoutOrder, Settings.defaultLayoutOrder)
        }
        UserDefaults.standard.set("not-json".data(using: .utf8), forKey: key)
        XCTAssertEqual(Settings.layoutOrder, Settings.defaultLayoutOrder)
    }

    /// 合法配置写入后能读回（含顺序与 enabled）。
    func testCustomLayoutRoundTrips() {
        let custom = [item("voice", false), item("task"), item("summary"), item("stats", false)]
        Settings.layoutOrder = custom
        XCTAssertEqual(Settings.layoutOrder, custom)
        XCTAssertEqual(Settings.layoutOrder.map(\.id),
                       ["voice", "task", "summary", "stats"])
        XCTAssertFalse(Settings.layoutOrder[0].enabled)
    }

    /// 工作态：按自定义顺序输出，禁用的不出现。
    func testIdentifiersFollowCustomOrderAndEnabledFlag() {
        let order = [item("voice", false), item("task"), item("summary", false), item("stats")]
        XCTAssertEqual(kinds(order, state: working), ["task"])
    }

    /// idle / work 下 task 与 stats 互斥（默认顺序不变）。
    func testTaskAndStatsAreMutuallyExclusive() {
        XCTAssertEqual(kinds(Settings.defaultLayoutOrder, state: working),
                       ["summary", "task", "voice"])
        XCTAssertEqual(kinds(Settings.defaultLayoutOrder, state: .idle),
                       ["summary", "stats", "voice"])
    }

    /// choice 态不受 DIY 影响（仍按权限 / 弹层布局，voice 照旧）。
    func testChoiceStateIgnoresDiyOrder() {
        let state = TouchBarState.choice(title: "允许完全访问", options: ["取消", "允许"])
        let order = [item("summary", false), item("task", false),
                     item("stats", false), item("voice", false)]
        XCTAssertEqual(kinds(order, state: state), ["dtitle", "dopt0", "dopt1", "voice"])
    }

    /// 极简模式仍只 summary + voice，DIY 顺序不生效。
    func testMinimalModeIgnoresDiyOrder() {
        let order = [item("voice"), item("stats"), item("task"), item("summary")]
        XCTAssertEqual(kinds(order, state: working, minimal: true),
                       ["summary", "voice"])
    }

    /// 预览色块体现启用项、顺序与 idle/work 互斥，且缩放后不越界。
    func testPreviewBlocksReflectOrderEnabledAndState() {
        let view = LayoutPreviewView(frame: NSRect(x: 0, y: 0, width: 340, height: 40))
        view.layout = [item("voice"), item("task"), item("summary", false), item("stats")]
        view.isIdle = false
        XCTAssertEqual(view.renderedBlocks.map(\.id), ["voice", "task"])

        view.isIdle = true
        XCTAssertEqual(view.renderedBlocks.map(\.id), ["voice", "stats"])

        view.layout = [item("stats"), item("voice"), item("task"), item("summary")]
        view.isIdle = true
        XCTAssertEqual(view.renderedBlocks.map(\.id), ["stats", "voice", "summary"])
        view.isIdle = false
        XCTAssertEqual(view.renderedBlocks.map(\.id),
                       ["voice", "task", "summary"])
        guard let last = view.renderedBlocks.last else {
            return XCTFail("预览应有色块")
        }
        XCTAssertTrue(last.x + last.width <= view.bounds.width + 0.01,
                      "色块应缩放进预览区：\(last.x + last.width) > \(view.bounds.width)")
    }

    /// 极简模式下预览只剩摘要 + 语音（与真实 identifiers 的分支一致）。
    func testPreviewMinimalModeOnlySummaryAndVoice() {
        let view = LayoutPreviewView(frame: NSRect(x: 0, y: 0, width: 340, height: 40))
        view.layout = Settings.defaultLayoutOrder
        view.minimalMode = true
        XCTAssertEqual(view.renderedBlocks.map(\.id), ["summary", "voice"])
        view.isIdle = true
        XCTAssertEqual(view.renderedBlocks.map(\.id), ["summary", "voice"])
        view.minimalMode = false
        XCTAssertEqual(view.renderedBlocks.map(\.id), ["summary", "stats", "voice"])
    }

    /// 预览任务条跟随详情 / 步骤 / 圆环开关：紧凑态无第二行，开启后逐项出现。
    func testPreviewTaskSegmentsFollowSettingSwitches() {
        let view = LayoutPreviewView(frame: NSRect(x: 0, y: 0, width: 340, height: 40))
        XCTAssertEqual(view.taskSecondLineSegments, [], "紧凑态任务条只画一行标题")

        view.detailExpanded = true
        XCTAssertEqual(view.taskSecondLineSegments,
                       ["statusDot", "model", "ring", "credit", "age"])

        view.showTaskStep = true
        XCTAssertEqual(view.taskSecondLineSegments,
                       ["statusDot", "model", "stepCount", "progressBar",
                        "ring", "credit", "age"])

        view.graphicContextIcon = false
        XCTAssertEqual(view.taskSecondLineSegments,
                       ["statusDot", "model", "stepCount", "progressBar",
                        "ringGlyph", "credit", "age"])
    }
}

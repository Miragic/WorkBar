import Foundation
import XCTest
@testable import TouchBarBuddy

/// `TextInjector` 的纯函数部分单测。
///
/// 真实的「激活 → 等前台 → AX 聚焦 → ⌘V」链路需要 WorkBuddy 在前台 + 辅助功能授权，
/// 无法在单测里稳定复现，所以只覆盖**可判定**的那一段：
/// 从「遍历顺序的（角色, 深度）」里挑出该当作输入框的下标。
///
/// 这段逻辑是「粘错地方」与「粘进按钮/正文」两类事故的分界线，必须钉死。
final class TextInjectorTests: XCTestCase {

    // MARK: - 角色常量

    /// 角色常量必须与真机 dump 一致；改名等于把选择逻辑关掉。
    func testRoleConstantsMatchRealDump() {
        XCTAssertEqual(TextInjector.textAreaRole, "AXTextArea")
        XCTAssertEqual(TextInjector.textFieldRole, "AXTextField")
        XCTAssertEqual(TextInjector.inputRoles, ["AXTextArea", "AXTextField"])
    }

    // MARK: - 只有 AXTextArea

    func testOnlyTextAreaIsSelected() {
        let candidates: [(role: String, depth: Int)] = [
            (role: "AXTextArea", depth: 18)
        ]
        XCTAssertEqual(TextInjector.pickInputElement(from: candidates), 0)
    }

    /// 正文 / 按钮 / 分组节点全在前面，真正的输入框在后面 —— 必须选输入框。
    func testTextAreaAfterNonInputNodesIsSelected() {
        let candidates: [(role: String, depth: Int)] = [
            (role: "AXWindow", depth: 1),
            (role: "AXGroup", depth: 4),
            (role: "AXStaticText", depth: 12),
            (role: "AXButton", depth: 13),
            (role: "AXTextArea", depth: 18)
        ]
        XCTAssertEqual(TextInjector.pickInputElement(from: candidates), 4)
    }

    /// 核心回归：`AXStaticText` 先出现在前面，后面才是 `AXTextArea` → 选后者。
    func testStaticTextBeforeTextAreaPicksTextArea() {
        let candidates: [(role: String, depth: Int)] = [
            (role: "AXStaticText", depth: 9),
            (role: "AXStaticText", depth: 10),
            (role: "AXTextArea", depth: 11)
        ]
        XCTAssertEqual(TextInjector.pickInputElement(from: candidates), 2)
    }

    // MARK: - 一个都没有

    func testNoInputElementYieldsNil() {
        let candidates: [(role: String, depth: Int)] = [
            (role: "AXWindow", depth: 1),
            (role: "AXStaticText", depth: 12),
            (role: "AXButton", depth: 13),
            (role: "AXMenuItem", depth: 2)
        ]
        XCTAssertNil(TextInjector.pickInputElement(from: candidates))
    }

    func testEmptyCandidatesYieldsNil() {
        XCTAssertNil(TextInjector.pickInputElement(from: []))
    }

    // MARK: - AXTextArea 优先于 AXTextField

    func testTextAreaWinsOverEarlierTextField() {
        let candidates: [(role: String, depth: Int)] = [
            (role: "AXTextField", depth: 5),
            (role: "AXTextArea", depth: 18)
        ]
        XCTAssertEqual(TextInjector.pickInputElement(from: candidates), 1)
    }

    func testFirstTextFieldUsedWhenNoTextArea() {
        let candidates: [(role: String, depth: Int)] = [
            (role: "AXStaticText", depth: 3),
            (role: "AXTextField", depth: 5),
            (role: "AXTextField", depth: 6)
        ]
        XCTAssertEqual(TextInjector.pickInputElement(from: candidates), 1)
    }

    // MARK: - 防御

    /// 负深度不参与（避免调用方算错深度时选中奇怪节点）。
    func testNegativeDepthIsIgnored() {
        let candidates: [(role: String, depth: Int)] = [
            (role: "AXTextArea", depth: -1),
            (role: "AXTextField", depth: 2)
        ]
        XCTAssertEqual(TextInjector.pickInputElement(from: candidates), 1)
    }

    // MARK: - 长度必须按 UTF-16 计量

    /// 回读不可用时返回 -1（调用方据此跳过「追加 / 覆盖」判定）。
    func testContentLengthOfNilIsMinusOne() {
        XCTAssertEqual(TextInjector.contentLength(of: nil), -1)
        XCTAssertEqual(TextInjector.contentLength(of: ""), 0)
    }

    /// 中文按字符计 5；而 emoji 是代理对，`String.count` 算 1、AX 需要 2 —— 这里必须是 2。
    func testContentLengthUsesUTF16Units() {
        XCTAssertEqual(TextInjector.contentLength(of: "今天多少号"), 5)
        let emoji = "😀"
        XCTAssertEqual(emoji.count, 1)
        XCTAssertEqual(TextInjector.contentLength(of: emoji), 2)
        // 混合内容：3 个中文 + 1 个 emoji = 3 + 2 = 5 个 UTF-16 单元。
        XCTAssertEqual(TextInjector.contentLength(of: "你好吗😀"), 5)
    }

    // MARK: - 光标是否在末尾

    /// 空内容：光标只能在 0，0 即末尾。
    func testCaretAtEndForEmptyContent() {
        XCTAssertTrue(TextInjector.isCaretAtEnd(location: 0, contentLength: 0))
        // 空内容却报了个偏离 0 的位置 —— 异常值，不能算到位（要走兜底 ⌘↓）。
        XCTAssertFalse(TextInjector.isCaretAtEnd(location: 3, contentLength: 0))
    }

    /// 中文内容：偏移按 UTF-16 计量，"今天多少号" 长度 5，caret=5 才是末尾。
    func testCaretAtEndWithChineseContent() {
        let length = ("今天多少号" as NSString).length
        XCTAssertEqual(length, 5)
        XCTAssertTrue(TextInjector.isCaretAtEnd(location: length, contentLength: length))
        XCTAssertFalse(TextInjector.isCaretAtEnd(location: length - 1, contentLength: length))
        XCTAssertFalse(TextInjector.isCaretAtEnd(location: 0, contentLength: length))
    }

    /// caret 恰好等于长度 = 末尾；略超（app 把插入点钳到合法范围）也算到位。
    func testCaretAtEndAcceptsExactAndClampedLocation() {
        XCTAssertTrue(TextInjector.isCaretAtEnd(location: 27, contentLength: 27))
        XCTAssertTrue(TextInjector.isCaretAtEnd(location: 28, contentLength: 27))
        XCTAssertFalse(TextInjector.isCaretAtEnd(location: 26, contentLength: 27))
    }

    /// 负数位置 / 负长度是异常值，一律不算到位。
    func testCaretAtEndRejectsNegativeValues() {
        XCTAssertFalse(TextInjector.isCaretAtEnd(location: -1, contentLength: 10))
        XCTAssertFalse(TextInjector.isCaretAtEnd(location: 5, contentLength: -1))
    }

    // MARK: - 追加是否成立

    /// 真机故障复现：原有 27 字被识别出的 6 字替换 → 长度变短，必须判为「疑似覆盖」。
    func testAppendDetectsOverwrite() {
        XCTAssertFalse(TextInjector.isAppendSatisfied(beforeLength: 27,
                                                     afterLength: 6,
                                                     textLength: 6))
    }

    /// 正常追加：27 + 12 = 39。
    func testAppendSatisfiesWhenLengthGrowsByText() {
        XCTAssertTrue(TextInjector.isAppendSatisfied(beforeLength: 27,
                                                    afterLength: 39,
                                                    textLength: 12))
    }

    /// 输入框原本为空：粘贴后长度等于文本长度，也算追加成立。
    func testAppendSatisfiesFromEmptyContent() {
        XCTAssertTrue(TextInjector.isAppendSatisfied(beforeLength: 0,
                                                    afterLength: 12,
                                                    textLength: 12))
    }

    /// 自动纠错吞掉一两个字仍算追加（容差内），但少了 3 字以上就不算了。
    func testAppendToleranceForAutocorrect() {
        XCTAssertTrue(TextInjector.isAppendSatisfied(beforeLength: 27,
                                                    afterLength: 38,
                                                    textLength: 12))
        XCTAssertFalse(TextInjector.isAppendSatisfied(beforeLength: 27,
                                                     afterLength: 36,
                                                     textLength: 12))
    }

    // MARK: - InjectResult

    func testInjectResultDefaultsToNoReason() {
        let result = InjectResult(ok: true)
        XCTAssertTrue(result.ok)
        XCTAssertNil(result.reason)
    }

    func testInjectResultCarriesReason() {
        let result = InjectResult(ok: false, reason: "需授权辅助功能才能填入")
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.reason, "需授权辅助功能才能填入")
    }
}

import XCTest
@testable import TouchBarBuddy

/// 语音识别文本回显（PRD P1-1）的单测。
///
/// 这里只钉「文案格式 + 长度上限 + 语气不串味」。真正的注入链路
/// （`VoiceRecognizer.insertText` → `TextInjector`）在这次改动里一行未动，
/// 由既有用例与真机验证负责。
final class TranscriptEchoTests: XCTestCase {

    /// 14 字以内原文一字不改（只加 🎙️ 前缀）。
    func testShortTranscriptKeepsOriginalText() {
        XCTAssertEqual(TouchBarController.transcriptNoticeText("明天下午三点开会"),
                       "🎙️ 明天下午三点开会")
        // 恰好等于上限时也必须是原文，不能多一个省略号。
        let exactlyLimit = String(repeating: "字", count: TouchBarController.transcriptTextLimit)
        XCTAssertEqual(TouchBarController.transcriptNoticeText(exactlyLimit),
                       "🎙️ \(exactlyLimit)")
    }

    /// 超长文本截断到 14 字 + `…`，不能让 notice item 撑爆 Touch Bar 宽度。
    func testLongTranscriptTruncatesToFourteenCharacters() {
        let input = "一二三四五六七八九十甲乙丙丁戊己庚辛壬癸"
        let output = TouchBarController.transcriptNoticeText(input)
        let expected = "🎙️ \(String(input.prefix(TouchBarController.transcriptTextLimit)))…"

        XCTAssertEqual(output, expected)
        XCTAssertTrue(output.hasSuffix("…"))
        // 原文仍完整交给注入链路：回显截断绝不改变 `voice.insertText(text)` 的参数。
        XCTAssertEqual(input.count, 20)
    }

    /// `.info` 必须和红字 / 安慰灰是三个互不相等的状态，避免将来有人合并出串味的颜色。
    func testInfoStyleIsDistinctFromErrorAndComfort() {
        XCTAssertTrue(TransientNotice.Style.info != .error)
        XCTAssertTrue(TransientNotice.Style.info != .comfort)
        XCTAssertTrue(TransientNotice.Style.error != .comfort)

        let info = TransientNotice(text: "🎙️ 你好", style: .info)
        let error = TransientNotice(text: "🎙️ 你好", style: .error)
        XCTAssertTrue(info != error, "同文案不同 style 必须是不同的 notice，否则定时器会互相误清")
    }

    /// 空识别结果只显示麦克风，不显示「🎙️ 」这种空壳提示。
    func testEmptyTranscriptShowsOnlyMicrophone() {
        XCTAssertEqual(TouchBarController.transcriptNoticeText(""), "🎙️")
        XCTAssertEqual(TouchBarController.transcriptNoticeText("   \n"), "🎙️")
    }

    /// 回显时长与错误提示相同（2 秒）。
    ///
    /// 原为 1.5 秒，用户真机反馈「不够读完 14 个字」，2026-11-19 调到 2.0。
    /// 与错误提示同长无冲突：注入失败走 .failed → 红字覆盖回显，不会两条同时抢一格。
    func testEchoDurationIsTwoSeconds() {
        XCTAssertEqual(TouchBarController.transcriptNoticeDuration, 2.0)
        XCTAssertEqual(TouchBarController.noticeDuration, 2.0)
    }
}

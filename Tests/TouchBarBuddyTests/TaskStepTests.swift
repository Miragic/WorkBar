import Foundation
import XCTest
@testable import TouchBarBuddy

/// 任务步骤（`~/.workbuddy/tasks/<session_id>/*.json`）的格式化与读取单测。
final class TaskStepTests: XCTestCase {

    // MARK: - 文案规则

    func testSegmentTextWithCurrentStep() {
        let p = TaskStepProgress(total: 8, done: 3, current: "核实博主粉丝数")
        XCTAssertEqual(TaskStep.segmentText(p), "3/8 核实博主粉丝数")
    }

    func testSegmentTextWithoutCurrentStep() {
        let p = TaskStepProgress(total: 8, done: 8, current: nil)
        XCTAssertEqual(TaskStep.segmentText(p), "8/8")
    }

    /// 只有 1 步时「1/1」不是进度，不该占宽度。
    func testSingleStepIsHidden() {
        let p = TaskStepProgress(total: 1, done: 1, current: "只做一件事")
        XCTAssertNil(TaskStep.segmentText(p))
        XCTAssertNil(TaskStep.segmentText(TaskStepProgress(total: 0, done: 0, current: nil)))
    }

    /// 步骤名要裁到 8 字并补省略号，否则 24 字的 subject 能把整行挤爆。
    func testLongSubjectIsTruncated() {
        XCTAssertEqual(TaskStep.truncate("核实待核实档博主的精确粉丝数"), "核实待核实档博主…")
        XCTAssertEqual(TaskStep.truncate("短名字"), "短名字")
    }

    /// 换行混进 subject 会把单行 label 撑高，必须归一成空格。
    func testNewlineInSubjectBecomesSpace() {
        let p = TaskStepProgress(total: 4, done: 1, current: "写 PRD\n评审")
        XCTAssertEqual(TaskStep.segmentText(p), "1/4 写 PRD 评审")
    }

    // MARK: - 读取与缓存

    private func makeStepFile(_ dir: String,
                              index: Int,
                              subject: String,
                              status: String,
                              stamp: Int) {
        let object: [String: Any] = [
            "subject": subject,
            "description": "",
            "activeForm": subject,
            "status": status,
            "id": "\(index)",
            "createdAt": stamp,
            "updatedAt": stamp
        ]
        let data = try? JSONSerialization.data(withJSONObject: object)
        let path = (dir as NSString).appendingPathComponent("\(index).json")
        try? data?.write(to: URL(fileURLWithPath: path))
    }

    func testReaderParsesStepsAndCurrent() {
        let root = NSTemporaryDirectory() + "tb-steps-\(UUID().uuidString)"
        let dir = (root as NSString).appendingPathComponent("session-1")
        try? FileManager.default.createDirectory(atPath: dir,
                                                 withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        makeStepFile(dir, index: 1, subject: "第一步", status: "completed", stamp: 100)
        makeStepFile(dir, index: 2, subject: "第二步", status: "completed", stamp: 200)
        makeStepFile(dir, index: 3, subject: "正在做的第三步", status: "in_progress", stamp: 300)
        makeStepFile(dir, index: 4, subject: "第四步", status: "pending", stamp: 400)

        let reader = TaskStepReader(root: root)
        guard let p = reader.progress(forSessionID: "session-1") else {
            return XCTFail("应该读到步骤")
        }
        XCTAssertEqual(p.total, 4)
        XCTAssertEqual(p.done, 2)
        XCTAssertEqual(p.current, "正在做的第三步")
        XCTAssertEqual(TaskStep.segmentText(p), "2/4 正在做的第三步")
    }

    /// 多条 in_progress 是脏数据，取 updatedAt 最近的那条，别随机取。
    func testReaderPicksLatestInProgress() {
        let root = NSTemporaryDirectory() + "tb-steps-\(UUID().uuidString)"
        let dir = (root as NSString).appendingPathComponent("session-1")
        try? FileManager.default.createDirectory(atPath: dir,
                                                 withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        makeStepFile(dir, index: 1, subject: "旧的进行中", status: "in_progress", stamp: 100)
        makeStepFile(dir, index: 2, subject: "新的进行中", status: "in_progress", stamp: 999)

        let p = TaskStepReader(root: root).progress(forSessionID: "session-1")
        XCTAssertEqual(p?.current, "新的进行中")
    }

    /// 修改已有文件不会改父目录 mtime，所以缓存签名必须包含**每个文件的 mtime**。
    func testCacheInvalidatesOnFileChange() {
        let root = NSTemporaryDirectory() + "tb-steps-\(UUID().uuidString)"
        let dir = (root as NSString).appendingPathComponent("session-1")
        try? FileManager.default.createDirectory(atPath: dir,
                                                 withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        makeStepFile(dir, index: 1, subject: "第一步", status: "in_progress", stamp: 100)
        makeStepFile(dir, index: 2, subject: "第二步", status: "pending", stamp: 200)

        let reader = TaskStepReader(root: root)
        XCTAssertEqual(reader.progress(forSessionID: "session-1")?.done, 0)

        // 原地改写第一个文件；目录 mtime 不变。
        // subject 也改长一点：文件系统 mtime 分辨率有限，同一秒内两次写入可能相等，
        // 文件大小变化保证签名一定不同（签名同时含 mtime 与 size）。
        makeStepFile(dir, index: 1, subject: "第一步已经做完了", status: "completed", stamp: 999)
        XCTAssertEqual(reader.progress(forSessionID: "session-1")?.done, 1,
                       "文件改了但缓存没失效")
    }

    func testMissingDirectoryReturnsNil() {
        let root = NSTemporaryDirectory() + "tb-steps-\(UUID().uuidString)"
        XCTAssertNil(TaskStepReader(root: root).progress(forSessionID: "no-such-session"))
    }

    /// 路径分隔符必须被挡住，防止拼出 root 之外的路径。
    func testSessionIDWithSlashIsRejected() {
        let root = NSTemporaryDirectory() + "tb-steps-\(UUID().uuidString)"
        XCTAssertNil(TaskStepReader(root: root).progress(forSessionID: "../etc"))
    }
}

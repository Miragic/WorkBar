import Foundation

/// 极简 XCTest 兼容层（仅测试用，不参与 App 构建）。
///
/// 为什么需要它：本机 `swift build` / `swift test` 因 SwiftPM 的 `PackageDescription`
/// 模块 ABI 断裂而不可用（`Package.swift` 的 manifest 链接阶段就失败）；同时 Command Line
/// Tools 里只随附了 `Testing.framework`，**没有 XCTest.framework**，所以既跑不了 `swift test`，
/// 也无法直接 `import XCTest`。
///
/// 为了不把已有的单元测试变成「只编写、不执行」的装饰，这里提供测试实际用到的最小 API 子集
/// （`XCTestCase` + 5 个断言 + `XCTFail`）。测试文件由 `Scripts/run-tests.sh` 复制到临时目录、
/// 去掉 `import XCTest` / `@testable import TouchBarBuddy` 后与源码同模块编译 ——
/// 于是 `internal` API 也能直接访问，等价于 `@testable import` 的效果。

/// 断言失败收集器。
enum XCTestSupport {
    /// 当前正在执行的测试名（由 runner 在调用前设置，用于给失败信息加前缀）。
    static var currentTest: String = ""
    /// 已记录的失败（描述、文件、行号）。
    static var failures: [(message: String, file: String, line: UInt)] = []
}

/// 记录一条失败。
private func xcRecordFailure(_ message: String,
                             _ file: StaticString,
                             _ line: UInt) {
    XCTestSupport.failures.append((message: message, file: "\(file)", line: line))
}

/// 测试基类（只提供 setUp / tearDown 钩子，供子类 override）。
class XCTestCase {
    init() {}

    /// 每个测试方法执行前调用。
    func setUp() {}

    /// 每个测试方法执行后调用。
    func tearDown() {}
}

/// 无条件失败。
func XCTFail(_ message: @autoclosure () -> String = "",
             file: StaticString = #filePath,
             line: UInt = #line) {
    let text = message()
    xcRecordFailure(text.isEmpty ? "XCTFail" : text, file, line)
}

/// 断言两值相等（`Equatable`）。
func XCTAssertEqual<T: Equatable>(_ expression1: @autoclosure () -> T,
                                  _ expression2: @autoclosure () -> T,
                                  _ message: @autoclosure () -> String = "",
                                  file: StaticString = #filePath,
                                  line: UInt = #line) {
    let lhs = expression1()
    let rhs = expression2()
    guard lhs != rhs else { return }
    let extra = message()
    let suffix = extra.isEmpty ? "" : " — \(extra)"
    xcRecordFailure("XCTAssertEqual 失败: \(lhs) != \(rhs)\(suffix)", file, line)
}

/// 断言为真。
func XCTAssertTrue(_ expression: @autoclosure () -> Bool,
                   _ message: @autoclosure () -> String = "",
                   file: StaticString = #filePath,
                   line: UInt = #line) {
    guard !expression() else { return }
    let extra = message()
    let suffix = extra.isEmpty ? "" : " — \(extra)"
    xcRecordFailure("XCTAssertTrue 失败\(suffix)", file, line)
}

/// 断言为假。
func XCTAssertFalse(_ expression: @autoclosure () -> Bool,
                    _ message: @autoclosure () -> String = "",
                    file: StaticString = #filePath,
                    line: UInt = #line) {
    guard expression() else { return }
    let extra = message()
    let suffix = extra.isEmpty ? "" : " — \(extra)"
    xcRecordFailure("XCTAssertFalse 失败\(suffix)", file, line)
}

/// 断言为 nil。
func XCTAssertNil(_ expression: @autoclosure () -> Any?,
                  _ message: @autoclosure () -> String = "",
                  file: StaticString = #filePath,
                  line: UInt = #line) {
    guard let value = expression() else { return }
    let extra = message()
    let suffix = extra.isEmpty ? "" : " — \(extra)"
    xcRecordFailure("XCTAssertNil 失败: 实际为 \(value)\(suffix)", file, line)
}

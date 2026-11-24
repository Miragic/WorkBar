// swift-tools-version:5.9
import PackageDescription

// 采用「库 target(全部逻辑) + 瘦可执行 target(仅入口) + 测试 target」的结构：
// - `TouchBarBuddy`（library）：Models / Provider / StateMachine / TouchBar / Voice / AppDelegate
// - `TouchBarBuddyApp`（executable）：仅 main.swift 装配入口
// - `TouchBarBuddyTests`：对核心逻辑做单元测试（@testable import TouchBarBuddy）
//
// 说明：相比原始设想的「单一可执行 target」，把逻辑拆到 library 是为了让测试可稳定
// `@testable import`，避免把含顶层代码的 main.swift 链进测试进程（详见回传说明）。
let package = Package(
    name: "touchbar-buddy",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "touchbar-buddy", targets: ["TouchBarBuddyApp"]),
        .library(name: "TouchBarBuddy", targets: ["TouchBarBuddy"])
    ],
    targets: [
        .target(
            name: "TouchBarBuddy",
            path: "Sources/TouchBarBuddy"
        ),
        .executableTarget(
            name: "TouchBarBuddyApp",
            dependencies: ["TouchBarBuddy"],
            path: "Sources/TouchBarBuddyApp"
        ),
        .testTarget(
            name: "TouchBarBuddyTests",
            dependencies: ["TouchBarBuddy"],
            path: "Tests/TouchBarBuddyTests"
        )
    ]
)

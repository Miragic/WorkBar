import AppKit
import TouchBarBuddy

// 程序入口：装配 NSApplication 与 AppDelegate 后进入事件循环。
// LSUIElement（accessory）策略：不占 Dock、不成为前台 app。
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()

import AppKit

// 无 storyboard/xib 的 LSUIElement app：必须显式挂 delegate，
// 仅靠 @main/NSApplicationMain 不会设置 NSApp.delegate。
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

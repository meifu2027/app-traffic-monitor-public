import NetworkExtension

// 系统扩展是独立可执行文件：入口把控制权交给 NetworkExtension 框架，
// 框架按 Info.plist 的 NSExtensionPrincipalClass 实例化 FilterDataProvider。
NEProvider.startSystemExtensionMode()

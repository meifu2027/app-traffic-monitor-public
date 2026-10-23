import Foundation

/// 进程路径 → 最外层 .app bundle 路径提取。
///
/// 规则（PROMPT §3）：尽可能按 Bundle 合并同一应用的 Helper、XPC 和子进程——
/// 取路径中**最外层**（第一个）`.app` 组件，因此
/// `/Applications/Google Chrome.app/Contents/Frameworks/... Helper.app/Contents/MacOS/...`
/// 归并为 `/Applications/Google Chrome.app`。
/// 不在任何 .app 内的进程（CLI、守护进程）返回 nil，按未归属处理。
public enum AppBundlePathExtractor {
    public static func extract(from processPath: String) -> String? {
        let parts = processPath.split(separator: "/", omittingEmptySubsequences: true)
        for (index, part) in parts.enumerated() where part.hasSuffix(".app") {
            return "/" + parts[0...index].joined(separator: "/")
        }
        return nil
    }
}

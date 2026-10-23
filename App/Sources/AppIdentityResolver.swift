import AppKit
import StatsCore

/// 进程路径 → 应用展示身份（名称/图标）解析器。
///
/// app_key 使用最外层 .app 的路径（AppBundlePathExtractor）；展示名与图标按需解析并
/// 有界缓存（资源规则 §9：图标解析不在采集回调里做，容量上限后整体重建）。
final class AppIdentityResolver {

    struct Identity {
        let appKey: String
        let displayName: String
        let icon: NSImage
    }

    private var cache: [String: Identity] = [:]
    private let maxCacheCount = 500

    /// 归属进程路径 → app_key；不属于任何 .app 的进程返回 ""（未归属）。
    static func appKey(processPath: String?) -> String {
        guard let path = processPath, !path.isEmpty else { return "" }
        return AppBundlePathExtractor.extract(from: path) ?? ""
    }

    func identity(appKey: String) -> Identity? {
        guard !appKey.isEmpty else { return nil }
        if let hit = cache[appKey] { return hit }
        guard let identity = build(appKey: appKey) else { return nil }
        if cache.count >= maxCacheCount { cache.removeAll() }
        cache[appKey] = identity
        return identity
    }

    private func build(appKey: String) -> Identity? {
        let url = URL(fileURLWithPath: appKey)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: appKey, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }

        let bundle = Bundle(url: url)
        let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent

        let icon = NSWorkspace.shared.icon(forFile: appKey)
        icon.size = NSSize(width: 20, height: 20)
        return Identity(appKey: appKey, displayName: name, icon: icon)
    }
}

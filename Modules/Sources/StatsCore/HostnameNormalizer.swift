//! 统计核心模块：计数归一化、时间归桶、速率与目标规范化。
//! 不依赖 AppKit 与 NetworkExtension（DEVELOPMENT_PLAN §2.1）。

import Foundation
import SharedContracts

/// 目标主机名规范化。
///
/// 需求口径（PROMPT §7、DEVELOPMENT_PLAN §2.3）：
/// - 统一小写；
/// - 去除末尾点；
/// - 保留完整子域名，不合并主域；
/// - 无法得到可用主机名时返回 nil，由调用方改用 IP 键或未知端点键。
public enum HostnameNormalizer {
    public static func normalize(_ rawHostname: String) -> String? {
        let trimmed = rawHostname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var result = Substring(trimmed.lowercased())
        while result.hasSuffix(".") {
            result = result.dropLast()
        }
        return result.isEmpty ? nil : String(result)
    }
}

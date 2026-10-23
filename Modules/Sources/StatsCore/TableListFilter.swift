import Foundation

/// 表格行列表的模糊过滤与确定性排序（「应用/域名」两页共用）。
/// 两条硬约束：
/// - 数值列必须按 Int64 原始值比较——显示值是 "1.2 MB" 这类格式化字符串，按串排序会错序；
/// - 全序必须确定：Swift 的 sort 不稳定，主键平局时按「合计降序 → 名称升序」兜底，
///   否则 1 秒自动刷新会让等值行来回跳动。
public enum TableListFilter {

    /// 列语义排序键（NSTableColumn 标识 ↔ 语义的映射在控制器完成）。
    public enum SortKey: String {
        case name, kind, route
        case upload, download, total
    }

    public struct Sort: Equatable {
        public let key: SortKey
        public let ascending: Bool

        public init(key: SortKey, ascending: Bool) {
            self.key = key
            self.ascending = ascending
        }

        /// 列表默认序：合计降序（沿用历史行为）。
        public static let byTotalDesc = Sort(key: .total, ascending: false)
    }

    /// 模糊子串匹配：query 去除首尾空白后为空 → 恒真（不过滤）；
    /// 否则任一文本命中即匹配（大小写/变音符不敏感，按本地化规则）。
    public static func fuzzyMatches(_ texts: [String], query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return texts.contains { $0.localizedCaseInsensitiveContains(trimmed) }
    }

    /// 按查询词过滤行。texts 提供每行的可搜索文本
    /// （应用页 = 显示名 + appKey 路径；域名/下钻页 = 目标显示文本）。
    public static func filteredInstances<Input>(
        _ rows: [Input], query: String, texts: (Input) -> [String]
    ) -> [Input] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return rows }
        return rows.filter { fuzzyMatches(texts($0), query: trimmed) }
    }

    /// 按排序重排（确定性全序，见类型注释）。text/number 按键取值，不适用的键返回 nil。
    public static func sortedInstances<Input>(
        _ rows: [Input], by sort: Sort,
        text: (Input, SortKey) -> String?,
        number: (Input, SortKey) -> Int64?
    ) -> [Input] {
        rows.sorted { lhs, rhs in
            let primary = primaryOrder(lhs, rhs, sort: sort, text: text, number: number)
            if primary != .orderedSame { return primary == .orderedAscending }

            // 平局兜底一：合计降序（与默认序一致，大流量在前）
            let lhsTotal = number(lhs, .total) ?? 0
            let rhsTotal = number(rhs, .total) ?? 0
            if lhsTotal != rhsTotal { return lhsTotal > rhsTotal }

            // 平局兜底二：名称升序；名称也不分先后则视为相等，行序随输入序（内容一致的行无视觉差异）
            let lhsName = text(lhs, .name) ?? ""
            let rhsName = text(rhs, .name) ?? ""
            return lhsName.compare(rhsName, options: .caseInsensitive) == .orderedAscending
        }
    }

    private static func primaryOrder<Input>(
        _ lhs: Input, _ rhs: Input, sort: Sort,
        text: (Input, SortKey) -> String?,
        number: (Input, SortKey) -> Int64?
    ) -> ComparisonResult {
        switch sort.key {
        case .upload, .download, .total:
            let l = number(lhs, sort.key) ?? 0
            let r = number(rhs, sort.key) ?? 0
            if l == r { return .orderedSame }
            return (l < r) == sort.ascending ? .orderedAscending : .orderedDescending
        case .name, .kind, .route:
            // localizedStandardCompare 只有升序语义，降序按需反向
            let base = (text(lhs, sort.key) ?? "")
                .localizedStandardCompare(text(rhs, sort.key) ?? "")
            switch base {
            case .orderedAscending: return sort.ascending ? .orderedAscending : .orderedDescending
            case .orderedDescending: return sort.ascending ? .orderedDescending : .orderedAscending
            case .orderedSame: return .orderedSame
            }
        }
    }
}

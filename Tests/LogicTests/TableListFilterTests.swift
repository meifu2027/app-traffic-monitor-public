import XCTest
import StatsCore

/// TableListFilter（表格行模糊过滤 + 确定性排序）纯逻辑用例。
/// 对应 App 侧「应用/域名」两页的搜索框与表头排序；NSTableView 装配不在本测试范围。
final class TableListFilterTests: XCTestCase {

    private struct Row: Equatable {
        let name: String
        let kind: String
        let route: String
        let upload: Int64
        let download: Int64
        var total: Int64 { upload + download }
    }

    private func text(_ row: Row, _ key: TableListFilter.SortKey) -> String? {
        switch key {
        case .name: return row.name
        case .kind: return row.kind
        case .route: return row.route
        default: return nil
        }
    }

    private func number(_ row: Row, _ key: TableListFilter.SortKey) -> Int64? {
        switch key {
        case .upload: return row.upload
        case .download: return row.download
        case .total: return row.total
        default: return nil
        }
    }

    private func sorted(_ rows: [Row], by sort: TableListFilter.Sort) -> [Row] {
        TableListFilter.sortedInstances(rows, by: sort, text: text, number: number)
    }

    /// 可搜索文本 = 显示名 + 路由（模拟应用页的 显示名/appKey 双文本）
    private func filtered(_ rows: [Row], query: String) -> [Row] {
        TableListFilter.filteredInstances(rows, query: query) { [$0.name, $0.route] }
    }

    // MARK: - 模糊过滤

    func testFilterWithBlankQueryKeepsAllRows() {
        let rows = [Row(name: "Safari", kind: "domain", route: "proxy", upload: 1, download: 2)]
        XCTAssertEqual(filtered(rows, query: ""), rows)
        XCTAssertEqual(filtered(rows, query: "   \n "), rows)
    }

    func testFilterMatchesCaseInsensitiveSubstringAnywhere() {
        let rows = [
            Row(name: "github.com", kind: "domain", route: "proxy", upload: 1, download: 1),
            Row(name: "baidu.com", kind: "domain", route: "direct", upload: 1, download: 1),
        ]
        // 中段子串 + 大小写不敏感（非前缀匹配）
        XCTAssertEqual(filtered(rows, query: "HUB").map(\.name), ["github.com"])
    }

    func testFilterMatchesAnySearchableText() {
        let rows = [
            Row(name: "访客浏览器", kind: "domain", route: "proxy", upload: 1, download: 1),
        ]
        XCTAssertEqual(filtered(rows, query: "PROXY").count, 1)
        XCTAssertEqual(filtered(rows, query: "浏览器").count, 1)
        XCTAssertEqual(filtered(rows, query: "chrome").count, 0)
    }

    // MARK: - 排序

    func testNumericSortComparesRawInt64NotFormattedStrings() {
        // 格式化后为 "999 B" < "1.0 KB" < "1.00 MB"，按字符串排序会错序（"1.00..." 最小）
        let rows = [
            Row(name: "b", kind: "domain", route: "proxy", upload: 999, download: 0),
            Row(name: "c", kind: "domain", route: "proxy", upload: 1_000_000, download: 0),
            Row(name: "a", kind: "domain", route: "proxy", upload: 1_000, download: 0),
        ]
        XCTAssertEqual(sorted(rows, by: .init(key: .upload, ascending: false)).map(\.upload),
                       [1_000_000, 1_000, 999])
        XCTAssertEqual(sorted(rows, by: .init(key: .upload, ascending: true)).map(\.upload),
                       [999, 1_000, 1_000_000])
    }

    func testNameSortUsesFinderStyleNaturalOrder() {
        let rows = [
            Row(name: "Safari 10", kind: "domain", route: "proxy", upload: 1, download: 1),
            Row(name: "Safari 2", kind: "domain", route: "proxy", upload: 1, download: 1),
        ]
        // 纯字符串序会是 "Safari 10" < "Safari 2"，自然序应按数字感知
        XCTAssertEqual(sorted(rows, by: .init(key: .name, ascending: true)).map(\.name),
                       ["Safari 2", "Safari 10"])
        XCTAssertEqual(sorted(rows, by: .init(key: .name, ascending: false)).map(\.name),
                       ["Safari 10", "Safari 2"])
    }

    func testSortTieBreaksByTotalDescThenNameAscDeterministically() {
        let rows = [
            Row(name: "b", kind: "domain", route: "proxy", upload: 100, download: 500),  // total 600
            Row(name: "a", kind: "domain", route: "proxy", upload: 100, download: 900),  // total 1000
            Row(name: "z", kind: "domain", route: "proxy", upload: 100, download: 900),  // total 1000
        ]
        // 同 upload：合计降序；同合计：名称升序
        XCTAssertEqual(sorted(rows, by: .init(key: .upload, ascending: false)).map(\.name),
                       ["a", "z", "b"])
        // Swift sort 不稳定：输入序打乱后结果必须不变（否则 1 秒刷新行序抖动）
        XCTAssertEqual(sorted(Array(rows.reversed()), by: .init(key: .upload, ascending: false)).map(\.name),
                       ["a", "z", "b"])
    }

    func testKindAndRouteColumnsSortByText() {
        let rows = [
            Row(name: "x1", kind: "ip", route: "direct", upload: 1, download: 1),
            Row(name: "x2", kind: "domain", route: "proxy", upload: 1, download: 1),
            Row(name: "x3", kind: "domain", route: "unknown", upload: 1, download: 1),
        ]
        XCTAssertEqual(sorted(rows, by: .init(key: .kind, ascending: true)).map(\.kind),
                       ["domain", "domain", "ip"])
        XCTAssertEqual(sorted(rows, by: .init(key: .route, ascending: true)).map(\.route),
                       ["direct", "proxy", "unknown"])
    }

    func testDefaultSortConstantIsTotalDescending() {
        XCTAssertEqual(TableListFilter.Sort.byTotalDesc, .init(key: .total, ascending: false))
    }
}

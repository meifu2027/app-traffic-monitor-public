import XCTest
import Storage
import StatsCore

final class TrafficStoreTests: XCTestCase {
    private var store: TrafficStore!
    private var url: URL!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("atm-test-\(UUID().uuidString).sqlite")
        store = try TrafficStore(url: url)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: url)
    }

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private var minuteBucket: Int64 {
        Int64(t0.timeIntervalSince1970 / 60) * 60
    }

    func testUpsertAccumulatesSameKey() throws {
        try store.upsertMinute([.init(bucket: minuteBucket, appKey: "/Applications/A.app", kind: "domain",
                                      key: "a.com", route: "proxy", upload: 100, download: 500)])
        try store.upsertMinute([.init(bucket: minuteBucket, appKey: "/Applications/A.app", kind: "domain",
                                      key: "a.com", route: "proxy", upload: 30, download: 70)])
        let usage = try store.targetUsage(from: t0.addingTimeInterval(-60), to: t0.addingTimeInterval(120))
        XCTAssertEqual(usage, [.init(kind: "domain", key: "a.com", route: "proxy", upload: 130, download: 570)])
    }

    func testSameTargetDifferentRouteOrAppAreSeparate() throws {
        try store.upsertMinute([
            .init(bucket: minuteBucket, appKey: "/Applications/A.app", kind: "domain", key: "a.com",
                  route: "proxy", upload: 10, download: 0),
            .init(bucket: minuteBucket, appKey: "/Applications/A.app", kind: "domain", key: "a.com",
                  route: "direct", upload: 5, download: 0),
            .init(bucket: minuteBucket, appKey: "/Applications/B.app", kind: "domain", key: "a.com",
                  route: "proxy", upload: 3, download: 0),
        ])
        let usage = try store.targetUsage(from: t0.addingTimeInterval(-60), to: t0.addingTimeInterval(60))
        // 目标视图跨 app 聚合：proxy 10+3=13
        let proxy = usage.first { $0.route == "proxy" }
        XCTAssertEqual(proxy?.upload, 13)
        let apps = try store.appUsage(from: t0.addingTimeInterval(-60), to: t0.addingTimeInterval(60))
        XCTAssertEqual(apps.count, 2)
    }

    func testAppUsageExcludesUnattributedAndTotalsStayHonest() throws {
        try store.upsertMinute([
            .init(bucket: minuteBucket, appKey: "/Applications/A.app", kind: "domain", key: "a.com",
                  route: "proxy", upload: 10, download: 100),
            .init(bucket: minuteBucket, appKey: "", kind: "domain", key: "b.com",
                  route: "proxy", upload: 1000, download: 2000),
        ])
        let apps = try store.appUsage(from: t0.addingTimeInterval(-60), to: t0.addingTimeInterval(60))
        XCTAssertEqual(apps.map(\.appKey), ["/Applications/A.app"])
        let unattributed = try store.unattributedTotals(from: t0.addingTimeInterval(-60),
                                                        to: t0.addingTimeInterval(60))
        XCTAssertEqual(unattributed.upload, 1000)
        XCTAssertEqual(unattributed.download, 2000)
    }

    /// 下钻：只看指定 app 的目标，其他 app 的同名目标不混入。
    func testAppTargetUsageDrillDown() throws {
        try store.upsertMinute([
            .init(bucket: minuteBucket, appKey: "/Applications/A.app", kind: "domain", key: "shared.com",
                  route: "proxy", upload: 10, download: 100),
            .init(bucket: minuteBucket, appKey: "/Applications/A.app", kind: "domain", key: "shared.com",
                  route: "direct", upload: 5, download: 50),
            .init(bucket: minuteBucket, appKey: "/Applications/A.app", kind: "ip", key: "1.2.3.4",
                  route: "unknown", upload: 1, download: 2),
            .init(bucket: minuteBucket, appKey: "/Applications/B.app", kind: "domain", key: "shared.com",
                  route: "proxy", upload: 999, download: 999),
        ])
        let range = (from: t0.addingTimeInterval(-60), to: t0.addingTimeInterval(60))
        let drill = try store.appTargetUsage(appKey: "/Applications/A.app", from: range.from, to: range.to)
        XCTAssertEqual(Set(drill.map { "\($0.kind)|\($0.key)|\($0.route)" }),
                       ["domain|shared.com|proxy", "domain|shared.com|direct", "ip|1.2.3.4|unknown"])
        let proxyRow = drill.first { $0.route == "proxy" }
        XCTAssertEqual(proxyRow?.upload, 10)
        // 路由筛选生效
        let proxyOnly = try store.appTargetUsage(appKey: "/Applications/A.app", from: range.from,
                                                 to: range.to, route: "proxy")
        XCTAssertEqual(proxyOnly.count, 1)
        XCTAssertEqual(proxyOnly.first?.key, "shared.com")
        // 空路径应用（含特殊字符）安全绑定
        let weird = try store.appTargetUsage(appKey: "/App'lications/X Y.app", from: range.from, to: range.to)
        XCTAssertTrue(weird.isEmpty)
    }

    func testRangeIsHalfOpen() throws {
        try store.upsertMinute([.init(bucket: minuteBucket, appKey: "", kind: "domain", key: "a.com",
                                      route: "proxy", upload: 1, download: 1)])
        let empty = try store.targetUsage(from: t0.addingTimeInterval(-120), to: t0)
        XCTAssertTrue(empty.isEmpty)
        let included = try store.targetUsage(from: t0.addingTimeInterval(-120), to: t0.addingTimeInterval(60))
        XCTAssertEqual(included.count, 1)
    }

    func testRouteTotalsAndFilter() throws {
        try store.upsertMinute([
            .init(bucket: minuteBucket, appKey: "/Applications/A.app", kind: "domain", key: "a.com",
                  route: "proxy", upload: 100, download: 900),
            .init(bucket: minuteBucket, appKey: "", kind: "ip", key: "5.6.7.8",
                  route: "proxy", upload: 50, download: 50),
            .init(bucket: minuteBucket, appKey: "", kind: "domain", key: "b.com",
                  route: "direct", upload: 10, download: 10),
        ])
        let routes = try store.routeTotals(from: t0.addingTimeInterval(-60), to: t0.addingTimeInterval(60))
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: routes.map { ($0.route, $0.upload) }),
                       ["proxy": 150, "direct": 10])
        let all = try store.totals(from: t0.addingTimeInterval(-60), to: t0.addingTimeInterval(60))
        XCTAssertEqual(all.upload, 160)
        XCTAssertEqual(all.download, 960)
    }

    func testPruneRemovesOnlyOlderBuckets() throws {
        let oldBucket = minuteBucket - 3600
        try store.upsertMinute([
            .init(bucket: oldBucket, appKey: "", kind: "domain", key: "old.com",
                  route: "proxy", upload: 1, download: 1),
            .init(bucket: minuteBucket, appKey: "", kind: "domain", key: "new.com",
                  route: "proxy", upload: 2, download: 2),
        ])
        try store.pruneMinute(olderThan: t0.addingTimeInterval(-600))
        let usage = try store.targetUsage(from: t0.addingTimeInterval(-7200), to: t0.addingTimeInterval(7200))
        XCTAssertEqual(usage.map(\.key), ["new.com"])
    }

    // MARK: - I 线：日汇总（T10）与时序查询

    private func calendar(tz: String, firstWeekday: Int = 2) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: tz)!
        cal.firstWeekday = firstWeekday
        return cal
    }

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, tz: String) -> Date {
        calendar(tz: tz).date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    /// sqlite3 CLI 标量查询（验证表内数据/清理效果，模式同 testMigrationFromV0）。
    @discardableResult
    private func sqliteScalar(_ sql: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [url.path, sql]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func minute(of date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 / 60) * 60
    }

    func testMaintainRollupCompressesPrunesAndIsIdempotent() throws {
        let cal = calendar(tz: "Asia/Shanghai")
        let now = date(2026, 10, 19, 12, 0, tz: "Asia/Shanghai")
        let today = cal.startOfDay(for: now)
        let day1 = cal.date(byAdding: .day, value: -3, to: today)! // 10-16 完整日 → 压缩
        let day2 = cal.date(byAdding: .day, value: -2, to: today)! // 10-17 完整日 → 压缩
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)! // 前沿日 → 留分钟
        let tomorrow = cal.date(byAdding: .day, value: 1, to: today)!

        try store.upsertMinute([
            .init(bucket: minute(of: day1.addingTimeInterval(3600)), appKey: "/Applications/A.app",
                  kind: "domain", key: "a.com", route: "proxy", upload: 100, download: 500),
            .init(bucket: minute(of: day1.addingTimeInterval(3660)), appKey: "/Applications/A.app",
                  kind: "domain", key: "a.com", route: "proxy", upload: 30, download: 70),
            .init(bucket: minute(of: day2.addingTimeInterval(7200)), appKey: "/Applications/B.app",
                  kind: "domain", key: "b.com", route: "direct", upload: 10, download: 10),
            .init(bucket: minute(of: yesterday.addingTimeInterval(3600)), appKey: "/Applications/A.app",
                  kind: "domain", key: "c.com", route: "proxy", upload: 5, download: 5),
            .init(bucket: minute(of: today.addingTimeInterval(60)), appKey: "/Applications/A.app",
                  kind: "domain", key: "d.com", route: "proxy", upload: 1, download: 1),
        ])

        try store.maintainDailyRollup(now: now, calendar: cal)
        let series = try store.dayTotals(from: day1, to: tomorrow, calendar: cal)
        XCTAssertEqual(series.count, 4)
        XCTAssertEqual(series.map(\.period), [Int64(day1.timeIntervalSince1970),
                                              Int64(day2.timeIntervalSince1970),
                                              Int64(yesterday.timeIntervalSince1970),
                                              Int64(today.timeIntervalSince1970)])
        XCTAssertEqual(series[0].upload, 130) // day1 两行 upsert 累加后进日汇总
        XCTAssertEqual(series[0].download, 570)
        XCTAssertEqual(series[1].total, 20)
        XCTAssertEqual(series[2].total, 10) // 前沿日走分钟侧
        XCTAssertEqual(series[3].total, 2)

        // 分钟桶已清理至前沿（仅剩昨天 + 今天两行），日汇总两行
        XCTAssertEqual(try sqliteScalar("SELECT COUNT(*) FROM minute_bucket;"), "2")
        XCTAssertEqual(try sqliteScalar("SELECT COUNT(*) FROM daily_rollup;"), "2")
        let frontier = Int64(yesterday.timeIntervalSince1970)
        XCTAssertEqual(try sqliteScalar("SELECT MIN(bucket) >= \(frontier) FROM minute_bucket;"), "1")

        // 幂等：重跑不双计
        try store.maintainDailyRollup(now: now, calendar: cal)
        let again = try store.dayTotals(from: day1, to: tomorrow, calendar: cal)
        XCTAssertEqual(again, series)
    }

    func testDayTotalsRouteAndAppFilters() throws {
        let cal = calendar(tz: "Asia/Shanghai")
        let now = date(2026, 10, 19, 12, 0, tz: "Asia/Shanghai")
        let today = cal.startOfDay(for: now)
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!
        try store.upsertMinute([
            .init(bucket: minute(of: yesterday.addingTimeInterval(3600)), appKey: "/Applications/A.app",
                  kind: "domain", key: "a.com", route: "proxy", upload: 100, download: 100),
            .init(bucket: minute(of: yesterday.addingTimeInterval(3660)), appKey: "/Applications/A.app",
                  kind: "domain", key: "a.com", route: "direct", upload: 11, download: 11),
            .init(bucket: minute(of: yesterday.addingTimeInterval(3720)), appKey: "/Applications/B.app",
                  kind: "ip", key: "1.2.3.4", route: "proxy", upload: 5, download: 5),
        ])
        try store.maintainDailyRollup(now: now, calendar: cal)

        let proxy = try store.dayTotals(from: yesterday, to: today, route: "proxy", calendar: cal)
        XCTAssertEqual(proxy.map(\.total), [210]) // A 100/100 + B(ip) 5/5
        let direct = try store.dayTotals(from: yesterday, to: today, route: "direct", calendar: cal)
        XCTAssertEqual(direct.map(\.total), [22])
        // app_key 走参数绑定（路径含空格/引号也安全）
        let appA = try store.dayTotals(from: yesterday, to: today, appKey: "/Applications/A.app", calendar: cal)
        XCTAssertEqual(appA.map(\.total), [222])
        let weird = try store.dayTotals(from: yesterday, to: today, appKey: "/App'lications/X Y.app",
                                        calendar: cal)
        XCTAssertTrue(weird.isEmpty)
    }

    /// 多 app 聚合（统计图页签 Top 应用条形多选联动）：目标下钻与序列查询
    /// 均按集合过滤、集合内跨 app 求和；空集合语义——序列=不过滤，下钻=空。
    func testMultiAppAggregation() throws {
        let cal = calendar(tz: "Asia/Shanghai")
        let now = date(2026, 10, 19, 12, 0, tz: "Asia/Shanghai")
        let today = cal.startOfDay(for: now)
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!
        try store.upsertMinute([
            .init(bucket: minute(of: yesterday.addingTimeInterval(3600)), appKey: "/Applications/A.app",
                  kind: "domain", key: "a.com", route: "proxy", upload: 100, download: 100),
            .init(bucket: minute(of: yesterday.addingTimeInterval(3600)), appKey: "/Applications/B.app",
                  kind: "domain", key: "a.com", route: "proxy", upload: 5, download: 5),
            .init(bucket: minute(of: yesterday.addingTimeInterval(3600)), appKey: "/Applications/C.app",
                  kind: "domain", key: "a.com", route: "proxy", upload: 50, download: 50),
        ])
        try store.maintainDailyRollup(now: now, calendar: cal)
        let range = (from: yesterday, to: today)
        let ab = ["/Applications/A.app", "/Applications/B.app"]

        // 目标下钻：A+B 聚合为同一目标行，C 的 50 不混入
        let drill = try store.appTargetUsage(appKeys: ab, from: range.from, to: range.to)
        XCTAssertEqual(drill, [.init(kind: "domain", key: "a.com", route: "proxy", upload: 105, download: 105)])
        // 空集合 = 无数据；含特殊字符路径安全绑定
        XCTAssertTrue(try store.appTargetUsage(appKeys: [], from: range.from, to: range.to).isEmpty)
        XCTAssertTrue(try store.appTargetUsage(appKeys: ["/App'lications/X Y.app"],
                                               from: range.from, to: range.to).isEmpty)

        // 日序列：A+B = 210；空集合 = 不过滤（全部 310）；单 key 重载 = A 独自 200
        let days = try store.dayTotals(from: range.from, to: range.to, appKeys: ab, calendar: cal)
        XCTAssertEqual(days.map(\.total), [210])
        XCTAssertEqual(try store.dayTotals(from: range.from, to: range.to, calendar: cal).map(\.total), [310])
        XCTAssertEqual(try store.dayTotals(from: range.from, to: range.to,
                                           appKey: "/Applications/A.app", calendar: cal).map(\.total), [200])

        // 小时序列同样按集合过滤
        let hours = try store.hourTotals(from: range.from, to: range.to, appKeys: ab)
        XCTAssertEqual(hours.map(\.total), [210])
    }

    /// 跨夏令时切换日（2026-03-08 纽约 02:00→03:00，当日仅 23 小时）的日边界正确性。
    func testDayBoundariesAcrossDSTTransition() throws {
        let tz = "America/New_York"
        let cal = calendar(tz: tz)
        let now = date(2026, 3, 10, 12, 0, tz: tz)
        let d7 = date(2026, 3, 7, 0, 0, tz: tz)
        let d10 = date(2026, 3, 10, 0, 0, tz: tz)
        try store.upsertMinute([
            .init(bucket: minute(of: date(2026, 3, 7, 12, 0, tz: tz)), appKey: "/Applications/A.app",
                  kind: "domain", key: "a.com", route: "proxy", upload: 10, download: 100),
            .init(bucket: minute(of: date(2026, 3, 8, 1, 30, tz: tz)), appKey: "/Applications/A.app",
                  kind: "domain", key: "a.com", route: "proxy", upload: 20, download: 200), // EST，切换前
            .init(bucket: minute(of: date(2026, 3, 8, 12, 0, tz: tz)), appKey: "/Applications/A.app",
                  kind: "domain", key: "a.com", route: "proxy", upload: 30, download: 300), // EDT
            .init(bucket: minute(of: date(2026, 3, 9, 12, 0, tz: tz)), appKey: "/Applications/A.app",
                  kind: "domain", key: "a.com", route: "proxy", upload: 40, download: 400),
        ])
        try store.maintainDailyRollup(now: now, calendar: cal)

        let series = try store.dayTotals(from: d7, to: date(2026, 3, 11, 0, 0, tz: tz), calendar: cal)
        XCTAssertEqual(series.count, 3) // 3/7、3/8、3/9；3/10 未种数据不产出零行
        XCTAssertEqual(series[0].upload, 10) // 3/7
        XCTAssertEqual(series[1].upload, 50) // 3/8（23 小时日，切换前后都归入同一天）
        XCTAssertEqual(series[2].upload, 40) // 3/9
        // 日起点间隔：3/7→3/8 = 24h；3/8→3/9 = 23h（夏令时跳进）；3/9→3/10 = 24h
        XCTAssertEqual(series[1].period - series[0].period, 86400)
        XCTAssertEqual(series[2].period - series[1].period, 82800)
    }

    func testHourTotalsGroupsLocalHours() throws {
        // 用本地日历取整点边界作为期望值（整小时偏移时区下与 SQL 固定偏移公式一致）
        let cal = Calendar.current
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let h1 = cal.dateInterval(of: .hour, for: base)!.start
        let h2 = h1.addingTimeInterval(3600)
        try store.upsertMinute([
            .init(bucket: Int64(h1.timeIntervalSince1970) + 1500, appKey: "/Applications/A.app",
                  kind: "domain", key: "a.com", route: "proxy", upload: 1, download: 2),
            .init(bucket: Int64(h1.timeIntervalSince1970) + 3000, appKey: "/Applications/A.app",
                  kind: "domain", key: "a.com", route: "proxy", upload: 3, download: 4),
            .init(bucket: Int64(h2.timeIntervalSince1970) + 600, appKey: "/Applications/A.app",
                  kind: "domain", key: "a.com", route: "proxy", upload: 5, download: 6),
        ])
        let hours = try store.hourTotals(from: h1, to: h2.addingTimeInterval(3600))
        XCTAssertEqual(hours.count, 2)
        XCTAssertEqual(hours[0].period, Int64(h1.timeIntervalSince1970))
        XCTAssertEqual(hours[0].upload, 4)
        XCTAssertEqual(hours[1].period, Int64(h2.timeIntervalSince1970))
        XCTAssertEqual(hours[1].upload, 5)
    }

    /// v0（无 app_key）旧库打开后自动迁移：数据聚合保留、可继续写入。
    func testMigrationFromV0() throws {
        let v0URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("atm-v0-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: v0URL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [v0URL.path,
            "CREATE TABLE minute_bucket (bucket INTEGER NOT NULL, target_kind TEXT NOT NULL, target_key TEXT NOT NULL, route TEXT NOT NULL, upload INTEGER NOT NULL DEFAULT 0, download INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (bucket, target_kind, target_key, route)) WITHOUT ROWID;",
            "INSERT INTO minute_bucket VALUES (\(minuteBucket), 'domain', 'a.com', 'proxy', 10, 20);",
            "PRAGMA user_version = 0;"]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let migrated = try TrafficStore(url: v0URL)
        // 迁移后数据保留（归入未归属）
        let usage = try migrated.targetUsage(from: t0.addingTimeInterval(-60), to: t0.addingTimeInterval(60))
        XCTAssertEqual(usage, [.init(kind: "domain", key: "a.com", route: "proxy", upload: 10, download: 20)])
        // 新写入带 app_key 正常
        try migrated.upsertMinute([.init(bucket: minuteBucket, appKey: "/Applications/A.app",
                                         kind: "domain", key: "a.com", route: "proxy",
                                         upload: 1, download: 1)])
        let apps = try migrated.appUsage(from: t0.addingTimeInterval(-60), to: t0.addingTimeInterval(60))
        XCTAssertEqual(apps.map(\.appKey), ["/Applications/A.app"])
    }
}

final class AppBundlePathExtractorTests: XCTestCase {
    func testNormalApp() {
        XCTAssertEqual(
            AppBundlePathExtractor.extract(from: "/Applications/Safari.app/Contents/MacOS/Safari"),
            "/Applications/Safari.app")
    }

    func testHelperMergesIntoOutermostApp() {
        XCTAssertEqual(
            AppBundlePathExtractor.extract(
                from: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"),
            "/Applications/Google Chrome.app")
        XCTAssertEqual(
            AppBundlePathExtractor.extract(
                from: "/System/Applications/Mail.app/Contents/XPCServices/ComposeService.xpc/Contents/MacOS/ComposeService"),
            "/System/Applications/Mail.app")
    }

    func testNonAppProcessReturnsNil() {
        XCTAssertNil(AppBundlePathExtractor.extract(from: "/opt/homebrew/bin/node"))
        XCTAssertNil(AppBundlePathExtractor.extract(from: "/usr/bin/curl"))
        XCTAssertNil(AppBundlePathExtractor.extract(from: "/"))
    }
}

final class ProcessSocketMapTests: XCTestCase {
    /// 冒烟：真实扫描不崩溃；本测试进程自身至少应有可枚举的 socket 或空表。
    /// （归属正确性由真机运行验证，见 docs/DEVELOPMENT.md。）
    func testRefreshDoesNotCrashAndYieldsTable() {
        let map = ProcessSocketMap()
        map.refresh()
        _ = map.table
    }
}

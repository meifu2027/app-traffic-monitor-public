import Foundation
import SQLite3
import StatsCore

public enum StorageError: Error, CustomStringConvertible {
    case openFailed(String)
    case execFailed(String)
    case prepareFailed(String)
    case stepFailed(String)

    public var description: String {
        switch self {
        case .openFailed(let m): return "打开数据库失败: \(m)"
        case .execFailed(let m): return "执行 SQL 失败: \(m)"
        case .prepareFailed(let m): return "预编译失败: \(m)"
        case .stepFailed(let m): return "执行失败: \(m)"
        }
    }
}

/// 流量分钟桶存储（D 线实现；I 线补齐 T10 日汇总压缩）。
///
/// schema v1：在 v0 基础上增加 `app_key` 列（进程归属的最外层 .app 路径；
/// 空串 = 未归属进程）。v0 → v1 自动迁移：旧行按主键聚合归入未归属。
/// schema v2（I 线）：新增 `daily_rollup` 日汇总表，`day` 为本地自然日起点
/// （unix 秒，由维护事务按 Calendar 边界计算）。完整本地日压缩进日汇总（约 400 天），
/// 分钟桶只保留近端（约 48 小时）。查询统一走两表 UNION——「同一天只存在于其中
/// 一张表」的不变量由 maintainDailyRollup 的单事务保证，读侧永不双计。
/// 口径列（计量来源暂未启用/路由分类/目标类型/app 归属）均已保留，便于 T05 演进。
///
/// 已知限制：日边界按维护时刻的当前时区计算，时区变更不回算旧日桶（个人本机工具
/// 可接受）；无提交序号列（单写者无重放）。
public final class TrafficStore {
    public struct Row: Equatable {
        public let bucket: Int64
        public let appKey: String
        public let kind: String
        public let key: String
        public let route: String
        public let upload: Int64
        public let download: Int64

        public init(bucket: Int64, appKey: String, kind: String, key: String,
                    route: String, upload: Int64, download: Int64) {
            self.bucket = bucket
            self.appKey = appKey
            self.kind = kind
            self.key = key
            self.route = route
            self.upload = upload
            self.download = download
        }
    }

    public struct TargetUsage: Equatable {
        public let kind: String
        public let key: String
        public let route: String
        public let upload: Int64
        public let download: Int64

        public init(kind: String, key: String, route: String, upload: Int64, download: Int64) {
            self.kind = kind
            self.key = key
            self.route = route
            self.upload = upload
            self.download = download
        }
    }

    public struct AppUsage: Equatable {
        public let appKey: String
        public let upload: Int64
        public let download: Int64
    }

    /// 日汇总保留期（UI 口径文案与维护清理共用此常量）。
    public static let dailyRollupRetention: TimeInterval = 400 * 24 * 3600
    /// 分钟桶有效保留窗口（维护前沿 = 最近未完成日的前一天；文案按约 48 小时表述）。
    public static let minuteRetention: TimeInterval = 2 * 24 * 3600
    /// 日定稿安全边际：日结束后至少间隔该时长才压缩（写入侧批量冲刷周期为 5 秒，
    /// 取 10 分钟绰绰有余，同时避免午夜边界竞态）。
    private static let rollupCompleteMargin: TimeInterval = 600

    private var db: OpaquePointer?
    public let url: URL

    private let transient = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)

    public init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "?"
            throw StorageError.openFailed(message)
        }
        db = handle
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA synchronous=NORMAL;")
        try migrateIfNeeded()
    }

    deinit {
        if let db = db { sqlite3_close_v2(db) }
    }

    // MARK: - 迁移

    private func migrateIfNeeded() throws {
        let version = try readUserVersion()

        if version < 1 {
            // 全新库或 D 线 v0 库
            let columns = try existingColumns(of: "minute_bucket")
            if columns.isEmpty {
                try createSchemaV1()
            } else if !columns.contains("app_key") {
                try migrateV0toV1()
            } else {
                try exec("PRAGMA user_version = 1;")
            }
        }
        if version < 2 {
            // v1 → v2：建日汇总表（数据由 maintainDailyRollup 首次运行时压缩补齐）
            try createDailyRollupV2()
        }
    }

    /// 版本读取独立成函数：语句在返回前 finalize，避免活跃语句的 schema 读锁阻塞后续 DDL。
    private func readUserVersion() throws -> Int32 {
        guard let db = db else { throw StorageError.prepareFailed("数据库未打开") }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else {
            throw StorageError.prepareFailed("读取 user_version 失败")
        }
        return sqlite3_column_int(stmt, 0)
    }

    private func existingColumns(of table: String) throws -> [String] {
        try queryTexts(sql: "PRAGMA table_info(\(table));", columnIndex: 1)
    }

    private func createSchemaV1() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS minute_bucket (
          bucket INTEGER NOT NULL,
          app_key TEXT NOT NULL DEFAULT '',
          target_kind TEXT NOT NULL,
          target_key TEXT NOT NULL,
          route TEXT NOT NULL,
          upload INTEGER NOT NULL DEFAULT 0,
          download INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY (bucket, app_key, target_kind, target_key, route)
        ) WITHOUT ROWID;
        """)
        try exec("PRAGMA user_version = 1;")
    }

    private func migrateV0toV1() throws {
        try exec("BEGIN IMMEDIATE;")
        do {
            try exec("ALTER TABLE minute_bucket RENAME TO minute_bucket_v0;")
            try exec("""
            CREATE TABLE minute_bucket (
              bucket INTEGER NOT NULL,
              app_key TEXT NOT NULL DEFAULT '',
              target_kind TEXT NOT NULL,
              target_key TEXT NOT NULL,
              route TEXT NOT NULL,
              upload INTEGER NOT NULL DEFAULT 0,
              download INTEGER NOT NULL DEFAULT 0,
              PRIMARY KEY (bucket, app_key, target_kind, target_key, route)
            ) WITHOUT ROWID;
            """)
            try exec("""
            INSERT INTO minute_bucket (bucket, app_key, target_kind, target_key, route, upload, download)
            SELECT bucket, '', target_kind, target_key, route, SUM(upload), SUM(download)
            FROM minute_bucket_v0
            GROUP BY bucket, target_kind, target_key, route;
            """)
            try exec("DROP TABLE minute_bucket_v0;")
            try exec("PRAGMA user_version = 1;")
            try exec("COMMIT;")
        } catch {
            _ = try? exec("ROLLBACK;")
            throw error
        }
    }

    /// v2（I 线/T10）：日汇总表。列与 minute_bucket 同构，`day` 为本地日起点。
    private func createDailyRollupV2() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS daily_rollup (
          day INTEGER NOT NULL,
          app_key TEXT NOT NULL DEFAULT '',
          target_kind TEXT NOT NULL,
          target_key TEXT NOT NULL,
          route TEXT NOT NULL,
          upload INTEGER NOT NULL DEFAULT 0,
          download INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY (day, app_key, target_kind, target_key, route)
        ) WITHOUT ROWID;
        """)
        try exec("PRAGMA user_version = 2;")
    }

    // MARK: - 写入

    /// 批量累加写入（同一事务，upsert 增量）。
    public func upsertMinute(_ rows: [Row]) throws {
        guard !rows.isEmpty, let db = db else { return }
        try exec("BEGIN IMMEDIATE;")
        var stmt: OpaquePointer?
        let sql = """
        INSERT INTO minute_bucket (bucket, app_key, target_kind, target_key, route, upload, download)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
        ON CONFLICT (bucket, app_key, target_kind, target_key, route)
        DO UPDATE SET upload = upload + excluded.upload, download = download + excluded.download;
        """
        do {
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw StorageError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            for row in rows {
                sqlite3_reset(stmt)
                sqlite3_bind_int64(stmt, 1, row.bucket)
                sqlite3_bind_text(stmt, 2, row.appKey, -1, transient)
                sqlite3_bind_text(stmt, 3, row.kind, -1, transient)
                sqlite3_bind_text(stmt, 4, row.key, -1, transient)
                sqlite3_bind_text(stmt, 5, row.route, -1, transient)
                sqlite3_bind_int64(stmt, 6, row.upload)
                sqlite3_bind_int64(stmt, 7, row.download)
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw StorageError.stepFailed(String(cString: sqlite3_errmsg(db)))
                }
            }
            try exec("COMMIT;")
        } catch {
            _ = try? exec("ROLLBACK;")
            throw error
        }
    }

    /// 删除早于给定时间的分钟桶（30 天保留策略的启动清理；日汇总压缩在 T10 实现）。
    public func pruneMinute(olderThan date: Date) throws {
        try exec("DELETE FROM minute_bucket WHERE bucket < \(Int64(date.timeIntervalSince1970));")
    }

    /// T10 日汇总维护（I 线）：完整本地日压缩进 daily_rollup → 清理已压缩分钟桶 →
    /// 清理超期日汇总。三步在同一事务内完成，保证读侧 UNION 永远看不到
    /// 「同一天同时存在于两张表」的双计状态；重复执行幂等（先 DELETE 后按日重建）。
    ///
    /// 维护前沿 frontier = startOfDay(now - 边际) 前移一天：即分钟桶保留
    /// 「昨天 + 今天」约 48 小时（小时粒度统计的可用窗口），更早的完整日进日汇总。
    /// 日边界按当前时区的本地日历计算；时区变更后旧日桶起点不回算。
    public func maintainDailyRollup(now: Date = Date(), calendar: Calendar = .current) throws {
        guard db != nil else { throw StorageError.execFailed("数据库未打开") }
        let frontierDate = calendar.startOfDay(for: now.addingTimeInterval(-Self.rollupCompleteMargin))
        let frontier = calendar.date(byAdding: .day, value: -1, to: frontierDate) ?? frontierDate
        let frontierSeconds = Int64(frontier.timeIntervalSince1970)

        // 需压缩的日：分钟表中出现过的、起点早于前沿的完整本地日
        let earliestMinute = try queryTexts(sql: "SELECT MIN(bucket) FROM minute_bucket;", columnIndex: 0)
            .compactMap { Int64($0) }
            .first

        try exec("BEGIN IMMEDIATE;")
        do {
            if let firstBucket = earliestMinute {
                var dayStart = calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(firstBucket)))
                var iterations = 0
                while dayStart < frontier && iterations < 1000 {
                    iterations += 1
                    let dayStartSeconds = Int64(dayStart.timeIntervalSince1970)
                    let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart)
                        ?? dayStart.addingTimeInterval(86400)
                    let nextDaySeconds = Int64(nextDay.timeIntervalSince1970)
                    try exec("DELETE FROM daily_rollup WHERE day = \(dayStartSeconds);")
                    // 覆盖式重建：重跑不双计；跨夏令时日按本地日历边界取整段
                    try exec("""
                    INSERT INTO daily_rollup (day, app_key, target_kind, target_key, route, upload, download)
                    SELECT \(dayStartSeconds), app_key, target_kind, target_key, route, SUM(upload), SUM(download)
                    FROM minute_bucket
                    WHERE bucket >= \(dayStartSeconds) AND bucket < \(nextDaySeconds)
                    GROUP BY app_key, target_kind, target_key, route;
                    """)
                    dayStart = nextDay
                }
            }
            try exec("DELETE FROM minute_bucket WHERE bucket < \(frontierSeconds);")
            let rollupCutoff = Int64(now.addingTimeInterval(-Self.dailyRollupRetention).timeIntervalSince1970)
            try exec("DELETE FROM daily_rollup WHERE day < \(rollupCutoff);")
            try exec("COMMIT;")
        } catch {
            _ = try? exec("ROLLBACK;")
            throw error
        }
    }

    // MARK: - 查询

    /// 统一查询数据源：近端分钟桶 + 远端日汇总（按日互斥，见 maintainDailyRollup）。
    /// 注意：日汇总行的 period 为日起点，非日对齐的查询区间会整日计入/排除首尾日
    /// （图表层对天/周/月粒度的自定义区间做日对齐 snapping，规避该口径损失）。
    private static let unionSource = """
    (SELECT bucket AS period, app_key, target_kind, target_key, route, upload, download FROM minute_bucket
     UNION ALL
     SELECT day, app_key, target_kind, target_key, route, upload, download FROM daily_rollup)
    """

    /// app_key IN (...) 的占位符串（参数绑定防应用路径特殊字符）。
    private static func appPlaceholders(_ count: Int) -> String {
        (1...max(count, 1)).map { "?\($0)" }.joined(separator: ", ")
    }

    /// 区间按目标+路由聚合（跨 app 维度求和）。
    public func targetUsage(from: Date, to: Date, route: String? = nil) throws -> [TargetUsage] {
        try queryRows(sql: """
        SELECT target_kind, target_key, route, SUM(upload), SUM(download)
        FROM \(Self.unionSource)
        WHERE period >= \(Int64(from.timeIntervalSince1970)) AND period < \(Int64(to.timeIntervalSince1970))
        \(route.map { "AND route = '\($0)'" } ?? "")
        GROUP BY target_kind, target_key, route
        """)
    }

    /// 区间按 app 聚合。仅返回已归属（app_key 非空）的行——按用户要求无归属不展示，
    /// 但未归属字节必须可查询（见 unattributedTotals）以保持口径诚实。
    public func appUsage(from: Date, to: Date, route: String? = nil) throws -> [AppUsage] {
        let rows = try queryTuples(sql: """
        SELECT app_key, SUM(upload), SUM(download)
        FROM \(Self.unionSource)
        WHERE period >= \(Int64(from.timeIntervalSince1970)) AND period < \(Int64(to.timeIntervalSince1970))
        AND app_key != ''
        \(route.map { "AND route = '\($0)'" } ?? "")
        GROUP BY app_key
        """)
        return rows.map { AppUsage(appKey: $0.0, upload: $0.1, download: $0.2) }
    }

    /// 下钻：指定 app 集合在区间访问的目标明细（按目标+路由聚合，集合内 app 求和）。
    /// app_key 使用参数绑定（应用路径可能含特殊字符）；空集合返回空。
    public func appTargetUsage(appKeys: [String], from: Date, to: Date, route: String? = nil) throws -> [TargetUsage] {
        guard !appKeys.isEmpty else { return [] }
        guard let db = db else { throw StorageError.prepareFailed("数据库未打开") }
        let sql = """
        SELECT target_kind, target_key, route, SUM(upload), SUM(download)
        FROM \(Self.unionSource)
        WHERE period >= \(Int64(from.timeIntervalSince1970))
          AND period < \(Int64(to.timeIntervalSince1970))
          AND app_key IN (\(Self.appPlaceholders(appKeys.count)))
        \(route.map { "AND route = '\($0)'" } ?? "")
        GROUP BY target_kind, target_key, route
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StorageError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        for (index, key) in appKeys.enumerated() {
            sqlite3_bind_text(stmt, Int32(index + 1), key, -1, transient)
        }
        var result: [TargetUsage] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let kind = String(cString: sqlite3_column_text(stmt, 0))
            let key = String(cString: sqlite3_column_text(stmt, 1))
            let routeValue = String(cString: sqlite3_column_text(stmt, 2))
            let up = sqlite3_column_int64(stmt, 3)
            let down = sqlite3_column_int64(stmt, 4)
            result.append(TargetUsage(kind: kind, key: key, route: routeValue, upload: up, download: down))
        }
        return result
    }

    /// 单 app 下钻便捷重载（表格页沿用）。
    public func appTargetUsage(appKey: String, from: Date, to: Date, route: String? = nil) throws -> [TargetUsage] {
        try appTargetUsage(appKeys: [appKey], from: from, to: to, route: route)
    }

    /// 区间未归属进程的字节合计（用于 app 视图口径标注）。
    public func unattributedTotals(from: Date, to: Date, route: String? = nil) throws -> (upload: Int64, download: Int64) {
        let rows = try queryTuples(sql: """
        SELECT 'x', SUM(upload), SUM(download)
        FROM \(Self.unionSource)
        WHERE period >= \(Int64(from.timeIntervalSince1970)) AND period < \(Int64(to.timeIntervalSince1970))
        AND app_key = ''
        \(route.map { "AND route = '\($0)'" } ?? "")
        """)
        guard let first = rows.first else { return (0, 0) }
        return (first.1, first.2)
    }

    /// 区间各路由合计。
    public func routeTotals(from: Date, to: Date) throws -> [(route: String, upload: Int64, download: Int64)] {
        let rows = try queryTuples(sql: """
        SELECT route, SUM(upload), SUM(download)
        FROM \(Self.unionSource)
        WHERE period >= \(Int64(from.timeIntervalSince1970)) AND period < \(Int64(to.timeIntervalSince1970))
        GROUP BY route
        """)
        return rows.map { (route: $0.0, upload: $0.1, download: $0.2) }
    }

    /// 区间总上传/下载（全路由）。
    public func totals(from: Date, to: Date, route: String? = nil) throws -> (upload: Int64, download: Int64) {
        let rows = try queryTuples(sql: """
        SELECT 'total', SUM(upload), SUM(download)
        FROM \(Self.unionSource)
        WHERE period >= \(Int64(from.timeIntervalSince1970)) AND period < \(Int64(to.timeIntervalSince1970))
        \(route.map { "AND route = '\($0)'" } ?? "")
        """)
        guard let first = rows.first else { return (0, 0) }
        return (first.1, first.2)
    }

    // MARK: - 时序查询（I 线统计图）

    /// 按本地自然日聚合的区间序列（图表/统计页签用）。
    /// 老数据来自 daily_rollup（GROUP BY day），近端未压缩日来自 minute_bucket
    /// 按本地日历边界逐日聚合（避免时区/夏令时整除取整错误），两侧按日合并。
    public func dayTotals(from: Date, to: Date, route: String? = nil,
                          appKeys: [String] = [], calendar: Calendar = .current) throws -> [PeriodTotal] {
        let routeClause = route.map { "AND route = '\($0)'" } ?? ""
        let appClause = appKeys.isEmpty ? "" : "AND app_key IN (\(Self.appPlaceholders(appKeys.count)))"
        var result: [Int64: PeriodTotal] = [:]

        // 1) 日汇总侧：day 本身就是本地日起点，直接分组
        let rollupRows = try queryPeriodTotals(sql: """
        SELECT day, SUM(upload), SUM(download)
        FROM daily_rollup
        WHERE day >= \(Int64(from.timeIntervalSince1970)) AND day < \(Int64(to.timeIntervalSince1970))
        \(routeClause) \(appClause)
        GROUP BY day
        """, appKeys: appKeys)
        for row in rollupRows { result[row.period] = row }

        // 2) 分钟侧：只枚举分钟表实际覆盖的本地日（维护后通常 ≤ 2 天），逐日按边界聚合
        let minRows = try queryTexts(sql: "SELECT MIN(bucket) FROM minute_bucket;", columnIndex: 0)
        let maxRows = try queryTexts(sql: "SELECT MAX(bucket) FROM minute_bucket;", columnIndex: 0)
        guard let minBucket = minRows.compactMap({ Int64($0) }).first,
              let maxBucket = maxRows.compactMap({ Int64($0) }).first else {
            return result.values.sorted { $0.period < $1.period }
        }
        var dayStart = max(calendar.startOfDay(for: from),
                           calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(minBucket))))
        let lastDay = min(calendar.startOfDay(for: to.addingTimeInterval(-1)),
                          calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(maxBucket))))
        while dayStart <= lastDay {
            let dayStartSeconds = Int64(dayStart.timeIntervalSince1970)
            if result[dayStartSeconds] == nil {
                let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart)
                    ?? dayStart.addingTimeInterval(86400)
                let rows = try queryPeriodTotals(sql: """
                SELECT \(dayStartSeconds), SUM(upload), SUM(download)
                FROM minute_bucket
                WHERE bucket >= \(dayStartSeconds) AND bucket < \(Int64(nextDay.timeIntervalSince1970))
                \(routeClause) \(appClause)
                """, appKeys: appKeys)
                if let row = rows.first {
                    result[dayStartSeconds] = PeriodTotal(period: dayStartSeconds,
                                                          upload: row.upload, download: row.download)
                }
            }
            dayStart = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86400)
        }
        return result.values.sorted { $0.period < $1.period }
    }

    /// 单 app 过滤便捷重载（旧调用方沿用）。
    public func dayTotals(from: Date, to: Date, route: String? = nil,
                          appKey: String?, calendar: Calendar = .current) throws -> [PeriodTotal] {
        try dayTotals(from: from, to: to, route: route,
                      appKeys: appKey.map { [$0] } ?? [], calendar: calendar)
    }

    /// 按本地小时聚合（仅分钟表——小时精度只在近端约 48 小时有数据）。
    /// 起点按当前时区偏移整除对齐；夏令时切换日的个别小时标签可能偏移一小时
    /// （仅影响该小时柱条的边界归属，个人本机可接受）。
    public func hourTotals(from: Date, to: Date, route: String? = nil,
                           appKeys: [String] = []) throws -> [PeriodTotal] {
        let tz = Int64(TimeZone.current.secondsFromGMT(for: Date()))
        let routeClause = route.map { "AND route = '\($0)'" } ?? ""
        let appClause = appKeys.isEmpty ? "" : "AND app_key IN (\(Self.appPlaceholders(appKeys.count)))"
        return try queryPeriodTotals(sql: """
        SELECT (bucket + \(tz)) / 3600 * 3600 - \(tz), SUM(upload), SUM(download)
        FROM minute_bucket
        WHERE bucket >= \(Int64(from.timeIntervalSince1970)) AND bucket < \(Int64(to.timeIntervalSince1970))
        \(routeClause) \(appClause)
        GROUP BY 1
        """, appKeys: appKeys)
    }

    /// 单 app 过滤便捷重载（旧调用方沿用）。
    public func hourTotals(from: Date, to: Date, route: String? = nil,
                           appKey: String?) throws -> [PeriodTotal] {
        try hourTotals(from: from, to: to, route: route, appKeys: appKey.map { [$0] } ?? [])
    }

    /// (period, upload, download) 三元组查询；appKeys 走参数绑定（应用路径可含特殊字符）。
    private func queryPeriodTotals(sql: String, appKeys: [String]) throws -> [PeriodTotal] {
        guard let db = db else { throw StorageError.prepareFailed("数据库未打开") }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StorageError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        for (index, key) in appKeys.enumerated() {
            sqlite3_bind_text(stmt, Int32(index + 1), key, -1, transient)
        }
        var out: [PeriodTotal] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            // 无 GROUP BY 的 SUM 空集会返回一行 NULL（不是零行），跳过之
            guard sqlite3_column_type(stmt, 1) != SQLITE_NULL else { continue }
            out.append(PeriodTotal(period: sqlite3_column_int64(stmt, 0),
                                   upload: sqlite3_column_int64(stmt, 1),
                                   download: sqlite3_column_int64(stmt, 2)))
        }
        return out
    }

    // MARK: - Private

    private func exec(_ sql: String) throws {
        guard let db = db else { throw StorageError.execFailed("数据库未打开") }
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let message = err.map { String(cString: $0) } ?? "?"
            sqlite3_free(err)
            throw StorageError.execFailed(message)
        }
    }

    private func queryRows(sql: String) throws -> [TargetUsage] {
        guard let db = db else { throw StorageError.prepareFailed("数据库未打开") }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StorageError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        var result: [TargetUsage] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let kind = String(cString: sqlite3_column_text(stmt, 0))
            let key = String(cString: sqlite3_column_text(stmt, 1))
            let route = String(cString: sqlite3_column_text(stmt, 2))
            let up = sqlite3_column_int64(stmt, 3)
            let down = sqlite3_column_int64(stmt, 4)
            result.append(TargetUsage(kind: kind, key: key, route: route, upload: up, download: down))
        }
        return result
    }

    private func queryTuples(sql: String) throws -> [(String, Int64, Int64)] {
        guard let db = db else { throw StorageError.prepareFailed("数据库未打开") }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StorageError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        var result: [(String, Int64, Int64)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let text = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            result.append((text, sqlite3_column_int64(stmt, 1), sqlite3_column_int64(stmt, 2)))
        }
        return result
    }

    private func queryTexts(sql: String, columnIndex: Int32) throws -> [String] {
        guard let db = db else { throw StorageError.prepareFailed("数据库未打开") }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StorageError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        var result: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let text = sqlite3_column_text(stmt, columnIndex) {
                result.append(String(cString: text))
            }
        }
        return result
    }
}

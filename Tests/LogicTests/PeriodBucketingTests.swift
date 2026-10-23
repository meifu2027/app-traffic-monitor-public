import XCTest
import StatsCore

/// I 线：周/月归桶（PeriodBucketing）单元测试。
final class PeriodBucketingTests: XCTestCase {

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        cal.firstWeekday = 2 // 周一为一周起点（App 图表层同样设置）
        return cal
    }

    /// 日起点（当地 00:00）的 unix 秒。
    private func day(_ y: Int, _ mo: Int, _ d: Int) -> Int64 {
        Int64(calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: 0))!.timeIntervalSince1970)
    }

    /// 2026-10-19 为周一：10-17(周六)/10-18(周日) 归入 10-12 起始的周；
    /// 10-19(周一)/10-21(周三) 归入 10-19 起始的周。
    func testWeekMergeMondayAligned() {
        let totals = [
            PeriodTotal(period: day(2026, 10, 17), upload: 1, download: 1),
            PeriodTotal(period: day(2026, 10, 18), upload: 2, download: 2),
            PeriodTotal(period: day(2026, 10, 19), upload: 4, download: 4),
            PeriodTotal(period: day(2026, 10, 21), upload: 8, download: 8),
        ]
        let weeks = PeriodBucketing.group(totals, by: .week, calendar: calendar)
        XCTAssertEqual(weeks.count, 2)
        XCTAssertEqual(weeks[0].period, day(2026, 10, 12))
        XCTAssertEqual(weeks[0].total, 6)
        XCTAssertEqual(weeks[1].period, day(2026, 10, 19))
        XCTAssertEqual(weeks[1].total, 24)
    }

    func testMonthMerge() {
        let totals = [
            PeriodTotal(period: day(2026, 9, 28), upload: 1, download: 0),
            PeriodTotal(period: day(2026, 9, 30), upload: 2, download: 0),
            PeriodTotal(period: day(2026, 10, 1), upload: 4, download: 0),
            PeriodTotal(period: day(2026, 10, 3), upload: 8, download: 0),
        ]
        let months = PeriodBucketing.group(totals, by: .month, calendar: calendar)
        XCTAssertEqual(months.count, 2)
        XCTAssertEqual(months[0].period, day(2026, 9, 1))
        XCTAssertEqual(months[0].total, 3)
        XCTAssertEqual(months[1].period, day(2026, 10, 1))
        XCTAssertEqual(months[1].total, 12)
    }

    /// 小时/天粒度原样返回，仅合并同周期重复行；输出按起点升序。
    func testDayAndHourPassThroughMergeDuplicates() {
        let p = day(2026, 10, 19)
        let days = PeriodBucketing.group([PeriodTotal(period: p + 86400, upload: 1, download: 1),
                                          PeriodTotal(period: p, upload: 1, download: 2),
                                          PeriodTotal(period: p, upload: 3, download: 4)],
                                         by: .day, calendar: calendar)
        XCTAssertEqual(days, [PeriodTotal(period: p, upload: 4, download: 6),
                              PeriodTotal(period: p + 86400, upload: 1, download: 1)])
        let hours = PeriodBucketing.group([PeriodTotal(period: p + 7200, upload: 1, download: 1)],
                                          by: .hour, calendar: calendar)
        XCTAssertEqual(hours.map(\.period), [p + 7200])
    }
}

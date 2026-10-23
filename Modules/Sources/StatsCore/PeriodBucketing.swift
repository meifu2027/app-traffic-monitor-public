import Foundation

/// 周期序列点：period 为周期起点（unix 秒，本地时区对齐的整点/日/周/月起点）。
public struct PeriodTotal: Equatable {
    public let period: Int64
    public let upload: Int64
    public let download: Int64

    public init(period: Int64, upload: Int64, download: Int64) {
        self.period = period
        self.upload = upload
        self.download = download
    }

    public var total: Int64 { upload + download }
}

/// 统计粒度（I 线统计图页签）。小时/天序列直接来自存储层查询，周/月由日序列归并。
public enum PeriodGranularity: CaseIterable {
    case hour
    case day
    case week
    case month

    public var title: String {
        switch self {
        case .hour: return "小时"
        case .day: return "天"
        case .week: return "周"
        case .month: return "月"
        }
    }
}

/// 周期归并纯函数：把日/小时粒度序列合并为周或月序列。
/// 周/月边界按传入 Calendar 的本地日历计算（调用方负责 firstWeekday 等偏好）。
public enum PeriodBucketing {

    /// 将序列按粒度归并。小时/天原样返回（仅合并同周期重复行）；
    /// 周/月把日序列按本地周（默认周一起，取决于 calendar.firstWeekday）/自然月合并。
    public static func group(_ totals: [PeriodTotal],
                             by granularity: PeriodGranularity,
                             calendar: Calendar) -> [PeriodTotal] {
        switch granularity {
        case .hour, .day:
            return merge(totals) { $0.period }
        case .week, .month:
            let component: Calendar.Component = granularity == .week ? .weekOfYear : .month
            return merge(totals) { value in
                guard let interval = calendar.dateInterval(of: component, for: value.date) else {
                    return value.period
                }
                return Int64(interval.start.timeIntervalSince1970)
            }
        }
    }

    /// 按映射后的周期起点合并上传/下载，输出按起点升序。
    private static func merge(_ totals: [PeriodTotal],
                              _ bucketOf: (PeriodTotal) -> Int64) -> [PeriodTotal] {
        var acc: [Int64: PeriodTotal] = [:]
        for item in totals {
            let bucket = bucketOf(item)
            if let existing = acc[bucket] {
                acc[bucket] = PeriodTotal(period: bucket,
                                          upload: existing.upload + item.upload,
                                          download: existing.download + item.download)
            } else {
                acc[bucket] = PeriodTotal(period: bucket, upload: item.upload, download: item.download)
            }
        }
        return acc.values.sorted { $0.period < $1.period }
    }
}

extension PeriodTotal {
    /// 周期起点的本地日期表示（供 Calendar 计算周/月边界）。
    public var date: Date {
        Date(timeIntervalSince1970: TimeInterval(period))
    }
}

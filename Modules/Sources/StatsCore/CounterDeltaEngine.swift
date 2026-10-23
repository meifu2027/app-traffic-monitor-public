import Foundation

/// 一次连接计数观测样本（来源无关；MihomoAdapter 负责把连接映射成本类型）。
public struct CounterSample: Equatable {
    public let id: String
    public let upload: Int64
    public let download: Int64
    /// 连接建立时间；nil 表示无法确认（视为观测期之前已存在）。
    public let startedAt: Date?

    public init(id: String, upload: Int64, download: Int64, startedAt: Date? = nil) {
        self.id = id
        self.upload = upload
        self.download = download
        self.startedAt = startedAt
    }
}

/// 一个观测区间内某连接的非负增量。
public struct CounterIncrement: Equatable {
    public let id: String
    public let uploadDelta: Int64
    public let downloadDelta: Int64

    public init(id: String, uploadDelta: Int64, downloadDelta: Int64) {
        self.id = id
        self.uploadDelta = uploadDelta
        self.downloadDelta = downloadDelta
    }
}

/// 累计计数 → 非负增量引擎（DEVELOPMENT_PLAN §2.6「代理字节的计算」）。
///
/// 规则：
/// - 会话首个完整快照只建基线，不把既有连接的历史累计记入当前区间；
/// - 同 ID 连接按累计值作差；负增量视为计数回退，仅重建该连接基线（不入账）；
/// - 全局累计（upload/downloadTotal）回退视为内核重启：全部重建基线；
/// - 连续观测期内新出现、且建立时间可确认落在观测期内的连接，从零计算首段；
///   建立时间不能确认的新连接只建基线；
/// - 连接从快照消失：移出跟踪（最后已见计数已入账，不补造关闭数据）；
/// - 计数不变（重复快照）产生零增量，不产生入账行。
///
/// 每个增量切片只返回一次，入账去重由存储层事务保证。
public final class CounterDeltaEngine {
    private struct LastSeen {
        var upload: Int64
        var download: Int64
    }

    private var lastSeen: [String: LastSeen] = [:]
    private var baselineEstablished = false
    private var sessionStart = Date()
    private var previousUploadTotal: Int64?
    private var previousDownloadTotal: Int64?

    /// 单连接计数回退次数（诊断用）。
    public private(set) var regressionCount = 0
    /// 检测到的内核重启次数（诊断用）。
    public private(set) var restartCount = 0

    public init() {}

    /// 处理一次快照，返回本观测区间的增量列表。
    public func process(uploadTotal: Int64?,
                       downloadTotal: Int64?,
                       samples: [CounterSample],
                       at now: Date = Date()) -> (increments: [CounterIncrement], kernelRestarted: Bool) {
        if let prev = previousDownloadTotal, let current = downloadTotal, current < prev {
            restartCount += 1
            resetSession(now: now)
            absorbBaseline(samples: samples, uploadTotal: uploadTotal, downloadTotal: downloadTotal)
            return ([], true)
        }

        guard baselineEstablished else {
            absorbBaseline(samples: samples, uploadTotal: uploadTotal, downloadTotal: downloadTotal)
            return ([], false)
        }

        var increments: [CounterIncrement] = []
        var alive = Set<String>()
        for sample in samples {
            alive.insert(sample.id)
            if let last = lastSeen[sample.id] {
                let dUp = sample.upload - last.upload
                let dDown = sample.download - last.download
                if dUp < 0 || dDown < 0 {
                    regressionCount += 1
                } else if dUp > 0 || dDown > 0 {
                    increments.append(CounterIncrement(id: sample.id, uploadDelta: dUp, downloadDelta: dDown))
                }
                lastSeen[sample.id] = LastSeen(upload: sample.upload, download: sample.download)
            } else {
                // 新连接：仅当建立时间可确认属于本连续观测期，才从零计数。
                let startedInSession = sample.startedAt.map { $0 >= sessionStart } ?? false
                if startedInSession, sample.upload > 0 || sample.download > 0 {
                    increments.append(CounterIncrement(id: sample.id,
                                                       uploadDelta: sample.upload,
                                                       downloadDelta: sample.download))
                }
                lastSeen[sample.id] = LastSeen(upload: sample.upload, download: sample.download)
            }
        }
        lastSeen = lastSeen.filter { alive.contains($0.key) }
        previousUploadTotal = uploadTotal ?? previousUploadTotal
        previousDownloadTotal = downloadTotal ?? previousDownloadTotal
        return (increments, false)
    }

    /// 外部确认的中断（接口断连、暂停恢复、端点替换）后调用：只重建基线。
    public func resetSession(now: Date = Date()) {
        lastSeen.removeAll()
        baselineEstablished = false
        sessionStart = now
        previousUploadTotal = nil
        previousDownloadTotal = nil
    }

    private func absorbBaseline(samples: [CounterSample], uploadTotal: Int64?, downloadTotal: Int64?) {
        for sample in samples {
            lastSeen[sample.id] = LastSeen(upload: sample.upload, download: sample.download)
        }
        baselineEstablished = true
        previousUploadTotal = uploadTotal ?? previousUploadTotal
        previousDownloadTotal = downloadTotal ?? previousDownloadTotal
    }
}

import Foundation
import MihomoAdapter
import StatsCore
import Storage

/// Mihomo 监控控制器（D 线）：发现端点 → 1s 快照采样 → 增量换算 → 路由分类 → 分钟桶入库。
///
/// 周期口径（DEVELOPMENT_PLAN §2.6）：/connections 为周期活跃连接快照，1 秒采样间隔
/// 独立于 UI 刷新与数据库提交；短连接可能漏采，全部数据为「已观测」口径。
/// 断连/暂停恢复后仅重建基线，不回填；全局计数回退按内核重启处理。
final class MihomoMonitorController {

    enum Status: Equatable {
        case connecting
        case running
        case unavailable(String)
        case paused
    }

    struct LiveStatus {
        let status: Status
        let proxyUpRate: Double
        let proxyDownRate: Double
        let lastDataAt: Date?
    }

    private(set) var liveStatus = LiveStatus(status: .connecting, proxyUpRate: 0, proxyDownRate: 0, lastDataAt: nil)

    /// 主线程回调（菜单栏/统计窗口刷新）。
    var onTick: ((LiveStatus) -> Void)?

    private let store: TrafficStore
    private let engine = CounterDeltaEngine()
    private let queue = DispatchQueue(label: "com.apptrafficmonitor.monitor")

    private var client: MihomoReadOnlyClient?
    private var timer: DispatchSourceTimer?
    /// T10 日汇总维护（I 线）：启动一次 + 每 6 小时一次（菜单栏应用长期不重启，
    /// 只靠启动维护会让分钟桶无限增长、日汇总迟迟不落）。
    private var maintenanceTimer: DispatchSourceTimer?
    private var proxyTypes: [String: String] = [:]
    private var consecutiveErrors = 0
    private var tickCount = 0
    private var lastTickAt: Date?
    private var pendingRows: [TrafficStore.Row] = []
    private var lastFlushAt = Date()
    private var proxyUpEMA: Double = 0
    private var proxyDownEMA: Double = 0

    /// 源端口→进程 映射（每 2 个 tick 刷新；归属失败的连接记未归属）。
    private let socketMap = ProcessSocketMap()

    private static let fractionalISO: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plainISO = ISO8601DateFormatter()

    init(store: TrafficStore) {
        self.store = store
        // I 线/T10：完整本地日压缩为日汇总（约 400 天），分钟桶只留近端约 48 小时。
        // 历史库（原 30 天分钟数据）在首次维护时自动压入日汇总，不丢历史。
        try? store.maintainDailyRollup()
        let maintenance = DispatchSource.makeTimerSource(queue: queue)
        maintenance.schedule(deadline: .now() + 6 * 3600, repeating: 6 * 3600)
        maintenance.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.flush() // 先冲刷缓冲，保证待压缩分钟已提交
            try? self.store.maintainDailyRollup()
        }
        maintenance.resume()
        maintenanceTimer = maintenance
    }

    func start() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.reconnect()
        }
    }

    func pause() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.timer?.cancel()
            self.timer = nil
            self.flush()
            self.publish(.paused)
        }
    }

    func resume() {
        queue.async { [weak self] in
            guard let self = self else { return }
            // 恢复只重建基线，不回填暂停区间
            self.reconnect()
        }
    }

    /// 退出前冲刷缓冲。
    func stopAndFlush() {
        queue.sync {
            self.timer?.cancel()
            self.timer = nil
            self.maintenanceTimer?.cancel()
            self.maintenanceTimer = nil
            self.flush()
        }
    }

    // MARK: - 连接与采样循环

    private func reconnect() {
        do {
            let endpoint = try MihomoEndpointDiscovery.discover()
            let newClient = MihomoReadOnlyClient(endpoint: endpoint)
            _ = try newClient.getVersion() // 连通性验证
            client = newClient
            refreshProxyTypes()
            engine.resetSession()
            consecutiveErrors = 0
            scheduleTimer()
            publish(.running)
        } catch {
            client = nil
            publish(.unavailable("Mihomo 不可用：\(String(describing: error))"))
            queue.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.reconnect()
            }
        }
    }

    private func refreshProxyTypes() {
        guard let client = client,
              let proxies = try? client.getProxies(),
              let map = proxies.proxies else { return }
        proxyTypes = map.compactMapValues { $0.type }
    }

    private func scheduleTimer() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1.0, repeating: 1.0)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        guard let client = client, let timer = timer else { return }
        let snapshot: ConnectionsSnapshot
        do {
            snapshot = try client.getConnectionsSnapshot()
        } catch {
            consecutiveErrors += 1
            if consecutiveErrors >= 3 {
                // 连续失败视为观测中断：停表、重建基线、标记缺口后自动重连
                timer.cancel()
                self.timer = nil
                engine.resetSession()
                flush()
                publish(.unavailable("连接中断：\(String(describing: error))"))
                queue.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                    self?.reconnect()
                }
            }
            return
        }
        consecutiveErrors = 0
        tickCount += 1
        if tickCount % 2 == 0 {
            socketMap.refresh()
        }
        if tickCount % 60 == 0 {
            refreshProxyTypes()
        }

        let now = Date()
        let samples = snapshot.connections?.map { conn in
            CounterSample(id: conn.id ?? "",
                          upload: conn.upload ?? 0,
                          download: conn.download ?? 0,
                          startedAt: Self.parseDate(conn.start))
        } ?? []

        let result = engine.process(uploadTotal: snapshot.uploadTotal,
                                    downloadTotal: snapshot.downloadTotal,
                                    samples: samples,
                                    at: now)

        // 连接元数据（路由分类、目标键与 app 归属）
        struct Meta {
            let chains: [String]?
            let host: String?
            let destinationIP: String?
            let processPath: String?
            let sourcePort: String?
            let isTCP: Bool
        }
        var meta: [String: Meta] = [:]
        for conn in snapshot.connections ?? [] {
            meta[conn.id ?? ""] = Meta(chains: conn.chains,
                                       host: conn.metadata?.host,
                                       destinationIP: conn.metadata?.destinationIP,
                                       processPath: conn.metadata?.processPath,
                                       sourcePort: conn.metadata?.sourcePort,
                                       isTCP: (conn.metadata?.network ?? "tcp") != "udp")
        }

        let bucket = Int64(now.timeIntervalSince1970 / 60) * 60
        var proxyUp = 0
        var proxyDown = 0
        var refreshedForMissThisTick = false
        for increment in result.increments {
            guard !increment.id.isEmpty, let m = meta[increment.id] else { continue }
            let route = MihomoRouteClassifier.classify(chains: m.chains, proxyTypes: proxyTypes)
            let (kind, key) = Self.targetKey(host: m.host, destinationIP: m.destinationIP)
            // 归属优先级：mihomo processPath（可靠时）→ 本机 socket 表 → 未归属。
            // socket 表未命中时当场刷新重查一次（连接仍在快照中=源端口仍开着），
            // 将 2s 周期刷新的滞后窗口压缩到毫秒级。
            var processPath = m.processPath ?? ""
            if processPath.isEmpty, let portString = m.sourcePort, let port = UInt16(portString) {
                if socketMap.entry(isTCP: m.isTCP, port: port) == nil, !refreshedForMissThisTick {
                    socketMap.refresh()
                    refreshedForMissThisTick = true
                }
                if let entry = socketMap.entry(isTCP: m.isTCP, port: port) {
                    processPath = entry.processPath
                }
            }
            let appKey = AppIdentityResolver.appKey(processPath: processPath)
            pendingRows.append(TrafficStore.Row(bucket: bucket, appKey: appKey, kind: kind, key: key,
                                                route: route.rawValue,
                                                upload: increment.uploadDelta,
                                                download: increment.downloadDelta))
            if route == .proxy {
                proxyUp += Int(increment.uploadDelta)
                proxyDown += Int(increment.downloadDelta)
            }
        }

        // 速率：实际时间差 + EMA 平滑；无增量时衰减
        let dt = lastTickAt.map { max(now.timeIntervalSince($0), 0.1) } ?? 1.0
        if proxyUp == 0 && proxyDown == 0 {
            proxyUpEMA *= 0.6
            proxyDownEMA *= 0.6
        } else {
            let upRate = Double(proxyUp) / dt
            let downRate = Double(proxyDown) / dt
            proxyUpEMA = proxyUpEMA <= 0 ? upRate : proxyUpEMA * 0.6 + upRate * 0.4
            proxyDownEMA = proxyDownEMA <= 0 ? downRate : proxyDownEMA * 0.6 + downRate * 0.4
        }
        lastTickAt = now

        if now.timeIntervalSince(lastFlushAt) > 5 || pendingRows.count > 200 {
            flush()
        }
        publish(.running)
    }

    private func flush() {
        guard !pendingRows.isEmpty else { return }
        try? store.upsertMinute(pendingRows)
        pendingRows.removeAll()
        lastFlushAt = Date()
    }

    private func publish(_ status: Status) {
        liveStatus = LiveStatus(status: status,
                                proxyUpRate: proxyUpEMA,
                                proxyDownRate: proxyDownEMA,
                                lastDataAt: lastTickAt)
        let snapshot = liveStatus
        DispatchQueue.main.async { [weak self] in
            self?.onTick?(snapshot)
        }
    }

    // MARK: - 目标键（未知 IP 与域名使用不同类型键）

    static func targetKey(host: String?, destinationIP: String?) -> (kind: String, key: String) {
        if let host = host, let normalized = HostnameNormalizer.normalize(host) {
            return ("domain", normalized)
        }
        if let ip = destinationIP, !ip.isEmpty {
            return ("ip", ip)
        }
        return ("none", "无端点")
    }

    static func parseDate(_ raw: String?) -> Date? {
        guard let raw = raw else { return nil }
        return fractionalISO.date(from: raw) ?? plainISO.date(from: raw)
    }
}

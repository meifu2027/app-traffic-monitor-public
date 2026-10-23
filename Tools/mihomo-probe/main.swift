import Foundation
import MihomoAdapter

// mihomo-probe：R01 验证工具（开发期一次性运行，不属于产品常驻组件）。
// 只读访问本机正在运行的 Clash Verge/Mihomo，输出端点发现与计数/链路结构证据。
// 不打印 secret，不修改任何配置。

func line(_ s: String) { print(s) }

func fetchOrFail() -> MihomoReadOnlyClient {
    do {
        let endpoint = try MihomoEndpointDiscovery.discover()
        line("[发现] unixSocketPath = \(endpoint.unixSocketPath ?? "无")")
        line("[发现] loopback = \(endpoint.loopbackURL?.absoluteString ?? "无")")
        line("[发现] secret = \(endpoint.secret == nil ? "未设置" : "已设置(不显示)")")
        return MihomoReadOnlyClient(endpoint: endpoint)
    } catch {
        line("[失败] 端点发现: \(error)")
        exit(2)
    }
}

let client = fetchOrFail()

// 1. /version
do {
    let v = try client.getVersion()
    line("[/version] meta=\(v.meta.map(String.init) ?? "?") version=\(v.version ?? "?")")
} catch {
    line("[/version] 读取失败: \(error)")
    exit(3)
}

// 2. /configs（路由相关摘要）
if let c = try? client.getConfigsSummary() {
    line("[/configs] mode=\(c.mode ?? "?") tun.enable=\(c.tun?.enable.map(String.init) ?? "?") device=\(c.tun?.device ?? "?") stack=\(c.tun?.stack ?? "?")")
}

// 3. /proxies（只读；统计节点类型分布）
if let p = try? client.getProxies(), let proxies = p.proxies {
    let byType = Dictionary(grouping: proxies.values) { $0.type ?? "?" }
        .map { "\($0.key)x\($0.value.count)" }
        .sorted()
        .joined(separator: ", ")
    line("[/proxies] 共 \(proxies.count) 个节点/组；类型分布: \(byType)")
}

// 4. /connections 两次快照（实测间隔）
let t0 = Date()
guard let s1 = try? client.getConnectionsSnapshot() else { line("[/connections] 第一次快照失败"); exit(4) }
Thread.sleep(forTimeInterval: 1.0)
guard let s2 = try? client.getConnectionsSnapshot() else { line("[/connections] 第二次快照失败"); exit(4) }
let interval = Date().timeIntervalSince(t0)

line("[/connections] 两次 GET 总耗时(≈快照间隔) = \(String(format: "%.3f", interval))s")

func counter(_ v: Int64?) -> String { v.map { $0.description } ?? "?" }
line("[/connections] 全局累计 uploadTotal: \(counter(s1.uploadTotal)) -> \(counter(s2.uploadTotal))，downloadTotal: \(counter(s1.downloadTotal)) -> \(counter(s2.downloadTotal))")
if let a = s1.uploadTotal, let b = s2.uploadTotal, b < a { line("[警告] uploadTotal 出现回退") }
if let a = s1.downloadTotal, let b = s2.downloadTotal, b < a { line("[警告] downloadTotal 出现回退") }

let c1 = (s1.connections ?? []).reduce(into: [String: MihomoConnection]()) { $0[$1.id ?? ""] = $1 }
let c2 = (s2.connections ?? []).reduce(into: [String: MihomoConnection]()) { $0[$1.id ?? ""] = $1 }
line("[/connections] 连接数: \(c1.count) -> \(c2.count)")

var monotonicViolations = 0
var grewUp = 0, grewDown = 0
for (id, second) in c2 {
    guard let first = c1[id] else { continue }
    if let a = first.upload, let b = second.upload {
        if b < a { monotonicViolations += 1 } else if b > a { grewUp += 1 }
    }
    if let a = first.download, let b = second.download {
        if b < a { monotonicViolations += 1 } else if b > a { grewDown += 1 }
    }
}
line("[/connections] 同 ID 连接计数: 增长(上传方向)\(grewUp)条 增长(下载方向)\(grewDown)条 回退违例\(monotonicViolations)项")

let appeared = c2.keys.filter { c1[$0] == nil }
let disappeared = c1.keys.filter { c2[$0] == nil }
line("[/connections] 快照间隔内: 新增 \(appeared.count) 条，消失 \(disappeared.count) 条（消失=短连接漏采风险来源）")

let withProcess = c2.values.filter { !($0.metadata?.processPath ?? "").isEmpty }.count
line("[/connections] 第二次快照中 processPath 非空: \(withProcess)/\(c2.count) 条（关联原始 app 的可用性）")

// 5. 路由分类统计 + 各取一个样本作为"单独证明"（分类依据实际 chains + /proxies 节点类型）
var proxyTypes: [String: String] = [:]
if let p = try? client.getProxies(), let proxies = p.proxies {
    proxyTypes = proxies.compactMapValues { $0.type }
}
var classes: [MihomoAdapter.RouteClass: Int] = [:]
for conn in c2.values {
    classes[MihomoRouteClassifier.classify(chains: conn.chains, proxyTypes: proxyTypes), default: 0] += 1
}
line("[分类] DIRECT=\(classes[.direct] ?? 0) 代理=\(classes[.proxy] ?? 0) 未知=\(classes[.unknown] ?? 0)")

func describe(_ conn: MihomoConnection) -> String {
    let host = conn.metadata?.host ?? conn.metadata?.destinationIP ?? "?"
    let net = conn.metadata?.network ?? "?"
    let up = counter(conn.upload), down = counter(conn.download)
    let chains = conn.chains?.joined(separator: " <- ") ?? "无"
    let proc = conn.metadata?.processPath ?? "无进程字段"
    return "host=\(host) net=\(net) up=\(up)B down=\(down)B chains=[\(chains)] process=\(proc)"
}

if let sample = c2.values.first(where: { MihomoRouteClassifier.classify(chains: $0.chains, proxyTypes: proxyTypes) == .direct }) {
    line("[样本·DIRECT] \(describe(sample))")
}
if let sample = c2.values.first(where: { MihomoRouteClassifier.classify(chains: $0.chains, proxyTypes: proxyTypes) == .proxy }) {
    line("[样本·代理] \(describe(sample))")
}

line("[完成] 全部为只读 GET，未修改任何 Clash 配置")

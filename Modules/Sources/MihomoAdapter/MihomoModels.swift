import Foundation

// MARK: - 只读接口的最小数据模型

public struct MihomoVersion: Codable, Equatable {
    public let meta: Bool?
    public let version: String?
}

public struct MihomoConnection: Codable, Equatable {
    public struct Metadata: Codable, Equatable {
        public let network: String?
        public let type: String?
        public let sourceIP: String?
        public let sourcePort: String?
        public let destinationIP: String?
        public let destinationPort: String?
        public let host: String?
        public let process: String?
        public let processPath: String?
    }

    public let id: String?
    public let upload: Int64?
    public let download: Int64?
    public let start: String?
    public let chains: [String]?
    public let rule: String?
    public let rulePayload: String?
    public let metadata: Metadata?
}

public struct ConnectionsSnapshot: Codable, Equatable {
    public let downloadTotal: Int64?
    public let uploadTotal: Int64?
    public let memory: Int64?
    public let connections: [MihomoConnection]?
}

public struct MihomoProxy: Codable, Equatable {
    public let type: String?
    public let name: String?
    public let udp: Bool?
    public let alive: Bool?
}

public struct ProxiesResponse: Codable, Equatable {
    public let proxies: [String: MihomoProxy]?
}

/// Mihomo /configs 的最小只读视图（完整字段很多，R01 只取路由相关）。
public struct MihomoConfigsSummary: Codable, Equatable {
    public let mode: String?
    public let tun: Tun?
    public struct Tun: Codable, Equatable {
        public let enable: Bool?
        public let device: String?
        public let stack: String?
    }
}

// MARK: - 路由分类（依据连接实际 chains + /proxies 节点类型）

public enum RouteClass: String, Equatable {
    case direct
    case proxy
    case unknown
}

/// 路由分类器（DEVELOPMENT_PLAN §2.6）。
///
/// 判定规则：
/// - `chains == ["DIRECT"]` 或出站节点类型为 `Direct` → DIRECT；
/// - 出站节点（`chains[0]`，即实际转发节点；数组末项是入口组，禁止按其猜测）
///   类型属于已知转发类型 → 代理；
/// - 拒绝/PASS/兼容直连、选择器/URLTest/Fallback/Relay 等组类型、未知类型、空链 → 未知。
/// 不按组名、当前选中组或固定排除表猜测；不能确认的一律保留未知。
public enum MihomoRouteClassifier {

    /// 已知的具体代理转发协议类型（/proxies 的 type 字段）。
    public static let forwardingTypes: Set<String> = [
        "Vless", "Vmess", "Trojan", "Shadowsocks", "ShadowsocksR",
        "Hysteria", "Hysteria2", "TUIC", "WireGuard", "AnyTLS",
        "Socks5", "Socks", "Http", "Https", "Ssh", "Mieru", "Snell",
    ]

    public static func classify(chains: [String]?, proxyTypes: [String: String]) -> RouteClass {
        guard let chains = chains, let outbound = chains.first, !outbound.isEmpty else {
            return .unknown
        }
        if outbound == "DIRECT" {
            return .direct
        }
        guard let type = proxyTypes[outbound] else {
            return .unknown
        }
        if type == "Direct" {
            return .direct
        }
        if forwardingTypes.contains(type) {
            return .proxy
        }
        return .unknown
    }
}

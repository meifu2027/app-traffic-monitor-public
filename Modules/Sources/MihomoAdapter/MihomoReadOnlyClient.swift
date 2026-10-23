import Foundation

/// Mihomo 只读客户端（R01 最小接入）。
///
/// 仅使用 /version、/configs、/proxies 的 GET 与 /connections 的 GET；
/// 不修改节点、规则、模式、TUN、DNS 或任何配置，不关闭连接，不清零计数。
/// /connections 的 WebSocket 周期订阅在 R03 的采样器中实现。
public final class MihomoReadOnlyClient {

    public let endpoint: ControllerEndpoint
    private let http: MinimalHTTPClient

    public init(endpoint: ControllerEndpoint) {
        self.endpoint = endpoint
        self.http = MinimalHTTPClient(endpoint: endpoint)
    }

    public func getVersion() throws -> MihomoVersion {
        try decode(get("/version"))
    }

    public func getConfigsSummary() throws -> MihomoConfigsSummary {
        try decode(get("/configs"))
    }

    public func getProxies() throws -> ProxiesResponse {
        try decode(get("/proxies"))
    }

    public func getConnectionsSnapshot() throws -> ConnectionsSnapshot {
        try decode(get("/connections"))
    }

    // MARK: - Private

    private func get(_ path: String) throws -> Data {
        try http.get(path)
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        try JSONDecoder().decode(T.self, from: data)
    }
}

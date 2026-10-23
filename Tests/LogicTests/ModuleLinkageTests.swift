import XCTest
import SharedContracts
import StatsCore
import Storage
@testable import MihomoAdapter

/// 模块链接冒烟测试：验证 4 个共享模块可被宿主less测试包导入并调用。
final class ModuleLinkageTests: XCTestCase {
    func testAllModulesImportableAndCallable() {
        XCTAssertEqual(ContractVersion.current, "0-dev")
        XCTAssertFalse(StorageModule.scope.isEmpty)
        XCTAssertNotNil(HostnameNormalizer.normalize("example.com"))
    }

    func testRouteClassification() throws {
        // 无类型表时：仅精确 ["DIRECT"] 可判定为直连，其余未知
        XCTAssertEqual(MihomoRouteClassifier.classify(chains: ["DIRECT"], proxyTypes: [:]), .direct)
        XCTAssertEqual(MihomoRouteClassifier.classify(chains: ["节点A", "组B"], proxyTypes: [:]), .unknown)
        XCTAssertEqual(MihomoRouteClassifier.classify(chains: [], proxyTypes: [:]), .unknown)
        XCTAssertEqual(MihomoRouteClassifier.classify(chains: nil, proxyTypes: [:]), .unknown)
        // 有类型表：出站节点（chains[0]）类型决定分类；末项组名不参与
        let types = ["节点A": "Vless", "组B": "Selector", "Rejecty": "Reject", "直连2": "Direct"]
        XCTAssertEqual(MihomoRouteClassifier.classify(chains: ["节点A", "组B"], proxyTypes: types), .proxy)
        XCTAssertEqual(MihomoRouteClassifier.classify(chains: ["Rejecty", "组B"], proxyTypes: types), .unknown)
        XCTAssertEqual(MihomoRouteClassifier.classify(chains: ["组B", "组B"], proxyTypes: types), .unknown)
        XCTAssertEqual(MihomoRouteClassifier.classify(chains: ["直连2", "组B"], proxyTypes: types), .direct)
    }

    func testEndpointScalarParsing() {
        let yaml = """
        mixed-port: 7897
        external-controller: 127.0.0.1:9097
        secret: "abc"
        tun:
          enable: true
        """
        XCTAssertEqual(MihomoEndpointDiscovery.scalarValue(in: yaml, key: "external-controller"), "127.0.0.1:9097")
        XCTAssertEqual(MihomoEndpointDiscovery.scalarValue(in: yaml, key: "secret"), "abc")
        XCTAssertEqual(MihomoEndpointDiscovery.scalarValue(in: yaml, key: "mixed-port"), "7897")
        // tun.enable 是嵌套行，不应被顶层解析误取
        XCTAssertNil(MihomoEndpointDiscovery.scalarValue(in: yaml, key: "enable"))
    }

    func testLoopbackNormalization() {
        XCTAssertEqual(MihomoEndpointDiscovery.normalizeLoopback("127.0.0.1:9097")?.absoluteString, "http://127.0.0.1:9097")
        XCTAssertEqual(MihomoEndpointDiscovery.normalizeLoopback("http://127.0.0.1:9097")?.absoluteString, "http://127.0.0.1:9097")
    }

    func testChunkedDecoding() throws {
        let raw = Data("4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\n".utf8)
        let decoded = try HTTPResponseParser.dechunk(raw)
        XCTAssertEqual(String(data: decoded, encoding: .utf8), "Wikipedia")
    }
}

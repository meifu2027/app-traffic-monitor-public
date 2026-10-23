import Foundation
import Darwin

/// 本机 Clash Verge/Mihomo 控制端点。
///
/// secret 仅存在于内存（与将来的 Keychain），不写入 SQLite、不写日志、不进入 DTO。
public struct ControllerEndpoint: Equatable {
    public let unixSocketPath: String?
    /// 回环 HTTP 控制接口（如 http://127.0.0.1:9097），作为兼容路径。
    public let loopbackURL: URL?
    public let secret: String?

    public init(unixSocketPath: String?, loopbackURL: URL?, secret: String?) {
        self.unixSocketPath = unixSocketPath
        self.loopbackURL = loopbackURL
        self.secret = secret
    }

    public var isAvailable: Bool {
        unixSocketPath != nil || loopbackURL != nil
    }
}

public enum MihomoEndpointDiscoveryError: Error, CustomStringConvertible {
    case notFound(detail: String)

    public var description: String {
        switch self {
        case .notFound(let detail):
            return "未发现正在运行的 Clash Verge/Mihomo 控制端点：\(detail)"
        }
    }
}

/// 只读发现本机正在运行的 Clash Verge/Mihomo 实际控制端点。
///
/// 发现优先级（R01 实测结论，2026-10-19）：
/// 1. 运行中内核进程的命令行参数 `-ext-ctl-unix <path>`（特权服务实际指定的端点，最可靠）；
/// 2. 进程参数 `-ext-ctl <addr>`（回环地址）；
/// 3. 进程参数 `-f <config>` 指向的 runtime 配置中的 `external-controller` / `secret`。
/// 用户目录下 Clash Verge 的持久配置已被实测证明可能是陈旧地址，不作为发现来源。
/// 不扫描局域网，不写入任何 Clash 配置。
public enum MihomoEndpointDiscovery {

    /// 进程列表来源，便于测试注入。
    public static var processLister: () throws -> String = {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["axo", "command"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        try p.run()
        // 先读到 EOF 再 wait，避免输出超过管道缓冲时的写端阻塞死锁。
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    public static func discover() throws -> ControllerEndpoint {
        let listing = try processLister()

        var unixPath: String?
        var loopbackAddr: String?
        var runtimeConfigPath: String?

        for rawLine in listing.split(separator: "\n") {
            let line = String(rawLine)
            // 只认真实内核进程的启动参数；排除本项目自身与任意 grep/less 等观察进程。
            guard line.contains("mihomo") || line.contains("clash") else { continue }
            guard !line.contains("mihomo-probe") else { continue }
            let args = line.split(separator: " ").map(String.init)
            for (i, token) in args.enumerated() where i + 1 < args.count {
                switch token {
                case "-ext-ctl-unix": unixPath = unixPath ?? args[i + 1]
                case "-ext-ctl": loopbackAddr = loopbackAddr ?? args[i + 1]
                case "-f": runtimeConfigPath = runtimeConfigPath ?? args[i + 1]
                default: break
                }
            }
        }

        // socket 存在性与类型校验
        if let path = unixPath {
            var st = stat()
            let isSocket = stat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFSOCK
            if !isSocket { unixPath = nil }
        }
        if let path = unixPath {
            return ControllerEndpoint(
                unixSocketPath: path,
                loopbackURL: loopbackAddr.flatMap(Self.normalizeLoopback),
                secret: runtimeConfigPath.flatMap(Self.readSecret(fromConfig:)))
        }

        // 无 unix 端点时退回 runtime config 的回环配置
        if let configPath = runtimeConfigPath,
           let controller = Self.readExternalController(fromConfig: configPath) {
            return ControllerEndpoint(
                unixSocketPath: nil,
                loopbackURL: Self.normalizeLoopback(controller),
                secret: Self.readSecret(fromConfig: configPath))
        }

        throw MihomoEndpointDiscoveryError.notFound(
            detail: "进程列表中未找到带控制端点参数的 mihomo/clash 内核进程")
    }

    /// 解析 YAML 顶层标量行 `key: value`（仅用于 runtime config 的少量字段，不引入 YAML 依赖）。
    /// 缩进行属于嵌套结构，不作为顶层键解析。
    static func scalarValue(in content: String, key: String) -> String? {
        for rawLine in content.split(separator: "\n") {
            guard !rawLine.hasPrefix(" ") && !rawLine.hasPrefix("\t") else { continue }
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasSuffix(":") else { continue }
            guard line.hasPrefix(key + ":") else { continue }
            let value = line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
            let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    static func readExternalController(fromConfig path: String) -> String? {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return scalarValue(in: content, key: "external-controller")
    }

    static func readSecret(fromConfig path: String) -> String? {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return scalarValue(in: content, key: "secret")
    }

    static func normalizeLoopback(_ addr: String) -> URL? {
        var a = addr
        if !a.hasPrefix("http://") && !a.hasPrefix("https://") {
            a = "http://" + a
        }
        return URL(string: a)
    }
}

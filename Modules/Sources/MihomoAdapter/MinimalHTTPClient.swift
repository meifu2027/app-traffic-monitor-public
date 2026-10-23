import Foundation
import Darwin

/// 最小只读 HTTP/1.1 客户端：支持 AF_UNIX socket 与回环 HTTP 两条路径。
///
/// R01 边界说明：
/// - 每个请求独立连接（Connection: close），只做 GET，不支持写操作；
/// - 响应支持 Content-Length 与 chunked 两种长度语义；
/// - AF_UNIX 采用 POSIX socket 实现（NWConnection 对 unix endpoint 实测报 ENETDOWN）；
/// - WebSocket 订阅（/connections 的周期快照）属于 R03 的采样器职责，不在本类实现；
/// - secret 只存在于内存，不进入任何日志输出。
final class MinimalHTTPClient {

    private let unixSocketPath: String?
    private let loopbackURL: URL?
    private let secret: String?

    init(endpoint: ControllerEndpoint) {
        self.unixSocketPath = endpoint.unixSocketPath
        self.loopbackURL = endpoint.loopbackURL
        self.secret = endpoint.secret
    }

    enum HTTPError: Error, CustomStringConvertible {
        case noEndpoint
        case socketCreationFailed(errno: Int32)
        case connectFailed(errno: Int32)
        case sendFailed(errno: Int32)
        case receiveFailed(errno: Int32)
        case badStatus(code: Int)
        case malformedResponse(String)
        var description: String {
            switch self {
            case .noEndpoint: return "端点不可用（无 unix socket 也无回环地址）"
            case .socketCreationFailed(let e): return "socket() 失败 errno=\(e)"
            case .connectFailed(let e): return "connect() 失败 errno=\(e)"
            case .sendFailed(let e): return "send() 失败 errno=\(e)"
            case .receiveFailed(let e): return "recv() 失败 errno=\(e)"
            case .badStatus(let code): return "HTTP 状态码异常: \(code)"
            case .malformedResponse(let detail): return "响应无法解析: \(detail)"
            }
        }
    }

    func get(_ path: String, timeout: TimeInterval = 5) throws -> Data {
        if let socket = unixSocketPath {
            return try getViaUnixSocket(socket, path: path, timeout: timeout)
        }
        if let base = loopbackURL {
            return try getViaURLSession(base, path: path, timeout: timeout)
        }
        throw HTTPError.noEndpoint
    }

    // MARK: - 回环 HTTP（URLSession）

    private func getViaURLSession(_ base: URL, path: String, timeout: TimeInterval) throws -> Data {
        guard let url = URL(string: path, relativeTo: base) else {
            throw HTTPError.malformedResponse("非法路径: \(path)")
        }
        var request = URLRequest(url: url.absoluteURL, timeoutInterval: timeout)
        if let secret = secret, !secret.isEmpty {
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }
        let sem = DispatchSemaphore(value: 0)
        var payload: Data?
        var failure: Error?
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error { failure = error }
            else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                failure = HTTPError.badStatus(code: http.statusCode)
            } else { payload = data }
            sem.signal()
        }
        task.resume()
        guard sem.wait(timeout: .now() + timeout + 1) == .success else {
            task.cancel()
            throw HTTPError.receiveFailed(errno: ETIMEDOUT)
        }
        if let failure = failure { throw failure }
        return payload ?? Data()
    }

    // MARK: - AF_UNIX（POSIX socket）

    private func getViaUnixSocket(_ socketPath: String, path: String, timeout: TimeInterval) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HTTPError.socketCreationFailed(errno: errno) }
        defer { close(fd) }

        // 读超时，避免对端无响应时永久阻塞
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { cString in
            strncpy(&addr.sun_path, cString, MemoryLayout<sockaddr_un>.size - 1)
        }
        let connectResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else { throw HTTPError.connectFailed(errno: errno) }

        var request = "GET \(path) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n"
        if let secret = secret, !secret.isEmpty {
            request += "Authorization: Bearer \(secret)\r\n"
        }
        request += "\r\n"

        try sendAll(fd, request: request)

        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n < 0 { throw HTTPError.receiveFailed(errno: errno) }
            if n == 0 { break }
            received.append(contentsOf: buffer[0..<n])
        }
        guard !received.isEmpty else {
            throw HTTPError.malformedResponse("空响应")
        }
        return try HTTPResponseParser.body(from: received)
    }

    private func sendAll(_ fd: Int32, request: String) throws {
        let bytes = Array(request.utf8)
        var offset = 0
        while offset < bytes.count {
            let sent = bytes.withUnsafeBufferPointer { buf -> Int in
                send(fd, buf.baseAddress! + offset, bytes.count - offset, 0)
            }
            guard sent > 0 else { throw HTTPError.sendFailed(errno: errno) }
            offset += sent
        }
    }
}

/// HTTP/1.1 响应解析：状态行 + 头 + body（Content-Length 或 chunked）。
enum HTTPResponseParser {

    static func body(from raw: Data) throws -> Data {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = raw.range(of: separator) else {
            throw MinimalHTTPClient.HTTPError.malformedResponse("缺少头部结束符")
        }
        let headerData = raw[raw.startIndex..<headerEnd.lowerBound]
        let bodyData = Data(raw[headerEnd.upperBound...])
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw MinimalHTTPClient.HTTPError.malformedResponse("头部非 UTF-8")
        }
        var lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false)[...]
        guard let statusLine = lines.first else {
            throw MinimalHTTPClient.HTTPError.malformedResponse("缺少状态行")
        }
        let parts = statusLine.split(separator: " ")
        guard parts.count >= 2, let code = Int(parts[1]), (200..<300).contains(code) else {
            throw MinimalHTTPClient.HTTPError.badStatus(code: parts.count >= 2 ? Int(parts[1]) ?? -1 : -1)
        }
        lines = lines.dropFirst()
        var contentLength: Int?
        var chunked = false
        for line in lines {
            let kv = line.split(separator: ":", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let key = kv[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = kv[1].trimmingCharacters(in: .whitespaces)
            if key == "content-length" { contentLength = Int(value) }
            if key == "transfer-encoding", value.lowercased().contains("chunked") { chunked = true }
        }
        if chunked {
            return try dechunk(bodyData)
        }
        if let length = contentLength {
            return Data(bodyData.prefix(length))
        }
        return bodyData
    }

    static func dechunk(_ input: Data) throws -> Data {
        var output = Data()
        var cursor = input.startIndex
        while cursor < input.endIndex {
            guard let lineEnd = input.range(of: Data("\r\n".utf8), in: cursor..<input.endIndex) else {
                throw MinimalHTTPClient.HTTPError.malformedResponse("chunked 大小行缺失")
            }
            guard let size = Int(String(data: input[cursor..<lineEnd.lowerBound], encoding: .utf8) ?? "", radix: 16) else {
                throw MinimalHTTPClient.HTTPError.malformedResponse("chunked 大小行非法")
            }
            if size == 0 { break }
            let bodyStart = input.index(lineEnd.upperBound, offsetBy: 0)
            guard input.distance(from: bodyStart, to: input.endIndex) >= size else {
                throw MinimalHTTPClient.HTTPError.malformedResponse("chunked 数据不完整")
            }
            let chunkEnd = input.index(bodyStart, offsetBy: size)
            output.append(input[bodyStart..<chunkEnd])
            cursor = input.index(chunkEnd, offsetBy:2, limitedBy: input.endIndex) ?? input.endIndex
        }
        return output
    }
}

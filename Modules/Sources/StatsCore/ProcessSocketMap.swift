import Darwin
import Foundation

/// 本用户进程的 socket 表：`(协议, 本地端口) → 进程路径`。
///
/// 用途：TUN 模式下 mihomo 连接的 metadata 保留原始 app 的源端口，
/// 通过本表把 (tcp/udp, sourcePort) 映射回发起进程，实现 app 归属。
///
/// 边界（如实）：
/// - 仅能枚举当前用户可见的进程（root 进程如 mihomo 本体的 socket 不可见，不会误归属）；
/// - 映射按采样时刻快照，短连接在扫描间隔内关闭则归属失败 → 记为未归属；
/// - 端口在本机内视为唯一（不区分网卡地址），跨网卡同端口极端冲突按后扫覆盖处理。
///
/// 实现备注（对照 SDK sys/proc_info.h）：
/// - UDP socket 的 soi_kind 为 SOCKINFO_IN(1)，TCP 为 SOCKINFO_TCP(2)；
/// - in_sockinfo.insi_lport 为 int 字段、值按网络字节序存储。
public final class ProcessSocketMap {

    public struct Entry: Equatable {
        public let pid: Int32
        public let processPath: String
    }

    public struct Key: Hashable {
        public let isTCP: Bool
        public let port: UInt16
        public init(isTCP: Bool, port: UInt16) {
            self.isTCP = isTCP
            self.port = port
        }
    }

    private(set) public var table: [Key: Entry] = [:]

    public init() {}

    /// 全量扫描并替换内部表。
    public func refresh() {
        var newTable: [Key: Entry] = [:]

        var pids = [Int32](repeating: 0, count: 8192)
        let pidCount: Int32 = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard pidCount > 0 else { return }

        for i in 0..<Int(pidCount) {
            let pid = pids[i]
            guard pid > 0 else { continue }
            var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard proc_pidpath(pid, &pathBuffer, UInt32(MAXPATHLEN)) > 0 else { continue }
            let path = String(cString: pathBuffer)
            guard !path.isEmpty else { continue }

            // fd 数组探测-扩容：浏览器/Java 等 fd 大户超过初始容量时
            // proc_pidinfo 会因缓冲不足失败，导致整个进程被跳过（曾致 TUN 大户全部未归属）。
            var fdCapacity = 1024
            iterate: while fdCapacity <= 32768 {
                var fdBuffer = [proc_fdinfo](repeating: proc_fdinfo(), count: fdCapacity)
                let bufferSize = Int32(MemoryLayout<proc_fdinfo>.size * fdCapacity)
                let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fdBuffer, bufferSize)
                if bytes <= 0 { break }
                let fdCount = Int(bytes) / MemoryLayout<proc_fdinfo>.size
                if fdCount >= fdCapacity {
                    fdCapacity *= 4
                    continue iterate
                }

                for j in 0..<fdCount {
                    guard fdBuffer[j].proc_fdtype == PROX_FDTYPE_SOCKET else { continue }
                    var info = socket_fdinfo()
                    let infoBytes = proc_pidfdinfo(pid, fdBuffer[j].proc_fd, PROC_PIDFDSOCKETINFO,
                                                   &info, Int32(MemoryLayout<socket_fdinfo>.size))
                    guard infoBytes == Int32(MemoryLayout<socket_fdinfo>.size) else { continue }

                    let family = info.psi.soi_family
                    guard family == AF_INET || family == AF_INET6 else { continue }

                    let key: Key
                    switch info.psi.soi_kind {
                    case Int32(SOCKINFO_TCP):
                        let raw = info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport
                        guard raw != 0 else { continue }
                        key = Key(isTCP: true, port: UInt16(bigEndian: UInt16(truncatingIfNeeded: raw)))
                    case Int32(SOCKINFO_IN):
                        let raw = info.psi.soi_proto.pri_in.insi_lport
                        guard raw != 0 else { continue }
                        key = Key(isTCP: false, port: UInt16(bigEndian: UInt16(truncatingIfNeeded: raw)))
                    default:
                        continue
                    }
                    if newTable[key] == nil {
                        newTable[key] = Entry(pid: pid, processPath: path)
                    }
                }
                break
            }
        }
        table = newTable
    }

    /// 查询。
    public func entry(isTCP: Bool, port: UInt16) -> Entry? {
        table[Key(isTCP: isTCP, port: port)]
    }
}

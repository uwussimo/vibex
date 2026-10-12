import Darwin
import Foundation
import os

/// Works out which project window an MCP request comes from.
///
/// Claude Code runs inside one of Vibex's terminal tabs, so the process holding the client end of
/// the TCP connection is a descendant of that tab's shell. For each window, walk its shells'
/// descendants with libproc and look for a TCP socket whose local port is the request's source port.
/// Sub-millisecond for a handful of tabs; results are cached per source port.
final class CallerResolver {
    struct Candidate {
        let windowID: String
        let shellPIDs: [pid_t]
    }

    private var cache: [UInt16: (windowID: String?, at: Date)] = [:]
    private let processes: ProcessTable

    init(processes: ProcessTable = .live) {
        self.processes = processes
    }

    func windowID(forClientPort port: UInt16, among candidates: [Candidate]) -> String? {
        if let hit = cache[port], Date().timeIntervalSince(hit.at) < 600 { return hit.windowID }
        var found: String?
        search: for candidate in candidates {
            for shell in candidate.shellPIDs where shell > 0 {
                for pid in [shell] + processes.descendants(shell) where processes.localTCPPorts(pid).contains(port) {
                    found = candidate.windowID
                    break search
                }
            }
        }
        if cache.count > 256 { cache.removeAll() }
        cache[port] = (found, Date())
        return found
    }
}

/// Process queries, swappable in tests.
nonisolated struct ProcessTable: Sendable {
    var children: @Sendable (pid_t) -> [pid_t]
    var localTCPPorts: @Sendable (pid_t) -> [UInt16]

    func descendants(_ pid: pid_t) -> [pid_t] {
        var result: [pid_t] = []
        var queue = [pid]
        while let next = queue.popLast(), result.count < 4096 {
            let kids = children(next)
            result += kids
            queue += kids
        }
        return result
    }

    nonisolated static let live = ProcessTable(
        children: { pid in
            var buffer = [pid_t](repeating: 0, count: 512)
            let count = proc_listchildpids(pid, &buffer, Int32(buffer.count * MemoryLayout<pid_t>.size))
            return count > 0 ? Array(buffer.prefix(Int(count))) : []
        },
        localTCPPorts: { pid in
            let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard size > 0 else { return [] }
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.stride)
            let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, size)
            guard filled > 0 else { return [] }
            var ports: [UInt16] = []
            for fd in fds.prefix(Int(filled) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
                var info = socket_fdinfo()
                let read = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, Int32(MemoryLayout<socket_fdinfo>.size))
                guard read == MemoryLayout<socket_fdinfo>.size, info.psi.soi_kind == SOCKINFO_TCP else { continue }
                let raw = UInt16(truncatingIfNeeded: info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport)
                ports.append(UInt16(bigEndian: raw))
            }
            return ports
        }
    )
}

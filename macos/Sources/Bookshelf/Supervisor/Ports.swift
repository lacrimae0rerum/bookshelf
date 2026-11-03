import Darwin
import Foundation

/// Who holds a loopback port (§17).
enum Ports {
    struct Owner: Equatable, Sendable, CustomStringConvertible {
        let pid: pid_t
        let command: String
        var description: String { "\(command) (pid \(pid))" }
    }

    /// `true` when `127.0.0.1:port` can be bound, as the service will bind it.
    /// `SO_REUSEADDR`, like uvicorn and node: a socket in TIME_WAIT does not count.
    static func isFree(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = loopback(port)
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    /// `true` when something accepts a connection on `127.0.0.1:port`.
    static func accepts(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = loopback(port)
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    /// Waits up to `timeout` for `port` to be free: a process that just stopped may still
    /// hold it for a moment.
    static func waitFree(_ port: UInt16, timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !isFree(port) {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    /// The processes listening on `port`, from `lsof`.
    static func owners(of port: UInt16) async -> [Owner] {
        let result = await Command.run(
            ["/usr/sbin/lsof", "-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpc"], env: [:], timeout: .seconds(5)
        )
        return parseLsof(result.output)
    }

    /// `lsof -F pc` output: a `p<pid>` line, then `c<command>`, per process.
    static func parseLsof(_ output: String) -> [Owner] {
        var owners: [Owner] = []
        var pid: pid_t?
        for line in output.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("p") {
                pid = pid_t(line.dropFirst())
            } else if line.hasPrefix("c"), let current = pid {
                owners.append(Owner(pid: current, command: String(line.dropFirst())))
                pid = nil
            }
        }
        return owners
    }

    private static func loopback(_ port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr(Loopback.host)
        return address
    }
}

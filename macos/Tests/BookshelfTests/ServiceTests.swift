import Darwin
import Foundation
import Testing
@testable import Bookshelf

struct LaunchSpecTests {
    let repo = Repository(root: URL(fileURLWithPath: "/repo"))
    let tools = Tools(uv: "/bin/uv", node: "/bin/node", pnpm: "/bin/pnpm", claude: nil)

    @Test func theAPIBindsTheLoopbackAddress() {
        let spec = LaunchSpec.api(repo: repo, tools: tools)
        #expect(spec.argv == ["/bin/uv", "run", "fastapi", "run", "app/main.py", "--host", "127.0.0.1", "--port", "8000"])
        #expect(spec.cwd.path == "/repo/backend")
        #expect(spec.readyURL.absoluteString == "http://127.0.0.1:8000/health/ready")
        #expect(spec.log == .api)
    }

    @Test func theWebRunsCompiledWithItsAddressesSet() {
        let spec = LaunchSpec.web(repo: repo, tools: tools, hasEnvFile: true)
        #expect(spec.argv == ["/bin/node", "--env-file=.env", "dist/server/entry.mjs"])
        #expect(spec.extraEnv == ["HOST": "127.0.0.1", "PORT": "4321", "API_INTERNAL_URL": "http://127.0.0.1:8000/api/v1"])
        #expect(LaunchSpec.web(repo: repo, tools: tools, hasEnvFile: false).argv == ["/bin/node", "dist/server/entry.mjs"])
    }
}

struct PortsTests {
    @Test func parsesLsofFieldOutput() {
        let output = "p123\ncnode\np456\ncpython3.1\n"
        #expect(Ports.parseLsof(output) == [.init(pid: 123, command: "node"), .init(pid: 456, command: "python3.1")])
        #expect(Ports.parseLsof("") == [])
    }

    @Test func seesAListenerAndItsOwner() async throws {
        let (fd, port) = try listen()
        #expect(!Ports.isFree(port))
        #expect(Ports.accepts(port))
        #expect(await Ports.owners(of: port).map(\.pid) == [getpid()])
        close(fd)
        #expect(await Ports.waitFree(port, timeout: .seconds(1)))
    }

    /// A listening socket on 127.0.0.1 and a port the system picks.
    func listen() throws -> (Int32, UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0 && Darwin.listen(fd, 1) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        try #require(ok)
        return (fd, UInt16(bigEndian: address.sin_port))
    }
}

struct QueueSummaryTests {
    @Test func decodesTheAPIsQueueStatus() throws {
        let json = #"{"workers":[],"queued":5,"running":2,"unclaimed_kinds":[],"paused":false,"paused_reason":null,"slots":2}"#
        let queue = try #require(JobsAPI.decode(Data(json.utf8)))
        #expect(queue == QueueSummary(queued: 5, running: 2, paused: false, pausedReason: nil))
        #expect(queue.summary == "2 running · 5 queued")
    }

    @Test func saysWhyTheQueuePaused() {
        #expect(QueueSummary(queued: 3, running: 0, paused: true, pausedReason: "usage limit until 18:00").summary == "paused: usage limit until 18:00")
        #expect(QueueSummary(queued: 0, running: 0, paused: false, pausedReason: nil).summary == "idle")
    }
}

@MainActor
struct SmokeReportTests {
    @Test func writesOneLinePerEventWhenAsked() throws {
        let file = try temporaryDirectory().appending(path: "report.txt")
        let report = SmokeReport(arguments: ["--smoke", "--smoke-report", file.path], launched: .now)
        #expect(report.quitWhenShown)
        report.record("ready")
        report.record("shown")
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        #expect(lines.map { $0.split(separator: "=")[0] } == ["ready", "shown"])
    }

    @Test func isSilentWithoutAReport() {
        let report = SmokeReport(arguments: ["--smoke-report"], launched: .now)
        #expect(!report.quitWhenShown)
        report.record("ready")  // no file, no crash
    }
}

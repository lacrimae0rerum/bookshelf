import Darwin
import Foundation
import Testing
@testable import Bookshelf

/// M9 with real processes: which signal a stop needs, and that nothing is left behind.
@Suite(.serialized) struct StopSequenceTests {
    let fast = StopTimings(term: .milliseconds(300), interrupt: .milliseconds(200))

    func stop(_ pid: pid_t) -> (StopStep, [String]) {
        let queue = ExitQueue()
        #expect(queue.watch(pid: pid))
        var lines: [String] = []
        let step = StopSequence.run(
            child: pid, group: pid, timings: fast,
            waitExit: { timeout in
                guard queue.next(timeout: timeout) == .exited(pid) else { return false }
                _ = ExitStatus.reap(pid, block: true)
                return true
            },
            log: { lines.append($0) }
        )
        return (step, lines)
    }

    @Test func aCommandThatHonoursSIGTERMStopsAtTheFirstStep() throws {
        let pid = try spawnShell("while :; do sleep 0.05; done")
        let (step, lines) = stop(pid)
        #expect(step == .term)
        #expect(lines == ["SIGTERM to \(pid)"])
        #expect(!isAlive(pid))
    }

    /// Starts `script` after its traps are set: a signal sent sooner would find none.
    func spawnTrapping(_ traps: String, then script: String) throws -> pid_t {
        let ready = try temporaryDirectory().appending(path: "ready").path
        let pid = try spawnShell("\(traps); touch \(ready); \(script)")
        #expect(eventually { FileManager.default.fileExists(atPath: ready) })
        return pid
    }

    @Test func aCommandThatIgnoresSIGTERMGetsSIGINT() throws {
        let pid = try spawnTrapping(#"trap "" TERM; trap "exit 0" INT"#, then: "while :; do sleep 0.05; done")
        let (step, _) = stop(pid)
        #expect(step == .interrupt)
        #expect(!isAlive(pid))
    }

    @Test func aCommandThatIgnoresBothLosesItsWholeGroupToSIGKILL() throws {
        let marker = try temporaryDirectory().appending(path: "grandchild.pid").path
        let pid = try spawnTrapping(#"trap "" TERM INT"#, then: "sleep 30 & echo $! > \(marker); while :; do sleep 0.05; done")
        #expect(eventually { (try? String(contentsOfFile: marker, encoding: .utf8))?.hasSuffix("\n") == true })
        let grandchild = pid_t(try String(contentsOfFile: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
        let (step, _) = stop(pid)
        #expect(step == .kill)
        _ = ExitStatus.reap(pid, block: true)
        #expect(eventually { !isAlive(grandchild) })
    }
}

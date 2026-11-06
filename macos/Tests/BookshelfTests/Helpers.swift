import Darwin
import Foundation
@testable import Bookshelf

/// A fresh temporary folder per test.
func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "bookshelf-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// `/bin/sh -c script` in a process group of its own.
func spawnShell(_ script: String) throws -> pid_t {
    try Spawn.run(["/bin/sh", "-c", script], env: ["PATH": "/usr/bin:/bin"], newGroup: true)
}

func isAlive(_ pid: pid_t) -> Bool {
    kill(pid, 0) == 0
}

/// Polls until `condition` holds or `timeout` passes.
func eventually(timeout: Duration = .seconds(2), _ condition: () -> Bool) -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        usleep(10_000)
    }
    return condition()
}

/// A job queue as `GET /jobs/queue` reads it.
func jobQueue(running: Int = 0, queued: Int = 0, paused: Bool = false) -> QueueSummary {
    QueueSummary(queued: queued, running: running, paused: paused, pausedReason: nil)
}

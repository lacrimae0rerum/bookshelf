import Foundation
import Testing
@testable import Bookshelf

struct LogFilesTests {
    @Test func rotatesAboveTheLimitAndKeepsThree() throws {
        let dir = try temporaryDirectory()
        let log = dir.appending(path: "api.log")
        for generation in 1...5 {
            try String(repeating: "\(generation)", count: 20).write(to: log, atomically: true, encoding: .utf8)
            LogFiles.rotate(log, limit: 10, keep: 3)
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(names == ["api.log.1", "api.log.2", "api.log.3"])
        #expect(try String(contentsOf: dir.appending(path: "api.log.1"), encoding: .utf8).hasPrefix("5"))
    }

    @Test func leavesASmallLogAlone() throws {
        let log = try temporaryDirectory().appending(path: "web.log")
        try "short".write(to: log, atomically: true, encoding: .utf8)
        LogFiles.rotate(log, limit: 10)
        #expect(FileManager.default.fileExists(atPath: log.path))
    }

    @Test func readsTheLastLines() throws {
        let log = try temporaryDirectory().appending(path: "setup.log")
        try (1...50).map { "line \($0)" }.joined(separator: "\n").appending("\n").write(to: log, atomically: true, encoding: .utf8)
        #expect(LogFiles.tail(log, lines: 3) == "line 48\nline 49\nline 50")
        #expect(LogFiles.tail(log.appending(path: "missing")) == "")
    }
}

struct CommandTests {
    @Test func capturesOutputAndStatus() async {
        let result = await Command.run(["/bin/sh", "-c", "echo out; echo err >&2; exit 4"], env: [:], timeout: .seconds(5))
        #expect(result.status == 4)
        #expect(result.output.contains("out") && result.output.contains("err"))
        #expect(!result.timedOut)
    }

    @Test func appendsToALogInstead() async throws {
        let log = try temporaryDirectory().appending(path: "setup.log")
        let result = await Command.run(["/bin/echo", "hello"], env: [:], log: log, timeout: .seconds(5))
        #expect(result.succeeded)
        #expect(LogFiles.tail(log).hasSuffix("hello"))
    }

    @Test func endsACommandThatRunsTooLong() async {
        let result = await Command.run(["/bin/sleep", "10"], env: [:], timeout: .milliseconds(100))
        #expect(result.timedOut)
        #expect(!result.succeeded)
    }

    @Test func reportsACommandThatCannotStart() async {
        let result = await Command.run(["/nope/missing"], env: [:], timeout: .seconds(1))
        #expect(result.status == -1)
    }
}

struct EventualTests {
    @Test func wakesEveryWaiterOnceAndTimesOut() async {
        let value = Eventual<Int>()
        #expect(await value.value(timeout: .milliseconds(20)) == nil)
        async let first = value.value()
        async let second = value.value(timeout: .seconds(5))
        value.fulfill(7)
        value.fulfill(8)
        #expect(await first == 7)
        #expect(await second == 7)
        #expect(await value.value(timeout: .zero) == 7)
    }
}

struct StateStoreTests {
    @Test func roundTripsTheLastPathCapture() throws {
        let url = try temporaryDirectory().appending(path: "state.json")
        #expect(StateStore.load(url) == AppState())
        let state = AppState(path: "/usr/bin:/bin", pathCapturedAt: Date(timeIntervalSince1970: 1_800_000_000))
        try StateStore.save(state, to: url)
        #expect(StateStore.load(url) == state)
    }
}

struct RepositoryTests {
    @Test func acceptsOnlyAFolderThatLooksLikeTheRepo() throws {
        let root = try temporaryDirectory()
        #expect(Repository.at(root.path) == nil)
        for folder in ["backend", "frontend", "scripts"] {
            try FileManager.default.createDirectory(at: root.appending(path: folder), withIntermediateDirectories: true)
        }
        #expect(Repository.at(root.path) == nil)
        try "".write(to: root.appending(path: "scripts/pg-local.sh"), atomically: true, encoding: .utf8)
        #expect(Repository.at(root.path)?.root.path == root.standardizedFileURL.path)
    }
}

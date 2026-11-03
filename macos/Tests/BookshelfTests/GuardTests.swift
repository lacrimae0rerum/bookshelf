import Darwin
import Foundation
import Testing
@testable import Bookshelf

@Suite(.serialized) struct GuardTests {
    let fast = StopTimings(term: .milliseconds(300), interrupt: .milliseconds(200))

    @Test func parsesItsArguments() {
        #expect(Guard.parse(["--guard", "123", "--", "/usr/bin/true", "-x"]) == Guard.Arguments(appPID: 123, command: ["/usr/bin/true", "-x"]))
        #expect(Guard.parse(["--guard", "123", "/usr/bin/true"]) == nil)
        #expect(Guard.parse(["--guard", "1", "--", "/usr/bin/true"]) == nil)
        #expect(Guard.parse(["--guard", "abc", "--", "/usr/bin/true"]) == nil)
        #expect(Guard.parse(["--guard", "123", "--"]) == nil)
    }

    /// The app's exit (here: a stand-in that exits after 0.2 s) stops the command.
    @Test func stopsTheCommandWhenTheAppExits() throws {
        let app = try spawnShell("sleep 0.2")
        let command = try spawnShell("while :; do sleep 0.05; done")
        let started = ContinuousClock.now
        let outcome = GuardLoop.run(appPID: app, child: command, group: command, queue: ExitQueue(), timings: fast, log: { _ in })
        #expect(outcome == .stopped(.term, reason: "app \(app) exited"))
        #expect(ContinuousClock.now - started < .seconds(1))
        #expect(!isAlive(command))
        _ = ExitStatus.reap(app, block: true)
    }

    /// An app that is already gone when the guard starts: caught by the check after registering.
    @Test func stopsAtOnceWhenTheAppIsAlreadyGone() throws {
        let app = try spawnShell("exit 0")
        _ = ExitStatus.reap(app, block: true)
        let command = try spawnShell("while :; do sleep 0.05; done")
        let outcome = GuardLoop.run(appPID: app, child: command, group: command, queue: ExitQueue(), timings: fast, log: { _ in })
        #expect(outcome == .stopped(.term, reason: "app \(app) is gone"))
        #expect(!isAlive(command))
    }

    @Test func reportsTheStatusOfACommandThatExitsByItself() throws {
        let app = try spawnShell("sleep 5")
        defer { kill(app, SIGKILL); _ = ExitStatus.reap(app, block: true) }
        let command = try spawnShell("sleep 0.1; exit 3")
        let outcome = GuardLoop.run(appPID: app, child: command, group: command, queue: ExitQueue(), timings: fast, log: { _ in })
        #expect(outcome == .childExited(3))
    }

    @Test func groupCleanupKillsEveryMemberButTheCaller() throws {
        let leader = try spawnShell("sleep 30 & sleep 30 & wait")
        #expect(eventually { GroupCleanup.members(of: leader).count == 3 })
        #expect(GroupCleanup.killOthers(in: leader) == 3)
        _ = ExitStatus.reap(leader, block: true)
        #expect(eventually { GroupCleanup.members(of: leader).isEmpty })
    }

    @Test func exitStatusesDecodeLikeAShell() {
        #expect(ExitStatus.decode(3 << 8) == 3)
        #expect(ExitStatus.decode(SIGKILL) == 128 + SIGKILL)
    }
}

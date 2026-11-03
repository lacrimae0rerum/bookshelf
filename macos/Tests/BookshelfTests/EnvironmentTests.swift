import Foundation
import Testing
@testable import Bookshelf

struct ShellPathTests {
    @Test func takesTheLastLineAndDropsRelativeAndRepeatedEntries() {
        let output = "Welcome!\n/opt/homebrew/bin:bin:/usr/bin::/opt/homebrew/bin:/Users/me/.local/bin"
        #expect(ShellPath.parse(output) == "/opt/homebrew/bin:/usr/bin:/Users/me/.local/bin")
    }

    @Test func findsNoPathInJunk() {
        #expect(ShellPath.parse("") == nil)
        #expect(ShellPath.parse("no path here") == nil)
    }

    @Test func givesTheShellOnlyTheMinimalVariables() async throws {
        let base = ["HOME": "/Users/me", "CLAUDECODE": "1", "PATH": "/usr/bin:/bin"]
        let printed = try await ShellPath.capture(base: base, argv: ["/bin/sh", "-c", #"echo "$HOME:${CLAUDECODE:-/unset}""#])
        #expect(printed == "/Users/me:/unset")
    }

    @Test func givesUpOnAShellThatHangs() async {
        let started = ContinuousClock.now
        await #expect(throws: ShellPath.CaptureError.self) {
            try await ShellPath.capture(base: [:], argv: ["/bin/sleep", "10"], timeout: .milliseconds(200))
        }
        #expect(ContinuousClock.now - started < .seconds(2))
    }
}

struct ChildEnvironmentTests {
    let account = ["HOME": "/Users/me", "USER": "me", "LOGNAME": "me", "SHELL": "/bin/zsh", "TMPDIR": "/tmp/me/", "LANG": "en_US.UTF-8"]

    @Test func passesOnlyTheAllowlistAndTheAppsOwnVariables() {
        let base = [
            "HOME": "/Users/me", "USER": "me", "LANG": "es_ES.UTF-8", "LC_ALL": "es_ES.UTF-8",
            "CLAUDECODE": "1", "AI_AGENT": "claude", "TERM_PROGRAM": "iTerm", "PATH": "/usr/bin:/bin",
            "BOOKSHELF_DATABASE_URL": "postgresql://elsewhere",
        ]
        let env = ChildEnvironment.build(base: base, path: "/opt/homebrew/bin:/usr/bin", account: account, extra: ["PORT": "4321"])
        #expect(env["PATH"] == "/opt/homebrew/bin:/usr/bin")
        #expect(env["LANG"] == "es_ES.UTF-8")
        #expect(env["LC_ALL"] == "es_ES.UTF-8")
        #expect(env["PORT"] == "4321")
        for dropped in ["CLAUDECODE", "AI_AGENT", "TERM_PROGRAM", "BOOKSHELF_DATABASE_URL"] {
            #expect(env[dropped] == nil, "\(dropped) leaked")
        }
    }

    @Test func fillsWhatAnEmptyEnvironmentLacksFromTheAccount() {
        let env = ChildEnvironment.build(base: [:], path: "/usr/bin", account: account)
        #expect(env == account.merging(["PATH": "/usr/bin"]) { $1 })
    }

    @Test func theCurrentAccountHasAHomeAndATemporaryFolder() {
        let current = ChildEnvironment.Account.current()
        #expect(current["HOME"]?.hasPrefix("/") == true)
        #expect(current["TMPDIR"]?.hasPrefix("/") == true)
    }
}

struct ToolResolverTests {
    func folder(with tools: [String]) throws -> URL {
        let dir = try temporaryDirectory()
        for tool in tools {
            let url = dir.appending(path: tool)
            try "#!/bin/sh\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        return dir
    }

    @Test func resolvesAbsolutePathsInPathOrder() throws {
        let first = try folder(with: ["uv", "node"])
        let second = try folder(with: ["uv", "node", "pnpm", "claude"])
        let tools = try ToolResolver.resolve(path: "\(first.path):\(second.path)")
        #expect(tools.uv == first.appending(path: "uv").path)
        #expect(tools.pnpm == second.appending(path: "pnpm").path)
        #expect(tools.claude == second.appending(path: "claude").path)
    }

    @Test func namesTheMissingToolAndHowToInstallIt() throws {
        let dir = try folder(with: ["uv", "pnpm"])
        #expect(throws: MissingTool(name: "node", fix: "brew install node")) {
            try ToolResolver.resolve(path: dir.path)
        }
    }

    @Test func claudeIsOptionalAndAnOverrideWins() throws {
        let dir = try folder(with: ["uv", "node", "pnpm", "claude"])
        let fake = try folder(with: ["fake-claude"]).appending(path: "fake-claude").path
        #expect(try ToolResolver.resolve(path: dir.path, claudeOverride: fake).claude == fake)
        #expect(try ToolResolver.resolve(path: dir.path, claudeOverride: "/nope/claude").claude == nil)
        let noClaude = try folder(with: ["uv", "node", "pnpm"])
        #expect(try ToolResolver.resolve(path: noClaude.path).claude == nil)
    }
}

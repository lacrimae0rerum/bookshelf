import Darwin
import Foundation

struct CommandResult: Sendable {
    /// The exit status, or the signal number when a signal ended it; `-1`: it never started.
    let status: Int32
    /// Captured stdout and stderr (empty when the output went to a log file).
    let output: String
    let timedOut: Bool

    var succeeded: Bool { status == 0 && !timedOut }
}

/// One-shot commands: the login shell's PATH, `lsof`, `pg-local.sh`, `astro build`.
enum Command {
    /// Runs `argv` (`argv[0]` absolute) to the end, stdin from `/dev/null`. The output is
    /// appended to `log` when given, else captured. Past `timeout`: SIGTERM, then SIGKILL 1 s on.
    static func run(
        _ argv: [String],
        env: [String: String],
        cwd: URL? = nil,
        log: URL? = nil,
        timeout: Duration
    ) async -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        process.environment = env
        if let cwd { process.currentDirectoryURL = cwd }
        process.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        if let log, let handle = LogFiles.appendHandle(log) {
            handle.write(Data("--- \(Log.timestamp()) \(argv.joined(separator: " "))\n".utf8))
            process.standardOutput = handle
            process.standardError = handle
        } else {
            process.standardOutput = pipe
            process.standardError = pipe
        }

        let exit = Eventual<Int32>()
        process.terminationHandler = { exit.fulfill($0.terminationStatus) }
        do {
            try process.run()
        } catch {
            try? pipe.fileHandleForWriting.close()
            return CommandResult(status: -1, output: "cannot start \(argv[0]): \(error.localizedDescription)", timedOut: false)
        }
        let output = OutputBuffer()
        if log == nil {
            pipe.fileHandleForReading.readabilityHandler = { handle in output.read(handle) }
        }

        // `Process` starts the command in a process group of its own: signal the group, so a
        // timeout also ends what the command started (`node` under `pnpm`, a profile's job).
        let pid = process.processIdentifier
        let signalCommand: (Int32) -> Void = { number in
            _ = getpgid(pid) == pid ? killpg(pid, number) : kill(pid, number)
        }
        var status = await exit.value(timeout: timeout)
        let timedOut = status == nil
        if timedOut {
            signalCommand(SIGTERM)
            status = await exit.value(timeout: .seconds(1))
            if status == nil {
                signalCommand(SIGKILL)
                status = await exit.value()
            }
        }
        // Whatever is still holding the pipe (a background job) gets half a second, no more.
        if log == nil { _ = await output.end.value(timeout: .milliseconds(500)) }
        return CommandResult(status: status ?? -1, output: output.text, timedOut: timedOut)
    }
}

/// A command's captured output, read as it comes so a full pipe never blocks it.
private final class OutputBuffer: @unchecked Sendable {
    let end = Eventual<Bool>()
    private let lock = NSLock()
    private var data = Data()

    var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }

    func read(_ handle: FileHandle) {
        let chunk = handle.availableData
        if chunk.isEmpty {
            handle.readabilityHandler = nil
            end.fulfill(true)
        } else {
            lock.withLock { data.append(chunk) }
        }
    }
}

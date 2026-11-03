import Foundation

/// The PATH of a login shell (M10, §5): GUI apps get launchd's `/usr/bin:/bin:/usr/sbin:/sbin`,
/// where none of the repo's tools live.
enum ShellPath {
    /// A login shell is enough here: `~/.zprofile` sets the PATH; `-i` is twice as slow.
    static let argv = ["/bin/zsh", "-l", "-c", #"print -rn -- "$PATH""#]
    /// The only variables the capture gets.
    static let captureKeys: Set<String> = ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG"]

    struct CaptureError: Error, CustomStringConvertible {
        let description: String
    }

    /// The PATH in a login shell's output, or `nil`. A profile may print banners first,
    /// so it is the last line. Relative and repeated entries are dropped.
    static func parse(_ output: String) -> String? {
        guard let last = output.split(whereSeparator: \.isNewline).last else { return nil }
        var seen = Set<String>()
        let entries = last.split(separator: ":").map(String.init).filter {
            $0.hasPrefix("/") && seen.insert($0).inserted
        }
        return entries.isEmpty ? nil : entries.joined(separator: ":")
    }

    /// Runs the login shell with a minimal environment and stdin from `/dev/null`.
    static func capture(
        base: [String: String],
        argv: [String] = argv,
        timeout: Duration = .seconds(5)
    ) async throws(CaptureError) -> String {
        let env = base.filter { captureKeys.contains($0.key) }
        let result = await Command.run(argv, env: env, timeout: timeout)
        if result.timedOut { throw CaptureError(description: "the login shell did not answer within \(timeout)") }
        guard result.status == 0, let path = parse(result.output) else {
            throw CaptureError(description: "the login shell printed no PATH (status \(result.status))")
        }
        return path
    }
}

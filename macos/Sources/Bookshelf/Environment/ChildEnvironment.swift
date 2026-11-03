import Darwin
import Foundation

/// Every child's environment is built, never inherited (M10, §5).
enum ChildEnvironment {
    /// Passed through from the app's own environment, with `LC_*`. Not `CLAUDECODE`, not
    /// `AI_AGENT`, not a terminal's variables.
    static let allowlist: Set<String> = ["PATH", "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG"]

    /// The allowlist from `base`, `path` as `PATH`, the account's values for whatever
    /// `base` lacks (an app opened with `env -i` has almost nothing), then `extra`.
    static func build(
        base: [String: String],
        path: String,
        account: [String: String] = Account.current(),
        extra: [String: String] = [:]
    ) -> [String: String] {
        var env = base.filter { allowlist.contains($0.key) || $0.key.hasPrefix("LC_") }
        env["PATH"] = path
        for (key, value) in account where env[key, default: ""].isEmpty {
            env[key] = value
        }
        env.merge(extra) { _, new in new }
        return env
    }

    /// The running user's HOME, USER, LOGNAME, SHELL and TMPDIR, from the user database, and
    /// a UTF-8 `LANG`.
    enum Account {
        static func current() -> [String: String] {
            var values = ["LANG": "en_US.UTF-8"]
            if let entry = getpwuid(getuid()) {
                let name = String(cString: entry.pointee.pw_name)
                values["HOME"] = String(cString: entry.pointee.pw_dir)
                values["USER"] = name
                values["LOGNAME"] = name
                values["SHELL"] = String(cString: entry.pointee.pw_shell)
            }
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
            if confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0 {
                values["TMPDIR"] = String(nulTerminated: buffer)
            }
            return values
        }
    }
}

extension String {
    /// A C string held in a `[CChar]` buffer, up to its first NUL.
    init(nulTerminated buffer: [CChar]) {
        self = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

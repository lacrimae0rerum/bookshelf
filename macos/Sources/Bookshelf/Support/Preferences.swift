import Foundation

/// App-shell settings in `UserDefaults` (§12). Settings has no window until P2; a key can be
/// set with `defaults write io.github.lacrimae0rerum.bookshelf <Key> …`, or for one launch
/// with `open -n Bookshelf.app --args -<Key> <value>` (the argument domain, never stored).
struct Preferences: @unchecked Sendable {
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Overrides the repo path the build script wrote into Info.plist.
    var repositoryPath: String? { nonEmpty(defaults.string(forKey: "RepositoryPath")) }
    /// Overrides the `claude` found on the PATH (the smoke test passes a fake one).
    var claudeBinary: String? { nonEmpty(defaults.string(forKey: "ClaudeBinary")) }
    var keepDatabaseRunning: Bool { bool("KeepDatabaseRunning", default: true) }
    var confirmQuitWhileJobsRun: Bool {
        get { bool("ConfirmQuitWhileJobsRun", default: true) }
        nonmutating set { defaults.set(newValue, forKey: "ConfirmQuitWhileJobsRun") }
    }
    var reopenLastPage: Bool { bool("ReopenLastPage", default: true) }
    var webInspectorEnabled: Bool { bool("WebInspectorEnabled", default: false) }

    /// Path and query of the last page shown, same origin only.
    var lastPage: String? {
        get { nonEmpty(defaults.string(forKey: "LastPage")) }
        nonmutating set { defaults.set(newValue, forKey: "LastPage") }
    }

    var pageZoom: Double {
        get { (defaults.object(forKey: "PageZoom") as? Double) ?? 1 }
        nonmutating set { defaults.set(newValue, forKey: "PageZoom") }
    }

    private func bool(_ key: String, default value: Bool) -> Bool {
        (defaults.object(forKey: key) as? Bool) ?? value
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

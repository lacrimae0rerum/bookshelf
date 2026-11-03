import Foundation

/// The app's own files, all outside the repo (docs/MACOS_APP.md §2).
struct AppPaths: Sendable {
    /// `~/Library/Application Support/Bookshelf`: `state.json` and `pids/`.
    let support: URL
    /// `~/Library/Logs/Bookshelf`: one log per service and `app.log`.
    let logs: URL

    static let standard = AppPaths(home: FileManager.default.homeDirectoryForCurrentUser)

    init(home: URL) {
        support = home.appending(path: "Library/Application Support/Bookshelf", directoryHint: .isDirectory)
        logs = home.appending(path: "Library/Logs/Bookshelf", directoryHint: .isDirectory)
    }

    var pids: URL { support.appending(path: "pids", directoryHint: .isDirectory) }
    var state: URL { support.appending(path: "state.json") }

    func log(_ name: LogName) -> URL { logs.appending(path: name.rawValue) }
    func pidFile(_ service: ServiceID) -> URL { pids.appending(path: "\(service.rawValue).pid") }

    func createDirectories() throws {
        for directory in [support, pids, logs] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}

/// The files in `~/Library/Logs/Bookshelf` (§16).
enum LogName: String, CaseIterable, Sendable {
    case app = "app.log"
    case api = "api.log"
    case web = "web.log"
    case webBuild = "web-build.log"
    case setup = "setup.log"
}

/// The Bookshelf checkout the app supervises (M1).
struct Repository: Sendable, Equatable {
    let root: URL

    var backend: URL { root.appending(path: "backend", directoryHint: .isDirectory) }
    var frontend: URL { root.appending(path: "frontend", directoryHint: .isDirectory) }
    var library: URL { root.appending(path: "library", directoryHint: .isDirectory) }
    var pgScript: URL { root.appending(path: "scripts/pg-local.sh") }
    var pgLog: URL { root.appending(path: ".pgdata/server.log") }
    var webEntry: URL { frontend.appending(path: "dist/server/entry.mjs") }
    var webEnvFile: URL { frontend.appending(path: ".env") }
    var readme: URL { root.appending(path: "README.md") }

    /// `nil` unless `path` holds `backend/`, `frontend/` and `scripts/pg-local.sh` (§12).
    static func at(_ path: String) -> Repository? {
        let repo = Repository(root: URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL)
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        for directory in [repo.backend, repo.frontend] {
            guard fm.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return nil
            }
        }
        return fm.fileExists(atPath: repo.pgScript.path) ? repo : nil
    }
}

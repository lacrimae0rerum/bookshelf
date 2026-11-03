import Foundation

/// The supervised services (§4).
enum ServiceID: String, CaseIterable, Sendable {
    case api, web
}

/// The fixed loopback addresses (M6): one address, `127.0.0.1`, everywhere.
enum Loopback {
    static let host = "127.0.0.1"
    static let databasePort: UInt16 = 54329
    static let apiPort: UInt16 = 8000
    static let webPort: UInt16 = 4321
    static let webOrigin = URL(string: "http://127.0.0.1:4321")!
    static let apiBase = "http://127.0.0.1:8000/api/v1"
    static let apiDocs = URL(string: "http://127.0.0.1:8000/docs")!
}

/// What it takes to run one service under a guard.
struct LaunchSpec: Sendable, Equatable {
    let id: ServiceID
    let argv: [String]
    let cwd: URL
    let log: LogName
    /// Set on top of the built environment (§4, §5).
    let extraEnv: [String: String]
    /// The service is ready when this answers 200.
    let readyURL: URL
    let port: UInt16
    let readyTimeout: Duration

    /// `uv run fastapi run app/main.py --host 127.0.0.1 --port 8000` in `backend/`.
    static func api(repo: Repository, tools: Tools) -> LaunchSpec {
        LaunchSpec(
            id: .api,
            argv: [tools.uv, "run", "fastapi", "run", "app/main.py", "--host", Loopback.host, "--port", "\(Loopback.apiPort)"],
            cwd: repo.backend,
            log: .api,
            extraEnv: [:],
            readyURL: URL(string: "http://127.0.0.1:\(Loopback.apiPort)/health/ready")!,
            port: Loopback.apiPort,
            readyTimeout: .seconds(60)
        )
    }

    /// `node --env-file=.env dist/server/entry.mjs` in `frontend/`, compiled (M5).
    static func web(repo: Repository, tools: Tools, hasEnvFile: Bool) -> LaunchSpec {
        LaunchSpec(
            id: .web,
            argv: [tools.node] + (hasEnvFile ? ["--env-file=.env"] : []) + ["dist/server/entry.mjs"],
            cwd: repo.frontend,
            log: .web,
            extraEnv: ["HOST": Loopback.host, "PORT": "\(Loopback.webPort)", "API_INTERNAL_URL": Loopback.apiBase],
            readyURL: Loopback.webOrigin,
            port: Loopback.webPort,
            readyTimeout: .seconds(30)
        )
    }
}

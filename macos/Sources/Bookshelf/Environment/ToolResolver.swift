import Foundation

/// Absolute paths of the tools the services need (§5).
struct Tools: Sendable, Equatable {
    let uv: String
    let node: String
    let pnpm: String
    /// `nil`: model jobs fail until it is installed; the services still start (§17).
    let claude: String?
}

struct MissingTool: Error, Equatable, CustomStringConvertible {
    let name: String
    let fix: String

    var description: String { "\(name) was not found on the login shell's PATH. Install it with `\(fix)`." }
}

enum ToolResolver {
    static let required: [(name: String, fix: String)] = [
        ("uv", "brew install uv"),
        ("node", "brew install node"),
        ("pnpm", "brew install pnpm"),
    ]

    /// The first executable `name` in `path`'s entries.
    static func which(_ name: String, path: String) -> String? {
        for directory in path.split(separator: ":") {
            let candidate = "\(directory)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// `claudeOverride` wins over the PATH when it is an executable file. `pnpm` is a Node
    /// script (`#!/usr/bin/env node`), so `node` must be on the same PATH (it is: same lookup).
    static func resolve(path: String, claudeOverride: String? = nil) throws(MissingTool) -> Tools {
        var found: [String: String] = [:]
        for tool in required {
            guard let location = which(tool.name, path: path) else { throw MissingTool(name: tool.name, fix: tool.fix) }
            found[tool.name] = location
        }
        let claude: String? = if let claudeOverride {
            FileManager.default.isExecutableFile(atPath: claudeOverride) ? claudeOverride : nil
        } else {
            which("claude", path: path)
        }
        return Tools(uv: found["uv"]!, node: found["node"]!, pnpm: found["pnpm"]!, claude: claude)
    }
}

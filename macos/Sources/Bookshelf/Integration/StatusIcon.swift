/// What the menu bar icon shows (§10): the state by the symbol's shape, never by colour, and
/// the same state in words for the tooltip and VoiceOver. No AppKit here; `StatusItem`
/// draws it.
enum StatusIcon: Equatable, Sendable {
    case starting
    case stopping
    /// `Supervisor.Phase.idle`: before the first start, and the last moment of a quit.
    case notRunning
    case ready
    case running(Int)
    case paused
    case failed

    /// Failed, then starting or stopping, then a paused queue, then running jobs, then ready.
    /// The queue counts only while the services are ready; `nil` is a queue not read yet.
    init(phase: Supervisor.Phase, queue: QueueSummary?) {
        switch phase {
        case .failed: self = .failed
        case .starting: self = .starting
        case .stopping: self = .stopping
        case .idle: self = .notRunning
        case .ready:
            if queue?.paused == true {
                self = .paused
            } else if let running = queue?.running, running > 0 {
                self = .running(running)
            } else {
                self = .ready
            }
        }
    }

    /// An SF Symbol, drawn as a template image.
    var symbolName: String {
        switch self {
        case .starting, .stopping, .notRunning: "hourglass"
        case .ready: "books.vertical"
        case .running: "books.vertical.fill"
        case .paused: "pause.circle"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    /// "Bookshelf — ready, 2 jobs running".
    var words: String {
        "Bookshelf — " + state
    }

    private var state: String {
        switch self {
        case .starting: "starting…"
        case .stopping: "stopping…"
        case .notRunning: "not running"
        case .ready: "ready"
        case .running(let count): "ready, \(count) \(count == 1 ? "job" : "jobs") running"
        case .paused: "job queue paused"
        case .failed: "a service failed"
        }
    }
}

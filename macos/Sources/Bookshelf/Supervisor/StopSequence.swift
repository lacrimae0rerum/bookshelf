import Darwin

/// The signal a stop needed last (M9).
enum StopStep: String, Sendable, Equatable {
    case term = "SIGTERM"
    case interrupt = "SIGINT"
    case kill = "SIGKILL"
}

struct StopTimings: Sendable, Equatable {
    /// SIGTERM → SIGINT. The API hands its jobs back and kills their runs at once, then
    /// uvicorn waits for open requests; a `/search/answer` can take minutes.
    var term: Duration = .seconds(5)
    /// SIGINT → SIGKILL. uvicorn's forced exit, on which the API kills the requests' runs.
    var interrupt: Duration = .seconds(1)

    static let standard = StopTimings()
}

enum StopSequence {
    /// SIGTERM to `child` only; after `timings.term`, SIGINT to `child`; after
    /// `timings.interrupt` more, `killGroup()` (SIGKILL to the group; the guard spares
    /// itself). `waitExit(timeout)` returns `true` once the child has exited and been
    /// reaped. The API's `claude` runs live in sessions of their own, so the group's SIGKILL
    /// never reaches them: the API must end them itself, which is why the group goes last.
    static func run(
        child: pid_t,
        group: pid_t,
        timings: StopTimings = .standard,
        waitExit: (Duration) -> Bool,
        killGroup: (() -> Void)? = nil,
        log: (String) -> Void
    ) -> StopStep {
        log("SIGTERM to \(child)")
        kill(child, SIGTERM)
        if waitExit(timings.term) { return .term }
        log("\(child) still running after \(timings.term): SIGINT")
        kill(child, SIGINT)
        if waitExit(timings.interrupt) { return .interrupt }
        log("\(child) still running after \(timings.interrupt) more: SIGKILL to group \(group)")
        if let killGroup { killGroup() } else { killpg(group, SIGKILL) }
        return .kill
    }
}

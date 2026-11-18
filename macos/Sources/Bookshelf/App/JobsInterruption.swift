import AppKit

/// What stops the API, and with it the jobs it runs: a quit (§3) or a restart from the Server
/// or menu bar menu. Either one asks first while jobs run.
enum JobsInterruption: Sendable {
    case quit
    case restart

    /// Ask only while the services are ready and at least one job runs.
    static func mustAsk(phase: Supervisor.Phase, queue: QueueSummary?) -> Bool {
        phase == .ready && (queue?.running ?? 0) > 0
    }

    /// "1 job is running. Quit anyway?", "3 jobs are running. Restart anyway?".
    func question(running: Int) -> String {
        let jobs = running == 1 ? "1 job is running." : "\(running) jobs are running."
        return "\(jobs) \(button) anyway?"
    }

    var button: String {
        switch self {
        case .quit: "Quit"
        case .restart: "Restart"
        }
    }

    /// Only the quit question has "Don't ask again" (the Confirm Quit preference).
    var offersSuppression: Bool { self == .quit }
}

extension AppDelegate {
    /// Restarts: true when no job runs, or the person chose Restart.
    func confirmRestart() async -> Bool {
        guard supervisor.phase == .ready else { return true }  // nothing to read the queue from
        let queue = await JobsAPI.queue(timeout: 1)
        guard JobsInterruption.mustAsk(phase: supervisor.phase, queue: queue), let queue else { return true }
        return await confirm(.restart, running: queue.running)
    }

    /// A sheet on the main window, in front of every app: the action may come from the menu
    /// bar icon while another app is active, and a sheet behind it would hold the action unseen.
    func confirm(_ interruption: JobsInterruption, running: Int) async -> Bool {
        let alert = NSAlert()
        alert.messageText = interruption.question(running: running)
        alert.informativeText = "They go back to the queue and run again next time."
        alert.addButton(withTitle: interruption.button)
        alert.addButton(withTitle: "Cancel")
        if interruption.offersSuppression {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Don't ask again"
        }
        guard let window = frontMainWindow(activating: true) else { return true }
        let go = await alert.beginSheetModal(for: window) == .alertFirstButtonReturn  // a sheet, never runModal
        if go, interruption == .quit, alert.suppressionButton?.state == .on { preferences.confirmQuitWhileJobsRun = false }
        return go
    }
}

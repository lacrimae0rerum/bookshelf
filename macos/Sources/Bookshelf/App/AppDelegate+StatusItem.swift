import AppKit

/// The menu bar icon's state and actions (§10). The icon and its menu are in
/// `Integration/StatusItem.swift`; the queue's poll in `Integration/QueuePoll.swift`.
extension AppDelegate {
    var statusIcon: StatusIcon {
        StatusIcon(phase: supervisor.phase, queue: lastQueue)
    }

    func refreshStatusIcon() {
        statusItem?.show(statusIcon)
    }

    /// The icon's poll; what it reads goes into `lastQueue`. Tests pass a fake phase, queue
    /// and clock.
    func makeQueuePoll(
        phase: @escaping () -> Supervisor.Phase,
        read: @escaping @MainActor () async -> QueueSummary? = QueuePoll.readQueue,
        sleep: @escaping @MainActor (Duration) async throws -> Void = QueuePoll.wait
    ) -> QueuePoll {
        QueuePoll(phase: phase, read: read, deliver: { [unowned self] in lastQueue = $0 }, sleep: sleep)
    }

    /// On every supervisor change. Out of `.ready`, the queue read for the services that ran
    /// is forgotten, so the next `.ready` shows the books until the poll reads it again.
    func syncStatusItem() {
        if supervisor.phase != .ready { lastQueue = nil }
        queuePoll.sync()
        refreshStatusIcon()
    }

    /// The window, in front of every app: the icon's menu is often used from another one.
    @objc func openBookshelf(_ sender: Any?) {
        frontMainWindow(activating: true)
    }
}

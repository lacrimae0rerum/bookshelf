import AppKit

/// `--smoke` and `--smoke-report <file>` (§20). The report gets one `event=seconds` line per
/// milestone (`ready`, `shown`, `quit`, `stopped`, `failed`), in seconds since launch;
/// `macos/scripts/smoke.sh` polls it. `--smoke` also quits with ⌘Q once the page is shown.
@MainActor
final class SmokeReport {
    let quitWhenShown: Bool
    private let file: URL?
    private let launched: ContinuousClock.Instant

    init(arguments: [String], launched: ContinuousClock.Instant) {
        quitWhenShown = arguments.contains("--smoke")
        file = arguments.firstIndex(of: "--smoke-report")
            .flatMap { arguments.indices.contains($0 + 1) ? URL(fileURLWithPath: arguments[$0 + 1]) : nil }
        self.launched = launched
    }

    func record(_ event: String) {
        guard let file else { return }
        let elapsed = launched.duration(to: .now).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        let line = "\(event)=\(String(format: "%.3f", seconds))\n"
        LogFiles.appendHandle(file)?.write(Data(line.utf8))
        Log.info("smoke: \(line.dropLast())")
    }
}

/// ⌘Q, sent through the menu's key equivalents as the keyboard would send it.
@MainActor
enum QuitKey {
    static func press() -> Bool {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
            characters: "q", charactersIgnoringModifiers: "q", isARepeat: false, keyCode: 12
        ) else { return false }
        return NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false
    }
}

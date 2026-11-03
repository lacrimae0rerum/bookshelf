import AppKit

// One binary, two modes (§19): the guard, or the app.
let launched = ContinuousClock.now
let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == Guard.flag {
    Guard.main(arguments)
}

let delegate = AppDelegate(smoke: SmokeReport(arguments: arguments, launched: launched))
let application = NSApplication.shared
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()

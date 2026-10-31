import AppKit

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "--snapshot", arguments.count > 1 {
    MainActor.assumeIsolated { Snapshot.run(to: arguments[1]) }
    exit(0)
}
if let first = arguments.first, first.hasPrefix("--") {
    Task { exit(await CLI.run(arguments)) }
    dispatchMain()
}

// Keep the app's run loop out of any async context so main-actor tasks (model loading) can run.
let app = NSApplication.shared
let controller = MainActor.assumeIsolated { AppController() }
app.delegate = controller
app.setActivationPolicy(.accessory)   // menu-bar app: no Dock icon
app.run()

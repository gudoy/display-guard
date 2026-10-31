// main.swift — one binary, two roles:
//   DisplayGuard                       the menu bar app (also installs everything)
//   DisplayGuard --reconcile [--force] one reconcile pass, run every 15s by a LaunchAgent

import AppKit

let arguments = CommandLine.arguments
if arguments.contains("--reconcile") {
    exit(Reconciler.pass(force: arguments.contains("--force")))
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

// Entry point. Swift runs the top-level code in main.swift when the app starts.
import AppKit

// UI code must run on the main thread ("main actor"); startup already does,
// this line just tells the compiler so.
MainActor.assumeIsolated {
    // Developer shortcuts (e.g. `DropWheel --convert jpg photo.png`), handy for
    // testing conversions from Terminal without dragging anything.
    if DevCommands.handle(CommandLine.arguments) {
        exit(0)
    }

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory) // menu bar app: no Dock icon
    app.run()                           // hands control to macOS' event loop, never returns
}

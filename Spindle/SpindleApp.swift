//
//  SpindleApp.swift
//  Spindle
//
//  Created by Rein Blank on 19/11/2026.
//

import SwiftUI

@main
struct SpindleApp: App {
    init() {
        // SPINDLE_REPLAY=<capture.wav>: replay a captured deck input offline
        // and quit, with no window or audio device.
        let env = ProcessInfo.processInfo.environment
        if let path = env["SPINDLE_REPLAY"] {
            let vinyl = TimecodeDefinition.named(env["SPINDLE_REPLAY_VINYL"]) ?? .traktorMK2
            let loads = (env["SPINDLE_REPLAY_LOADS"] ?? "0").split(separator: ",").compactMap { Double($0) }
            let out = env["SPINDLE_REPLAY_OUT"] ?? path + ".csv"
            print(DeckEngine.replay(path: path, out: out, vinyl: vinyl, absolute: env["SPINDLE_REPLAY_REL"] == nil, loads: loads))
            exit(0)
        }
        if env["SPINDLE_SELFTEST"] != nil {
            print(DeckEngine.scrubTest()); print(DeckEngine.loopTest()); print(DeckEngine.needleTest())
            exit(0)
        }
    }

    /// The one app model. Created here, once: a view's @State initial value
    /// is evaluated every time the view is re-created, which built extra
    /// copies of every store (each reading the data files).
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
        .commands {
            CommandGroup(after: .appSettings) { ShortcutsMenuItem() }
        }
        Window(Shortcuts.windowTitle, id: "shortcuts") {
            ShortcutsView()
        }
        .defaultSize(width: 500, height: 640)
    }
}

/// Spindle ▸ Keyboard Shortcuts… (⌘/).
private struct ShortcutsMenuItem: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Keyboard Shortcuts…") { openWindow(id: "shortcuts") }
            .keyboardShortcut("/", modifiers: .command)
    }
}

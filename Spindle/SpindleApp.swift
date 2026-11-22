//
//  SpindleApp.swift
//  Spindle
//
//  Created by Rein Blank on 19/11/2026.
//

import SwiftUI

@main
struct SpindleApp: App {
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

//
//  Shortcuts.swift
//  Spindle
//
//  Every keyboard shortcut in one place, so the Keyboard shortcuts window
//  can show and change them. Each page's key handler asks
//  `Shortcuts.shared.matches(.action, event)` instead of checking key codes.
//  Changes are kept in UserDefaults ("shortcuts").
//

import AppKit
import Observation

/// A key plus modifiers, e.g. ⇧←.
nonisolated struct KeyCombo: Codable, Equatable, Hashable, Sendable {
    var keyCode: UInt16
    var shift = false, control = false, option = false, command = false
    /// What the key itself shows (stored when recorded).
    var label: String

    init(_ keyCode: UInt16, _ label: String, shift: Bool = false, control: Bool = false,
         option: Bool = false, command: Bool = false) {
        self.keyCode = keyCode; self.label = label
        self.shift = shift; self.control = control; self.option = option; self.command = command
    }

    init(event: NSEvent) {
        let f = event.modifierFlags
        self.init(event.keyCode, Self.name(for: event),
                  shift: f.contains(.shift), control: f.contains(.control),
                  option: f.contains(.option), command: f.contains(.command))
    }

    func matches(_ event: NSEvent) -> Bool {
        let f = event.modifierFlags
        return event.keyCode == keyCode && f.contains(.shift) == shift && f.contains(.control) == control
            && f.contains(.option) == option && f.contains(.command) == command
    }

    var display: String {
        (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "") + label
    }

    static let special: [UInt16: String] = [
        49: "Space", 36: "Return", 76: "Enter", 48: "Tab", 53: "Esc", 51: "⌫", 117: "⌦",
        123: "←", 124: "→", 125: "↓", 126: "↑", 116: "Page ↑", 121: "Page ↓", 115: "Home", 119: "End",
    ]

    static func name(for event: NSEvent) -> String {
        if let s = special[event.keyCode] { return s }
        let c = event.charactersIgnoringModifiers ?? ""
        return c.isEmpty ? "Key \(event.keyCode)" : c.uppercased()
    }
}

enum ShortcutAction: String, CaseIterable, Identifiable {
    // Everywhere
    case nextPage, previousPage, colorMenu, setMenu
    // Organize
    case organizeLibrary, organizeTracks, organizeUp, organizeDown, organizePlay,
         organizeBack, organizeForward, organizeRename
    // Mark
    case markPlay, markBarBack, markBarForward, markBeatBack, markBeatForward,
         markPreviousTrack, markNextTrack, markZoomOut, markZoomIn, markNudgeEarlier, markNudgeLater,
         markDownbeat, markClick, markMarked, markNewCue, markNewLoop
    // Mix
    case mixUp, mixDown, mixListen, mixBack, mixForward, mixLoadA, mixLoadB

    var id: String { rawValue }

    enum Section: String, CaseIterable { case everywhere = "Everywhere", organize = "Organize", mark = "Mark", mix = "Mix" }

    var section: Section {
        switch self {
        case .nextPage, .previousPage, .colorMenu, .setMenu: .everywhere
        case .organizeLibrary, .organizeTracks, .organizeUp, .organizeDown, .organizePlay,
             .organizeBack, .organizeForward, .organizeRename: .organize
        case .mixUp, .mixDown, .mixListen, .mixBack, .mixForward, .mixLoadA, .mixLoadB: .mix
        default: .mark
        }
    }

    var title: String {
        switch self {
        case .nextPage: "Next page"
        case .previousPage: "Previous page"
        case .colorMenu: "Colour the selected tracks"
        case .setMenu: "Put the selected tracks in a set"
        case .organizeLibrary: "Keys work in the library"
        case .organizeTracks: "Keys work in the track list"
        case .organizeUp: "Previous track / list"
        case .organizeDown: "Next track / list"
        case .organizePlay: "Pre-listen play / stop"
        case .organizeBack: "Back 10 s (library: close folder)"
        case .organizeForward: "Forward 10 s (library: open folder)"
        case .organizeRename: "Rename (library)"
        case .markPlay: "Play / stop"
        case .markBarBack: "Back one bar"
        case .markBarForward: "Forward one bar"
        case .markBeatBack: "Back one beat"
        case .markBeatForward: "Forward one beat"
        case .markPreviousTrack: "Previous track"
        case .markNextTrack: "Next track"
        case .markZoomOut: "Zoom out"
        case .markZoomIn: "Zoom in"
        case .markNudgeEarlier: "Nudge grid earlier"
        case .markNudgeLater: "Nudge grid later"
        case .markDownbeat: "Bar 1 here"
        case .markClick: "Click on / off"
        case .markMarked: "Marked on / off"
        case .markNewCue: "New cue"
        case .markNewLoop: "New loop slot"
        case .mixUp: "Previous track"
        case .mixDown: "Next track"
        case .mixListen: "Pre-listen play / stop (over a deck: that deck)"
        case .mixBack: "Pre-listen back 10 s"
        case .mixForward: "Pre-listen forward 10 s"
        case .mixLoadA: "Load on deck A"
        case .mixLoadB: "Load on deck B"
        }
    }

    var defaultCombo: KeyCombo {
        switch self {
        case .nextPage: KeyCombo(48, "Tab")
        case .previousPage: KeyCombo(48, "Tab", shift: true)
        case .colorMenu: KeyCombo(8, "C", shift: true)
        case .setMenu: KeyCombo(1, "S", shift: true)
        case .organizeLibrary: KeyCombo(18, "1")
        case .organizeTracks: KeyCombo(19, "2")
        case .organizeUp, .mixUp: KeyCombo(126, "↑")
        case .organizeDown, .mixDown: KeyCombo(125, "↓")
        case .organizePlay, .markPlay, .mixListen: KeyCombo(49, "Space")
        case .organizeBack, .markBarBack, .mixBack: KeyCombo(123, "←")
        case .organizeForward, .markBarForward, .mixForward: KeyCombo(124, "→")
        case .organizeRename: KeyCombo(36, "Return")
        case .markBeatBack: KeyCombo(123, "←", shift: true)
        case .markBeatForward: KeyCombo(124, "→", shift: true)
        case .markPreviousTrack: KeyCombo(126, "↑")
        case .markNextTrack: KeyCombo(125, "↓")
        case .markZoomOut: KeyCombo(27, "−")
        case .markZoomIn: KeyCombo(24, "=")
        case .markNudgeEarlier: KeyCombo(33, "[")
        case .markNudgeLater: KeyCombo(30, "]")
        case .markDownbeat: KeyCombo(2, "D")
        case .markClick: KeyCombo(8, "C")
        case .markMarked: KeyCombo(46, "M")
        case .markNewCue: KeyCombo(12, "Q")
        case .markNewLoop: KeyCombo(37, "L")
        case .mixLoadA: KeyCombo(6, "Z")
        case .mixLoadB: KeyCombo(46, "M")
        }
    }
}

@Observable
final class Shortcuts {
    static let shared = Shortcuts()

    private(set) var custom: [String: KeyCombo] = [:]
    /// The shortcuts window is waiting for a new key.
    @ObservationIgnored var recording = false
    static let windowTitle = "Keyboard Shortcuts"

    /// Keys for the pages: not while a new key is being recorded, and not
    /// from the shortcuts window itself.
    func forPages(_ event: NSEvent) -> Bool {
        !recording && !QuickPick.shared.isOpen && event.window?.title != Self.windowTitle
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: "shortcuts"),
           let saved = try? JSONDecoder().decode([String: KeyCombo].self, from: data) {
            custom = saved
        }
    }

    func combo(_ action: ShortcutAction) -> KeyCombo { custom[action.rawValue] ?? action.defaultCombo }

    func matches(_ action: ShortcutAction, _ event: NSEvent) -> Bool { combo(action).matches(event) }

    /// Another action on the same page (or Everywhere) that already uses `combo`.
    func conflict(for action: ShortcutAction, _ combo: KeyCombo) -> ShortcutAction? {
        ShortcutAction.allCases.first { other in
            other != action && self.combo(other) == combo
                && (other.section == action.section || other.section == .everywhere || action.section == .everywhere)
        }
    }

    /// Sets a key; one that clashes on the same page swaps to this action's old key.
    func set(_ action: ShortcutAction, _ new: KeyCombo) {
        if let other = conflict(for: action, new) { store(other, combo(action)) }
        store(action, new)
    }

    func reset(_ action: ShortcutAction) { custom[action.rawValue] = nil; save() }
    func resetAll() { custom = [:]; save() }

    private func store(_ action: ShortcutAction, _ combo: KeyCombo) {
        custom[action.rawValue] = combo == action.defaultCombo ? nil : combo
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(custom) { UserDefaults.standard.set(data, forKey: "shortcuts") }
    }
}

//
//  ShortcutsView.swift
//  Spindle
//
//  The Keyboard shortcuts window: every shortcut by page. Click a key and
//  press a new one (with ⇧ ⌃ ⌥ ⌘ if you like); Esc cancels. A key already
//  used on the same page swaps over.
//

import AppKit
import SwiftUI

struct ShortcutsView: View {
    @State private var keys = Shortcuts.shared
    @State private var recording: ShortcutAction?
    @State private var monitor: Any?
    @State private var note: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.space4) {
                    ForEach(ShortcutAction.Section.allCases, id: \.self) { section in
                        VStack(alignment: .leading, spacing: 0) {
                            LabelText(section.rawValue).padding(.bottom, Theme.space2)
                            ForEach(ShortcutAction.allCases.filter { $0.section == section }) { action in
                                row(action)
                            }
                            if section == .mark {
                                fixedRow("Jump to cue 1–9", "1 … 9")
                                fixedRow("Set cue 1–9", "⇧1 … ⇧9")
                            }
                        }
                    }
                }
                .padding(Theme.space4)
            }
            Rectangle().fill(Theme.line).frame(height: 1)
            HStack {
                Text(note ?? "Click a key to change it. Esc cancels.")
                    .font(Theme.caption).foregroundStyle(Theme.inkMuted)
                Spacer()
                Button("Reset all") { keys.resetAll(); note = "All shortcuts are back to their defaults." }
                    .buttonStyle(FlatButtonStyle())
                    .disabled(keys.custom.isEmpty)
            }
            .padding(Theme.space3)
            .background(Theme.panelRaised)
        }
        .frame(minWidth: 460, idealWidth: 500, minHeight: 420, idealHeight: 640)
        .background(Theme.panel)
        .onDisappear { stopRecording() }
    }

    private func row(_ action: ShortcutAction) -> some View {
        let isRecording = recording == action
        let changed = keys.custom[action.rawValue] != nil
        return HStack(spacing: Theme.space2) {
            Text(action.title).font(Theme.body).foregroundStyle(Theme.ink)
            Spacer()
            if changed {
                Button { keys.reset(action); note = "\(action.title): back to \(action.defaultCombo.display)." } label: {
                    Image(systemName: "arrow.uturn.backward").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.inkMuted)
                .help("Back to \(action.defaultCombo.display)")
            }
            Button { isRecording ? stopRecording() : startRecording(action) } label: {
                Text(isRecording ? "Press a key…" : keys.combo(action).display)
                    .font(Theme.readoutSm)
                    .foregroundStyle(isRecording ? Theme.onAccent : Theme.ink)
                    .frame(minWidth: 90)
                    .padding(.vertical, 3).padding(.horizontal, Theme.space2)
                    .background(isRecording ? Theme.accent : Theme.control)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSm))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line.opacity(0.5)).frame(height: 1) }
    }

    private func fixedRow(_ title: String, _ key: String) -> some View {
        HStack {
            Text(title).font(Theme.body).foregroundStyle(Theme.inkMuted)
            Spacer()
            Text(key).font(Theme.readoutSm).foregroundStyle(Theme.inkFaint)
                .frame(minWidth: 90).padding(.vertical, 3).padding(.horizontal, Theme.space2)
        }
        .padding(.vertical, 4)
        .help("Fixed")
    }

    private func startRecording(_ action: ShortcutAction) {
        stopRecording()
        recording = action
        keys.recording = true
        note = "Press the new key for “\(action.title)”. Esc cancels."
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let action = recording else { return event }
            if event.keyCode == 53 {                       // Esc
                note = nil
            } else {
                let combo = KeyCombo(event: event)
                let clash = keys.conflict(for: action, combo)
                keys.set(action, combo)
                note = clash.map { "\(combo.display) was “\($0.title)”; that one now uses \(keys.combo($0).display)." }
                    ?? "\(action.title): \(combo.display)."
            }
            stopRecording(keepNote: true)
            return nil
        }
    }

    private func stopRecording(keepNote: Bool = false) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
        keys.recording = false
        if !keepNote { note = nil }
    }
}

//
//  SessionsView.swift
//  Spindle
//
//  Build step 5: Sessions. Record the mix, see the auto-logged tracklist
//  with timestamps, export the recording and the tracklist.
//

import SwiftUI

struct SessionsView: View {
    let model: AppModel
    @Bindable var store: SessionStore

    var body: some View {
        HStack(spacing: 1) {
            VStack(spacing: 0) {
                recorder
                Rectangle().fill(Theme.line).frame(height: 1)
                list
            }
            .frame(width: 340)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.line)
        .onAppear { store.reload() }
    }

    private var recorder: some View {
        VStack(alignment: .leading, spacing: Theme.space2) {
            HStack(spacing: Theme.space3) {
                RecordButton(model: model)
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.recording ? SessionStore.clock(store.elapsed) : "Not recording")
                        .font(store.recording ? Theme.readout : Theme.body)
                        .foregroundStyle(store.recording ? Theme.ink : Theme.inkMuted)
                    Text(store.current?.source ?? sourceDescription)
                        .font(Theme.caption).foregroundStyle(Theme.inkFaint).lineLimit(1)
                }
                Spacer()
            }
            SignalMeter(level: store.level).frame(height: 4)
            if let error = store.error {
                Text(error).font(Theme.caption).foregroundStyle(Theme.warn)
            }
            if let engine = model.engine, engine.hasInputs {
                Picker("Record from", selection: Binding(
                    get: { engine.recordInput },
                    set: { engine.recordInput = $0 })) {
                    Text("Spindle output (both decks)").tag(-1)
                    ForEach(Array(stride(from: 0, to: engine.device.inputChannels - 1, by: 2)), id: \.self) { ch in
                        Text("Mixer input \(ch + 1)–\(ch + 2)\(ch == 0 ? " (Xone master send)" : "")").tag(ch)
                    }
                }
                .disabled(store.recording)
                .font(Theme.caption)
            }
        }
        .padding(Theme.space3)
        .background(Theme.panelRaised)
    }

    private var sourceDescription: String {
        guard let engine = model.engine else { return "Start the audio engine to record" }
        return engine.recordInput >= 0 ? "Will record mixer input \(engine.recordInput + 1)–\(engine.recordInput + 2)" : "Will record Spindle's output"
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if let live = store.current {
                    row(live, live: true)
                }
                ForEach(store.sessions) { session in
                    row(session, live: false)
                    Rectangle().fill(Theme.line).frame(height: 1)
                }
                if store.sessions.isEmpty && store.current == nil {
                    Text("No sessions yet. Press record while you mix.")
                        .font(Theme.caption).foregroundStyle(Theme.inkFaint).padding(Theme.space4)
                }
            }
        }
        .background(Theme.panel)
    }

    private func row(_ session: SessionInfo, live: Bool) -> some View {
        let selected = store.selected == session.id || (live && store.selected == nil)
        return Button {
            store.selected = session.id
        } label: {
            HStack {
                if live { Circle().fill(Theme.warn).frame(width: 7, height: 7) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.started.formatted(date: .abbreviated, time: .shortened))
                        .font(Theme.body).foregroundStyle(selected ? Theme.ink : Theme.inkMuted)
                    Text("\(SessionStore.clock(live ? store.elapsed : session.duration)) · \(session.entries.count) tracks")
                        .font(Theme.readoutSm).foregroundStyle(Theme.inkFaint)
                }
                Spacer()
            }
            .padding(.horizontal, Theme.space3)
            .padding(.vertical, Theme.space2)
            .background(selected ? Theme.accentSoft : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var shown: SessionInfo? {
        if let current = store.current, store.selected == nil || store.selected == current.id { return current }
        return store.sessions.first { $0.id == store.selected } ?? (store.current == nil ? store.sessions.first : nil)
    }

    @ViewBuilder
    private var detail: some View {
        if let session = shown {
            let live = session.id == store.current?.id
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: Theme.space2) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.started.formatted(date: .complete, time: .shortened)).font(Theme.title).foregroundStyle(Theme.ink)
                        Text("\(SessionStore.clock(live ? store.elapsed : session.duration)) · \(session.source)\(session.droppedFrames > 0 ? " · \(session.droppedFrames) frames dropped" : "")")
                            .font(Theme.caption).foregroundStyle(Theme.inkMuted)
                    }
                    Spacer()
                    if !live {
                        Button("Export WAV…") { store.export(session, as: .wav) }
                        Button("Export MP3…") { store.export(session, as: .mp3) }
                        Button("Export AAC…") { store.export(session, as: .aac) }
                        Button("Copy tracklist") { store.copyTracklist(session) }
                        Button("Save tracklist…") { store.saveTracklist(session) }
                        Button("Show in Finder") { store.reveal(session) }
                    }
                }
                .buttonStyle(FlatButtonStyle())
                .padding(Theme.space3)
                .background(Theme.panelRaised)
                Rectangle().fill(Theme.line).frame(height: 1)
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(session.entries.enumerated()), id: \.element.id) { index, entry in
                            HStack(spacing: Theme.space3) {
                                Text("\(index + 1)").font(Theme.readoutSm).foregroundStyle(Theme.inkFaint).frame(width: 24, alignment: .trailing)
                                Text(SessionStore.clock(entry.time)).font(Theme.readout).foregroundStyle(Theme.ink).frame(width: 80, alignment: .leading)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(entry.title).font(Theme.body).foregroundStyle(Theme.ink).lineLimit(1)
                                    if !entry.artist.isEmpty { Text(entry.artist).font(Theme.caption).foregroundStyle(Theme.inkMuted) }
                                }
                                Spacer()
                                Text(entry.bpm.map { String(format: "%.0f", $0) } ?? "").font(Theme.readoutSm).foregroundStyle(Theme.inkMuted)
                                Text(entry.key ?? "").font(Theme.readoutSm).foregroundStyle(Theme.inkMuted).frame(width: 28)
                                Text(entry.deck).font(Theme.label).foregroundStyle(entry.deck == "A" ? Theme.deckA : Theme.deckB)
                            }
                            .padding(.horizontal, Theme.space3)
                            .padding(.vertical, Theme.space2)
                            Rectangle().fill(Theme.line).frame(height: 1)
                        }
                        if session.entries.isEmpty {
                            Text(live ? "Tracks appear here once a deck has played them for 20 seconds." : "No tracks were logged.")
                                .font(Theme.caption).foregroundStyle(Theme.inkFaint).padding(Theme.space4)
                        }
                    }
                }
            }
            .background(Theme.panel)
        } else {
            Text("Record a session to see its tracklist here.")
                .font(Theme.caption).foregroundStyle(Theme.inkFaint)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.panel)
        }
    }
}

/// Round record button, shared by the top bar and the Sessions page.
struct RecordButton: View {
    let model: AppModel
    var body: some View {
        let recording = model.sessions.recording
        Button {
            model.toggleRecording()
        } label: {
            HStack(spacing: Theme.space1) {
                Circle().fill(Theme.warn).frame(width: 9, height: 9)
                    .opacity(recording ? 1 : 0.8)
                Text(recording ? "Stop recording" : "Record")
                    .font(Theme.body)
            }
            .padding(.horizontal, Theme.space3)
            .padding(.vertical, 5)
            .foregroundStyle(Theme.ink)
            .background(recording ? Theme.warn.opacity(0.3) : Theme.control)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMd))
        }
        .buttonStyle(.plain)
        .disabled(model.engine == nil)
        .help(model.engine == nil ? "Start the audio engine first" : "Record the mix with an automatic tracklist")
    }
}

/// MIDI learn: one row per action, press Learn then a pad or knob.
struct MIDIMappingView: View {
    @Bindable var midi: MIDIController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("MIDI mapping").font(Theme.title).foregroundStyle(Theme.ink)
                Spacer()
                Text(midi.sources.isEmpty ? "No MIDI devices found" : midi.sources.joined(separator: ", "))
                    .font(Theme.caption).foregroundStyle(Theme.inkMuted)
                Button("Done") { midi.learning = nil; dismiss() }.buttonStyle(FlatButtonStyle(primary: true))
            }
            .padding(Theme.space3)
            .background(Theme.panelRaised)
            Text(midi.learning.map { "Press a pad or turn a knob for \($0.label)…" }
                 ?? "Click Learn, then press a pad or turn a knob. Knobs pick up a value once they reach it (soft takeover).")
                .font(Theme.caption)
                .foregroundStyle(midi.learning == nil ? Theme.inkMuted : Theme.accent)
                .padding(.horizontal, Theme.space3).padding(.vertical, Theme.space2)
            Rectangle().fill(Theme.line).frame(height: 1)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(MIDITarget.all) { target in
                        HStack {
                            Text(target.label).font(Theme.body).foregroundStyle(Theme.ink)
                            Spacer()
                            if let pickup = midi.pickup[target] {
                                Text(String(format: "knob at %.0f%% — turn to pick up", (target.action == .filter ? (pickup + 1) / 2 : pickup) * 100))
                                    .font(Theme.caption).foregroundStyle(Theme.inkFaint)
                            }
                            Text(midi.bindings[target]?.label ?? "—").font(Theme.readoutSm)
                                .foregroundStyle(midi.bindings[target] == nil ? Theme.inkFaint : Theme.ink)
                                .frame(width: 120, alignment: .trailing)
                            Button(midi.learning == target ? "Listening…" : "Learn") {
                                midi.learning = midi.learning == target ? nil : target
                            }
                            .buttonStyle(FlatButtonStyle(primary: midi.learning == target))
                            Button("Clear") { midi.clear(target) }
                                .buttonStyle(FlatButtonStyle())
                                .disabled(midi.bindings[target] == nil)
                        }
                        .padding(.horizontal, Theme.space3).padding(.vertical, 5)
                        Rectangle().fill(Theme.line).frame(height: 1)
                    }
                }
            }
            Text("Last message: \(midi.lastMessage.isEmpty ? "none" : midi.lastMessage)")
                .font(Theme.readoutSm).foregroundStyle(Theme.inkFaint)
                .padding(Theme.space3)
        }
        .frame(width: 620, height: 600)
        .background(Theme.panel)
        .preferredColorScheme(.dark)
    }
}

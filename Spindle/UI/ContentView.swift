//
//  ContentView.swift
//  Spindle
//
//  The window: device bar on top, the current page, and the page bar at the
//  bottom like DaVinci Resolve (Organize, Prep, Mix, Sessions).
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import OSLog

struct ContentView: View {
    @State private var model = AppModel()

    var body: some View {
        VStack(spacing: 0) {
            TopBar(model: model)
            Rectangle().fill(Theme.line).frame(height: 1)
            if let error = model.error {
                Text(error)
                    .font(Theme.body)
                    .foregroundStyle(Theme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.space2)
                    .background(Theme.warn.opacity(0.25))
            }
            switch model.page {
            case .organize:
                OrganizeView(library: model.library, analysis: model.analysis, model: model)
                    .frame(maxHeight: .infinity)
            case .prep:
                PrepView(library: model.library, model: model, page: model.prepPage)
                    .frame(maxHeight: .infinity)
            case .mix:
                MixView(model: model, library: model.library)
                    .frame(maxHeight: .infinity)
            case .sessions:
                SessionsView(model: model, store: model.sessions)
                    .frame(maxHeight: .infinity)
            }
            Rectangle().fill(Theme.line).frame(height: 1)
            PageBar(page: $model.page)
        }
        .background(Theme.bg)
        .preferredColorScheme(.dark)
        .frame(minWidth: 1180, minHeight: 820)
        .sheet(isPresented: $model.showingMIDI) { MIDIMappingView(midi: model.midi) }
        .task { await model.start() }
        .task { await model.refreshLibrary() }
        .task { await snapshotIfRequested() }
        .fileImporter(
            isPresented: $model.showingImporter,
            allowedContentTypes: [.audio]
        ) { result in
            spindleLog.notice("Picker returned for deck \(model.importTarget?.label ?? "none"): \(String(describing: result))")
            guard let deck = model.importTarget else { return }
            switch result {
            case .success(let url): Task { await model.load(url: url, into: deck) }
            case .failure(let error): deck.error = error.localizedDescription
            }
        }
    }
}

extension ContentView {
    /// Self-test: with SPINDLE_SNAPSHOT=<folder> set, renders every page to a
    /// PNG (with a track loaded and a simulated record playing), then puts
    /// the page back. Used to check layouts without clicking through.
    func snapshotIfRequested() async {
        guard let dir = ProcessInfo.processInfo.environment["SPINDLE_SNAPSHOT"] else { return }
        let original = model.page
        try? await Task.sleep(for: .seconds(4))
        let tracks = model.library.tracks
        if tracks.count > 1 {
            await model.load(url: tracks[0].url, into: model.decks[0])
            await model.load(url: tracks[1].url, into: model.decks[1])
            if model.laptop {
                model.setPlaying(true, deck: model.decks[0])
                try? await Task.sleep(for: .seconds(1))
                model.sync(deck: model.decks[1])
                model.setPlaying(true, deck: model.decks[1])
                try? await Task.sleep(for: .seconds(2))
                if let engine = model.engine,
                   let a = model.decks[0].track.flatMap({ model.prep.prep(for: $0.url) }),
                   let b = model.decks[1].track.flatMap({ model.prep.prep(for: $0.url) }) {
                    let pa = a.beatIndex(at: engine.decks[0].telemetry.pointee.playhead)
                    let pb = b.beatIndex(at: engine.decks[1].telemetry.pointee.playhead)
                    var diff = (pa - pa.rounded(.down)) - (pb - pb.rounded(.down))
                    if diff > 0.5 { diff -= 1 } else if diff < -0.5 { diff += 1 }
                    spindleLog.notice(String(format: "Sync check: A %.2f BPM, B %.2f BPM, beat phase difference %.3f beats (%.1f ms)",
                        a.bpm * (1 + model.decks[0].tempo), b.bpm * (1 + model.decks[1].tempo), diff, diff * a.beatSeconds * 1000))
                }
            } else {
                model.setSimulatedPitch(1, deck: model.decks[0])
            }
            model.selectForPrep(tracks[0].url)
            model.organizeSelection = [tracks[0].url]
            model.highlightedClip = tracks[2 % tracks.count].url
        }
        // Playlist test: a folder with a playlist holding library tracks and
        // a file from outside the music folder; removed again at the end.
        var testFolder: UUID?
        if let outside = ProcessInfo.processInfo.environment["SPINDLE_SNAPSHOT_PLAYLIST"], tracks.count > 5 {
            let store = model.library.playlists
            let folder = store.create(name: "Test sets", folder: true, in: nil)
            let list = store.create(name: "Warm-up", folder: false, in: folder)
            _ = store.create(name: "Peak time", folder: false, in: folder)
            model.addToPlaylist(tracks.prefix(5).map(\.url) + [URL(fileURLWithPath: outside)], playlist: list)
            model.library.playlist = list
            model.organizeSelection = [tracks[0].url]
            testFolder = folder
            try? await Task.sleep(for: .seconds(8))      // let the outside file be analysed
        }
        // Tag test: tempo groups plus one hand-made tag; removed at the end.
        var testTags: [UUID] = []
        let savedColumns = UserDefaults.standard.string(forKey: "mix.columns")
        if ProcessInfo.processInfo.environment["SPINDLE_SNAPSHOT_TAGS"] != nil {
            let store = model.library.tags
            let before = Set(store.tags.map(\.id))
            store.makeTempoGroups(bpms: model.library.allTracks.compactMap { model.analysis.analysis(for: $0.url)?.bpm })
            let vocal = store.create(name: "vocal")
            store.set(vocal, on: tracks.prefix(3).map(\.url.path), true)
            testTags = store.tags.map(\.id).filter { !before.contains($0) }
            let groups = store.tags.filter { $0.rule != nil }
            spindleLog.notice("Tag test: \(groups.count) tempo groups: " + groups.map { "\($0.name) (\(model.library.tracks(withTag: $0.id).count))" }.joined(separator: ", "))
            model.library.tag = groups.max { model.library.tracks(withTag: $0.id).count < model.library.tracks(withTag: $1.id).count }?.id
            UserDefaults.standard.set("tags", forKey: "mix.columns")
        }
        let recordTest = ProcessInfo.processInfo.environment["SPINDLE_SNAPSHOT_RECORD"] != nil
        if recordTest { model.toggleRecording() }
        let started = Date()
        for page in AppModel.Page.allCases {
            if page == .sessions && recordTest {
                // Long enough for deck A to be logged (20 s of play).
                let wait = 24 - Date().timeIntervalSince(started)
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                model.toggleRecording()
            }
            model.page = page
            try? await Task.sleep(for: .seconds(page == .sessions ? 2 : 4))
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                  let view = window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(page.rawValue).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            spindleLog.notice("Snapshot: \(url.path)")
        }
        model.setSimulatedPitch(0, deck: model.decks[0])
        for deck in model.decks { model.setPlaying(false, deck: deck) }
        if !testTags.isEmpty {
            model.library.selectAll()
            for id in testTags { model.library.tags.delete(id) }
            UserDefaults.standard.set(savedColumns, forKey: "mix.columns")
        }
        if let testFolder {
            model.library.selectAll()
            model.library.playlists.delete(testFolder)
        }
        model.page = original
    }
}

private struct TopBar: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: Theme.space3) {
            Text("Spindle").font(Theme.title).foregroundStyle(Theme.ink)
            RecordButton(model: model)
            if model.sessions.recording {
                Text(SessionStore.clock(model.sessions.elapsed)).font(Theme.readoutSm).foregroundStyle(Theme.ink)
            }
            Spacer()
            Button("MIDI") { model.showingMIDI = true }
                .buttonStyle(FlatButtonStyle())
                .help("Map an Akai MPK mini or other MIDI controller (MIDI learn)")

            Picker("Device", selection: $model.selectedDeviceID) {
                ForEach(model.devices) { device in
                    Text("\(device.name)  (\(device.inputChannels) in / \(device.outputChannels) out)")
                        .tag(Optional(device.id))
                }
            }
            .frame(maxWidth: 320)

            if model.controlMode != .laptop {
                Picker("Vinyl", selection: $model.definition) {
                    ForEach(TimecodeDefinition.all) { def in
                        Text(def.name).tag(def)
                    }
                }
                .frame(maxWidth: 240)
            }

            Picker("Play with", selection: Binding(
                get: { model.controlMode },
                set: { mode in
                    model.controlMode = mode
                    Task { await model.start() }
                })) {
                ForEach(AppModel.ControlMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .frame(maxWidth: 220)
            .help("Vinyl: Traktor timecode records. Laptop: play from Spindle alone. Simulated vinyl: virtual turntables for testing.")

            Button(model.running ? "Restart" : "Start") {
                Task { await model.start() }
            }
            .buttonStyle(FlatButtonStyle(primary: !model.running))

            if model.running {
                Button("Stop") { model.stop() }
                    .buttonStyle(FlatButtonStyle())
            }

            status
        }
        .font(Theme.body)
        .foregroundStyle(Theme.inkMuted)
        .padding(.horizontal, Theme.space3)
        .frame(height: 44)
        .background(Theme.panelRaised)
        .onAppear { model.refreshDevices() }
    }

    @ViewBuilder
    private var status: some View {
        if let engine = model.engine {
            let ms = Double(engine.bufferFrames) / engine.sampleRate * 1000
            Text(String(format: "%.0f kHz · %d smp · %.1f ms%@",
                        engine.sampleRate / 1000, engine.bufferFrames, ms,
                        engine.simulate ? " · SIM" : (engine.laptop ? " · LAPTOP" : "")))
                .font(Theme.readoutSm)
                .foregroundStyle(Theme.inkMuted)
        } else {
            LabelText("Stopped", color: Theme.inkFaint)
        }
    }
}

/// Bottom page bar like Resolve. Pages not built yet are dimmed.
private struct PageBar: View {
    @Binding var page: AppModel.Page

    var body: some View {
        HStack(spacing: Theme.space4) {
            Spacer()
            ForEach(AppModel.Page.allCases) { p in
                let active = p == page
                Button {
                    if p.available { page = p }
                } label: {
                    VStack(spacing: 3) {
                        Text(p.rawValue)
                            .font(Theme.label)
                            .foregroundStyle(active ? Theme.accent : (p.available ? Theme.inkMuted : Theme.inkFaint.opacity(0.5)))
                        Rectangle()
                            .fill(active ? Theme.accent : .clear)
                            .frame(width: 24, height: 2)
                    }
                    .padding(.horizontal, Theme.space2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!p.available)
                .help(p.available ? p.rawValue : "\(p.rawValue): coming in a later build step")
            }
            Spacer()
        }
        .frame(height: 36)
        .background(Theme.panelRaised)
    }
}

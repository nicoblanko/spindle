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
    @Bindable var model: AppModel

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
            HStack(spacing: 0) {
                Group {
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
                }
                .frame(maxWidth: .infinity)
                if LookSettings.shared.panelOpen {
                    Rectangle().fill(Theme.line).frame(width: 1)
                    ColorPanel(look: LookSettings.shared)
                        .frame(width: 210)
                        .transition(.move(edge: .trailing))
                }
            }
            .frame(maxHeight: .infinity)
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
        if let out = ProcessInfo.processInfo.environment["SPINDLE_GRIDCHECK"] {
            try? await Task.sleep(for: .seconds(3))
            let items = model.library.allTracks.compactMap { t in model.prep.prep(for: t.url).map { (t.url, $0) } }
            let report = await GridCheck.run(items)
            try? report.write(toFile: out, atomically: true, encoding: .utf8)
            spindleLog.notice("Grid check written")
            return
        }
        if ProcessInfo.processInfo.environment["SPINDLE_SCRUBTEST"] != nil {
            spindleLog.notice("\(DeckEngine.scrubTest())")
            spindleLog.notice("\(DeckEngine.loopTest())")
            return
        }
        if ProcessInfo.processInfo.environment["SPINDLE_PREPLAG"] != nil {
            // Lag check: step through Prep's list like holding the down arrow.
            try? await Task.sleep(for: .seconds(4))
            model.page = .prep
            try? await Task.sleep(for: .seconds(2))
            spindleLog.notice("Lag check: start")
            var worst = 0.0, last = Date()
            for _ in 0..<40 {
                model.prepStepTrack(1, in: model.pageRecords("prep").map(\.id))
                try? await Task.sleep(for: .milliseconds(120))
                let gap = Date().timeIntervalSince(last) - 0.12
                worst = max(worst, gap); last = Date()
            }
            spindleLog.notice(String(format: "Lag check: worst main-thread delay %.0f ms", worst * 1000))
            return
        }
        guard let dir = ProcessInfo.processInfo.environment["SPINDLE_SNAPSHOT"] else { return }
        let original = model.page
        // SPINDLE_LOOK=rgb|3-band|mono[,dusk|,ink]: snapshot in that look, then restore yours.
        let look = LookSettings.shared
        let savedLook = (look.theme, look.waveStyle, look.panelOpen)
        if let spec = ProcessInfo.processInfo.environment["SPINDLE_LOOK"]?.lowercased() {
            look.panelOpen = spec.contains("panel")
            look.theme = spec.contains("ink") || spec.contains("darker") ? .ink : spec.contains("dusk") ? .dusk : .studio
            look.waveStyle = spec.contains("rgb") ? .rgb : spec.contains("mono") ? .mono : .threeBand
        }
        defer { look.theme = savedLook.0; look.waveStyle = savedLook.1; look.panelOpen = savedLook.2 }
        try? await Task.sleep(for: .seconds(4))
        let tracks = model.library.tracks
        // Speed check: building the Organize list with the current view.
        do {
            let base = model.library.allTracks.enumerated().map {
                Record(track: $1, analysis: model.analysis.analysis(for: $1.url), index: $0 + 1)
            }
            let t0 = Date()
            for _ in 0..<20 {
                let r = model.records.apply(model.organizeView, to: base)
                if let g = model.organizeView.groupBy { _ = model.records.group(r, by: g) }
            }
            spindleLog.notice(String(format: "Speed check: list with current view %.2f ms per build (%d tracks)",
                                     Date().timeIntervalSince(t0) * 1000 / 20, base.count))
        }
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
            // Delete → Recently deleted → restore.
            try? await Task.sleep(for: .seconds(1))
            let before = store.node(list)?.tracks.count ?? 0
            store.delete(list)
            let inTrash = store.trash.first?.name == "Warm-up" && store.node(list) == nil
            if let entry = store.trash.first { store.restore(entry) }
            let back = store.node(list)?.tracks.count ?? -1
            spindleLog.notice("Restore test: \(before) tracks; in Recently deleted after delete: \(inTrash); after restore: \(back) tracks, parent kept: \(store.node(list)?.parent == folder)")
            try? await Task.sleep(for: .seconds(8))      // let the outside file be analysed
        }
        // Field test: tags, a single-select and a rating field, grouped and
        // filtered like Airtable; everything is removed again at the end.
        var testTags: [UUID] = []
        var testFields: [UUID] = []
        var testViews: [UUID] = []
        var restoreViewID: UUID?
        let savedColumns = UserDefaults.standard.string(forKey: "mix.columns")
        let savedGroupField = UserDefaults.standard.string(forKey: "mix.groupField")
        let savedView = model.organizeView
        if ProcessInfo.processInfo.environment["SPINDLE_SNAPSHOT_TAGS"] != nil, tracks.count > 8 {
            let store = model.library.tags
            let before = Set(store.tags.map(\.id))
            store.makeTempoGroups(bpms: model.library.allTracks.compactMap { model.analysis.analysis(for: $0.url)?.bpm })
            let vocal = store.create(name: "vocal")
            let warm = store.create(name: "warm-up")
            store.set(vocal, on: tracks.prefix(4).map(\.url.path), true)
            store.set(warm, on: tracks[2..<7].map(\.url.path), true)
            testTags = store.tags.map(\.id).filter { !before.contains($0) }
            let set = model.fields.addField(name: "Set", type: .singleSelect)
            let club = model.fields.addOption(set, name: "Club")!
            let radio = model.fields.addOption(set, name: "Radio")!
            let rating = model.fields.addField(name: "Rating", type: .rating)
            for (i, t) in tracks.prefix(8).enumerated() {
                model.fields.set(t.url.path, set, .options([i % 2 == 0 ? club : radio]))
                model.fields.set(t.url.path, rating, .rating(i % 5 + 1))
            }
            testFields = [set, rating]
            model.library.selectAll()
            model.organizeView = ViewSettings(conditions: [FilterCondition(field: .energy, op: .gte, number: 5)],
                                              groupBy: .tags, hidden: [.intro, .outro, .folder, .length, .tempoGroup])
            UserDefaults.standard.set("field", forKey: "mix.columns")
            UserDefaults.standard.set(String(data: try! JSONEncoder().encode(FieldRef.tags), encoding: .utf8), forKey: "mix.groupField")
            let shown = model.records.apply(model.organizeView, to: model.library.visibleTracks.enumerated().map {
                Record(track: $1, analysis: model.analysis.analysis(for: $1.url), index: $0 + 1) })
            let groups = model.records.group(shown, by: .tags)
            // Saved views: two templates, switch, edit, revert.
            let viewsBefore = Set(model.savedViews.map(\.id))
            let savedCurrent = model.currentViewID
            model.organizeView = ViewSettings(conditions: [FilterCondition(field: .tags, op: .hasAny, options: [vocal.uuidString])],
                                              groupBy: .tempoGroup, hidden: [.intro, .outro, .mood, .length])
            let warmView = model.saveViewAs("Vocal warm-up")
            model.organizeView = ViewSettings(conditions: [FilterCondition(field: .energy, op: .gte, number: 7)],
                                              groupBy: .key, hidden: [.intro, .outro, .mood, .length],
                                              fieldOrder: [.tags, .key, .bpm, .energy, .tempoGroup])
            let peakView = model.saveViewAs("Peak time")
            model.applyView(warmView)
            let warmCount = model.records.apply(model.organizeView, to: model.library.allTracks.enumerated().map {
                Record(track: $1, analysis: model.analysis.analysis(for: $1.url), index: $0 + 1) }).count
            model.organizeView.conditions.append(FilterCondition(field: .bpm, op: .gt, number: 126))
            let editedFlag = model.viewModified
            model.revertCurrentView()
            spindleLog.notice("View test: '\(model.currentView?.name ?? "-")' shows \(warmCount) tracks; edited after change: \(editedFlag); after revert: \(model.viewModified); views: \(model.savedViews.map(\.name))")
            model.applyView(peakView)
            testViews = model.savedViews.map(\.id).filter { !viewsBefore.contains($0) }
            restoreViewID = savedCurrent
            spindleLog.notice("Field test: \(shown.count) tracks with energy ≥ 5; groups by Tags: " + groups.map { g in
                "\(g.options.map(\.name).joined(separator: "+").isEmpty ? g.title : g.options.map(\.name).joined(separator: "+")) (\(g.records.count))" }.joined(separator: ", "))
        }
        // Stack test: queue five tracks, Next on deck B; queue restored at the end.
        let savedStack = model.stack
        let savedTab = model.mixTab
        if tracks.count > 9 {
            model.stack = []
            model.addToStack(tracks[3..<8].map(\.url))
            model.next(deck: model.decks[1])
            try? await Task.sleep(for: .seconds(1))
            spindleLog.notice("Stack test: deck B \(model.decks[1].track?.title ?? "-"), queue \(model.stack.count), played \(model.played.count)")
            if let first = model.library.playlists.playlists.first { model.mixTab = first.node.id.uuidString }
        }
        // Organize test: a set open in the panel, two tagged tracks; removed at the end.
        var organizeSet: UUID?
        var organizeTag: UUID?
        let savedOpenSet = model.openSet
        if ProcessInfo.processInfo.environment["SPINDLE_SNAPSHOT_ORGANIZE"] != nil, tracks.count > 10 {
            let store = model.library.playlists
            let set = store.create(name: "Test set", folder: false, in: nil)
            model.addToPlaylist(tracks[3..<9].map(\.url), playlist: set)
            let tag = model.library.tags.create(name: "test-acid")
            model.library.tags.set(tag, on: [tracks[0].url.path, tracks[1].url.path], true)
            model.library.selectAll()
            model.openSet = set
            model.organizeSelection = [tracks[10].url]
            organizeSet = set
            organizeTag = tag
        }
        if let a = model.decks[0].track.flatMap({ model.prep.prep(for: $0.url) })?.loops.first {
            model.playLoopSlot(a, deck: model.decks[0])
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
            var prepStart: (Double, Date)?
            if page == .prep {
                // Pre-listen check: play with the click for the snapshot wait.
                try? await Task.sleep(for: .seconds(1))
                model.prepSetMetronome(true)
                model.prepSetPlaying(true)
                // Every FX on, in the player only (the track's prep is untouched).
                if let e = model.engine?.preview {
                    for kind in FXKind.allCases { e.setFX(kind, kind == .filter ? 0.3 : 0.6) }
                }
                prepStart = (model.prepPosition, Date())
            }
            try? await Task.sleep(for: .seconds(page == .sessions ? 2 : 4))
            if let (t0, d0) = prepStart {
                spindleLog.notice(String(format: "Prep check: preview %@, moved %.2f s in %.2f s, output %d",
                                         model.prepPage.preview == nil ? "not loaded" : "loaded",
                                         model.prepPosition - t0, Date().timeIntervalSince(d0), model.engine?.previewOutput ?? -1))
            }
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                  let view = window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(page.rawValue).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            if page == .organize && organizeSet != nil {
                model.organizeSelection = Set(tracks.prefix(3).map(\.url))
                try? await Task.sleep(for: .seconds(2))
                if let rep2 = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep2)
                    try? rep2.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("Organize-inspector.png"))
                }
            }
            spindleLog.notice("Snapshot: \(url.path)")
            if page == .prep {
                model.prepSetPlaying(false)
                model.syncPreviewFX()
                model.prepSetMetronome(false)
            }
        }
        model.setSimulatedPitch(0, deck: model.decks[0])
        model.setLoop(false, deck: model.decks[0])
        for deck in model.decks { model.setPlaying(false, deck: deck) }
        model.stack = savedStack
        model.played = []
        model.mixTab = savedTab
        if !testTags.isEmpty || !testFields.isEmpty {
            model.library.selectAll()
            for id in testTags { model.library.tags.delete(id) }
            for id in testFields { model.fields.deleteField(id) }
            for id in testViews { model.deleteView(id) }
            model.currentViewID = restoreViewID
            model.organizeView = savedView
            UserDefaults.standard.set(savedColumns, forKey: "mix.columns")
            UserDefaults.standard.set(savedGroupField, forKey: "mix.groupField")
        }
        if let organizeSet {
            model.library.playlists.delete(organizeSet)
            if let entry = model.library.playlists.trash.first(where: { $0.nodes.first?.id == organizeSet }) {
                model.library.playlists.purge(entry)
            }
            if let organizeTag { model.library.tags.delete(organizeTag) }
            model.openSet = savedOpenSet
            model.organizeSelection = []
        }
        if let testFolder {
            model.library.selectAll()
            model.library.playlists.delete(testFolder)
            if let entry = model.library.playlists.trash.first(where: { $0.nodes.first?.id == testFolder }) {
                model.library.playlists.purge(entry)
            }
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
            ColorPanelButton(look: LookSettings.shared)
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

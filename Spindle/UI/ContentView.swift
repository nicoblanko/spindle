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
            model.setSimulatedPitch(1, deck: model.decks[0])
            model.selectForPrep(tracks[0].url)
            model.highlightedClip = tracks[2 % tracks.count].url
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

            Picker("Vinyl", selection: $model.definition) {
                ForEach(TimecodeDefinition.all) { def in
                    Text(def.name).tag(def)
                }
            }
            .frame(maxWidth: 240)

            Toggle("Simulate", isOn: $model.simulate)
                .toggleStyle(.checkbox)

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
                        engine.simulate ? " · SIM" : ""))
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

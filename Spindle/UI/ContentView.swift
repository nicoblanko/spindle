//
//  ContentView.swift
//  Spindle
//
//  Build step 1: the timecode prototype. Device bar, track list from the
//  music folder, one box per deck (waveforms and readouts), and the page bar.
//

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
            LibraryPanel(library: model.library, model: model)
                .frame(minHeight: 180, idealHeight: 240, maxHeight: 280)
            Rectangle().fill(Theme.line).frame(height: 1)
            HStack(spacing: 1) {
                ForEach(model.decks) { deck in
                    DeckPanel(deck: deck, model: model)
                }
            }
            .frame(maxHeight: .infinity)
            .background(Theme.line)
            Rectangle().fill(Theme.line).frame(height: 1)
            PageBar()
        }
        .background(Theme.bg)
        .preferredColorScheme(.dark)
        .frame(minWidth: 1100, minHeight: 820)
        .task { await model.start() }
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

private struct TopBar: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: Theme.space3) {
            Text("Spindle").font(Theme.title).foregroundStyle(Theme.ink)
            Text("Timecode prototype").font(Theme.caption).foregroundStyle(Theme.inkMuted)
            Spacer()

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

/// Bottom page bar like Resolve. Only Mix is built in this step.
private struct PageBar: View {
    private let pages = ["Organize", "Prep", "Mix", "Sessions"]
    var body: some View {
        HStack(spacing: Theme.space4) {
            Spacer()
            ForEach(pages, id: \.self) { page in
                let active = page == "Mix"
                VStack(spacing: 3) {
                    Text(page)
                        .font(Theme.label)
                        .foregroundStyle(active ? Theme.accent : Theme.inkFaint)
                    Rectangle()
                        .fill(active ? Theme.accent : .clear)
                        .frame(width: 24, height: 2)
                }
                .padding(.horizontal, Theme.space2)
            }
            Spacer()
        }
        .frame(height: 36)
        .background(Theme.panelRaised)
    }
}

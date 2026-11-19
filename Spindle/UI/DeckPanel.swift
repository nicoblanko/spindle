//
//  DeckPanel.swift
//  Spindle
//
//  One deck's readouts: time, pitch, direction, timecode lock and scope.
//

import SwiftUI
import UniformTypeIdentifiers
import OSLog

struct DeckPanel: View {
    @Bindable var deck: DeckModel
    let model: AppModel

    private var engine: DeckEngine? { model.engine?.decks[deck.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(deck.color).frame(height: 3)
            header
            Rectangle().fill(Theme.line).frame(height: 1)
            waveforms
            Rectangle().fill(Theme.line).frame(height: 1)
            TimelineView(.animation) { _ in
                live(engine?.telemetry.pointee ?? DeckTelemetry())
            }
            .padding(Theme.space3)
            Rectangle().fill(Theme.line).frame(height: 1)
            controls
            if model.engine?.simulate == true {
                Rectangle().fill(Theme.line).frame(height: 1)
                simulator.padding(Theme.space3)
            }
        }
        .background(Theme.panel)
        .dropDestination(for: URL.self) { urls, _ in
            spindleLog.notice("Drop on deck \(deck.label): \(urls.count) file(s)")
            guard let url = urls.first else { return false }
            Task { await model.load(url: url, into: deck) }
            return true
        }
    }

    private var header: some View {
        HStack(spacing: Theme.space3) {
            LabelText("Deck \(deck.label)", color: deck.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(deck.track?.title ?? (deck.loading ? "Loading…" : "No track"))
                    .font(Theme.title)
                    .foregroundStyle(deck.track == nil ? Theme.inkFaint : Theme.ink)
                    .lineLimit(1)
                if let error = deck.error {
                    Text(error).font(Theme.caption).foregroundStyle(Theme.warn).lineLimit(1)
                } else if let artist = deck.track?.artist, !artist.isEmpty {
                    Text(artist).font(Theme.caption).foregroundStyle(Theme.inkMuted).lineLimit(1)
                }
            }
            Spacer()
            Button("Load…") { model.chooseFile(for: deck) }
                .buttonStyle(FlatButtonStyle())
        }
        .padding(.horizontal, Theme.space3)
        .padding(.vertical, Theme.space2)
        .background(Theme.panelRaised)
    }

    /// The whole track on top, the zoomed scrolling waveform below.
    private var waveforms: some View {
        VStack(spacing: 1) {
            TrackOverview(deck: deck, telemetry: engine?.telemetry)
                .frame(height: 32)
            WaveformLane(deck: deck, telemetry: engine?.telemetry)
                .frame(minHeight: 140, maxHeight: .infinity)
        }
        .background(Theme.line)
    }

    /// Routing and deck options.
    private var controls: some View {
        HStack(spacing: Theme.space3) {
            routingPickers
            Toggle("Test tone", isOn: Binding(
                get: { deck.testTone },
                set: { model.setTestTone($0, deck: deck) }))
                .toggleStyle(.button)
                .tint(deck.color)
                .help("Plays a quiet \(deck.id == 0 ? "440" : "660") Hz tone on this deck's output, to check which mixer channel it reaches.")
            Spacer()
            Toggle("Absolute", isOn: Binding(
                get: { deck.absoluteMode },
                set: { model.setAbsolute($0, deck: deck) }))
                .toggleStyle(.checkbox)
            Button("Cue to needle") { model.cueToNeedle(deck: deck) }
                .buttonStyle(FlatButtonStyle())
                .disabled(deck.track == nil)
                .help("Restarts the track from wherever the needle is now.")
        }
        .font(Theme.caption)
        .foregroundStyle(Theme.inkMuted)
        .padding(.horizontal, Theme.space3)
        .padding(.vertical, Theme.space2)
        .background(Theme.panelRaised)
    }

    /// Input and output stereo pairs for this deck, e.g. "In 3–4", "Out 1–2".
    @ViewBuilder
    private var routingPickers: some View {
        if let device = model.engine?.device {
            let inputs = stride(from: 0, to: device.inputChannels - 1, by: 2).map { $0 }
            let outputs = stride(from: 0, to: device.outputChannels - 1, by: 2).map { $0 }
            let input = deck.id == 0 ? model.routing.inputA : model.routing.inputB
            let output = deck.id == 0 ? model.routing.outputA : model.routing.outputB
            if !model.simulate && !inputs.isEmpty {
                Picker("In", selection: Binding(get: { input }, set: { model.setInput($0, deck: deck) })) {
                    ForEach(inputs, id: \.self) { Text("\($0 + 1)–\($0 + 2)").tag($0) }
                }
                .fixedSize()
            }
            if outputs.count >= 2 {
                Picker("Out", selection: Binding(get: { output }, set: { model.setOutput($0, deck: deck) })) {
                    ForEach(outputs, id: \.self) { Text("\($0 + 1)–\($0 + 2)").tag($0) }
                }
                .fixedSize()
            }
        }
    }

    @ViewBuilder
    private func live(_ t: DeckTelemetry) -> some View {
        HStack(alignment: .top, spacing: Theme.space4) {
            VStack(alignment: .leading, spacing: Theme.space2) {
                Text(Self.clock(t.playhead))
                    .font(Theme.readoutXL)
                    .foregroundStyle(Theme.ink)
                if let duration = deck.track?.duration {
                    Text("−" + Self.clock(max(0, duration - t.playhead)))
                        .font(Theme.readout)
                        .foregroundStyle(Theme.inkMuted)
                }
                HStack(spacing: Theme.space3) {
                    readout("Pitch", Self.pitch(t.pitch))
                    readout("Dir", abs(t.pitch) < 0.005 ? "■" : (t.pitch >= 0 ? "▶" : "◀"))
                    readout("Mode", t.absolute ? "ABS" : "REL",
                            color: t.absolute ? Theme.ink : Theme.inkMuted)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: Theme.space2) {
                LabelText("Timecode")
                HStack(alignment: .top, spacing: Theme.space3) {
                    ScopeView(scope: engine?.scope, color: deck.color)
                        .frame(width: 96, height: 96)
                    VStack(alignment: .leading, spacing: Theme.space1) {
                        lockBadge(t)
                        readout("Position", t.hasPosition ? Self.clock(t.timecodeSeconds) : "—")
                        readout("Signal", Self.db(t.signal))
                        SignalMeter(level: t.signal)
                            .frame(width: 96, height: 4)
                        if t.hasPosition {
                            Text(DecoderConfig.all[Int(t.activeConfig)].label)
                                .font(Theme.readoutSm)
                                .foregroundStyle(Theme.inkFaint)
                        }
                    }
                }
            }
        }
    }

    private func lockBadge(_ t: DeckTelemetry) -> some View {
        let noSignal = t.signal < 0.002
        let text = noSignal ? "No signal" : (t.hasPosition ? "Locked" : "Searching")
        let color = noSignal ? Theme.warn : (t.hasPosition ? Theme.match : Theme.inkMuted)
        return HStack(spacing: Theme.space1) {
            Circle().fill(color).frame(width: 6, height: 6)
            LabelText(text, color: color)
        }
    }

    private func readout(_ label: String, _ value: String, color: Color = Theme.ink) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            LabelText(label, color: Theme.inkFaint)
            Text(value).font(Theme.readout).foregroundStyle(color)
        }
    }

    private var simulator: some View {
        VStack(alignment: .leading, spacing: Theme.space2) {
            HStack {
                LabelText("Simulated turntable")
                Spacer()
                Text(Self.pitch(deck.simulatedPitch))
                    .font(Theme.readoutSm)
                    .foregroundStyle(Theme.inkMuted)
            }
            Slider(value: Binding(
                get: { deck.simulatedPitch },
                set: { model.setSimulatedPitch($0, deck: deck) }), in: -2...2)
            .tint(deck.color)
            HStack(spacing: Theme.space2) {
                Button("◀ Rev") { model.setSimulatedPitch(-1, deck: deck) }
                Button("■ Stop") { model.setSimulatedPitch(0, deck: deck) }
                Button("▶ 33⅓") { model.setSimulatedPitch(1, deck: deck) }
                Button("+8%") { model.setSimulatedPitch(1.08, deck: deck) }
                Spacer()
                Button("Needle to start") { model.seekSimulator(seconds: 1, deck: deck) }
            }
            .buttonStyle(FlatButtonStyle())
        }
    }

    static func clock(_ seconds: Double) -> String {
        let negative = seconds < 0
        let s = abs(seconds)
        let minutes = Int(s / 60)
        let rest = s - Double(minutes * 60)
        return (negative ? "-" : "") + String(format: "%02d:%04.1f", minutes, rest)
    }

    static func pitch(_ p: Double) -> String {
        // Speed relative to 33⅓ rpm, sign ignored (direction has its own readout).
        String(format: "%+.2f%%", (abs(p) - 1) * 100)
    }

    static func db(_ level: Float) -> String {
        level < 0.0001 ? "−∞ dB" : String(format: "%.0f dB", 20 * log10(level))
    }
}

struct SignalMeter: View {
    let level: Float
    var body: some View {
        GeometryReader { geo in
            let db = level < 0.0001 ? -60 : max(-60, min(0, 20 * log10(level)))
            let fraction = CGFloat((db + 60) / 60)
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.control)
                Rectangle()
                    .fill(db > -1 ? Theme.warn : Theme.inkMuted)
                    .frame(width: geo.size.width * fraction)
            }
        }
    }
}

/// X/Y plot of the two timecode channels. A clean signal draws a ring; its
/// roundness shows the stereo balance and its size the level.
struct ScopeView: View {
    let scope: UnsafeMutablePointer<Float>?
    let color: Color

    var body: some View {
        TimelineView(.animation) { _ in
            Canvas { context, size in
                var grid = Path()
                grid.addRect(CGRect(x: size.width / 2, y: 0, width: 1, height: size.height))
                grid.addRect(CGRect(x: 0, y: size.height / 2, width: size.width, height: 1))
                context.fill(grid, with: .color(Theme.line))
                guard let scope else { return }
                // Auto-scale so quiet phono signals still fill the scope.
                var peak: Float = 0.001
                for i in 0..<(DeckEngine.scopeFrames * 2) { peak = max(peak, abs(scope[i])) }
                let scale = Float(size.width / 2 - 4) / peak
                var dots = Path()
                for i in 0..<DeckEngine.scopeFrames {
                    let x = size.width / 2 + CGFloat(scope[i * 2] * scale)
                    let y = size.height / 2 - CGFloat(scope[i * 2 + 1] * scale)
                    dots.addRect(CGRect(x: x, y: y, width: 1.5, height: 1.5))
                }
                context.fill(dots, with: .color(color))
            }
        }
        .background(Theme.bg)
        .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
    }
}

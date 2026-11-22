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
    /// Mix page: smaller waveform and a one-line readout.
    var compact = false

    /// Mix page: the cover left of the waveforms, per deck.
    @AppStorage private var showArt: Bool

    init(deck: DeckModel, model: AppModel, compact: Bool = false) {
        self.deck = deck
        self.model = model
        self.compact = compact
        _showArt = AppStorage(wrappedValue: true, "mix.showArt.\(deck.label)")
    }

    private var engine: DeckEngine? { model.engine?.decks[deck.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(deck.color).frame(height: 3)
            header
            Rectangle().fill(Theme.line).frame(height: 1)
            waveforms
            Rectangle().fill(Theme.line).frame(height: 1)
            Group {
                if compact {
                    liveCompact
                } else {
                    TimelineView(.animation) { _ in live(engine?.telemetry.pointee ?? DeckTelemetry()) }
                }
            }
            .padding(compact ? Theme.space2 : Theme.space3)
            Rectangle().fill(Theme.line).frame(height: 1)
            controls
            if model.engine?.simulate == true && !compact {
                Rectangle().fill(Theme.line).frame(height: 1)
                simulator.padding(Theme.space3)
            }
            if model.engine?.simulate == true && compact {
                Rectangle().fill(Theme.line).frame(height: 1)
                simulatorCompact.padding(.horizontal, Theme.space3).padding(.vertical, Theme.space1)
            }
            Spacer(minLength: 0)
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
            if compact {
                Button { showArt.toggle() } label: {
                    Image(systemName: "photo").font(.system(size: 11))
                        .foregroundStyle(showArt ? Theme.ink : Theme.inkFaint)
                        .frame(width: 22, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(showArt ? "Hide album art" : "Show album art")
            }
            Button("Load…") { model.chooseFile(for: deck) }
                .buttonStyle(FlatButtonStyle())
        }
        .padding(.horizontal, Theme.space3)
        .padding(.vertical, Theme.space2)
        .background(Theme.panelRaised)
    }

    /// The whole track on top (click, drag or scroll to move through it), the
    /// zoomed scrolling waveform below (scroll or drag to scrub, pinch or
    /// ⌘-scroll to zoom).
    private var waveforms: some View {
        HStack(spacing: 1) {
            if compact && showArt {
                // Square, as tall as both waveforms (32 + 1 + 96).
                AlbumArtImage(url: deck.track?.url).frame(width: 129, height: 129)
            }
            waveformStack
        }
        .background(Theme.line)
    }

    private var waveformStack: some View {
        VStack(spacing: 1) {
            GeometryReader { geo in
                TrackOverview(deck: deck, telemetry: engine?.telemetry,
                              prep: deck.track.flatMap { model.prep.prep(for: $0.url) })
                    .overlay {
                        WaveformInteraction(
                            onScroll: { points in
                                guard let d = deck.track?.duration else { return }
                                model.scrub(deck: deck, by: Double(points) * d / Double(max(geo.size.width, 1)))
                            },
                            onClick: { fraction in
                                guard let d = deck.track?.duration else { return }
                                model.seek(deck: deck, to: Double(fraction) * d)
                            },
                            dragsAbsolutely: true)
                    }
            }
            .frame(height: 32)
            GeometryReader { geo in
                WaveformLane(deck: deck, telemetry: engine?.telemetry,
                             prep: deck.track.flatMap { model.prep.prep(for: $0.url) },
                             window: deck.laneWindow)
                    .overlay {
                        WaveformInteraction(
                            onScroll: { points in
                                model.scrub(deck: deck, by: Double(points) * deck.laneWindow / Double(max(geo.size.width, 1)))
                            },
                            onClick: { fraction in
                                model.seek(deck: deck, by: (Double(fraction) - 0.5) * deck.laneWindow)
                            },
                            onZoom: { factor in
                                model.setLaneWindow(deck.laneWindow / Double(factor), deck: deck)
                            })
                    }
                    .overlay(alignment: .topTrailing) { zoomButtons }
            }
            .frame(height: compact ? 96 : 150)
        }
        .background(Theme.line)
    }

    private var zoomButtons: some View {
        HStack(spacing: 1) {
            Button("−") { model.setLaneWindow(deck.laneWindow * 1.5, deck: deck) }
            Text(String(format: "%.0f s", deck.laneWindow))
                .font(Theme.readoutSm).foregroundStyle(Theme.inkMuted)
                .frame(width: 34).frame(height: 18).background(Theme.panelRaised)
            Button("+") { model.setLaneWindow(deck.laneWindow / 1.5, deck: deck) }
        }
        .buttonStyle(ZoomButtonStyle())
        .padding(Theme.space1)
        .help("Zoom: pinch or ⌘-scroll on the waveform")
    }

    /// Routing and deck options; in laptop mode the transport.
    @ViewBuilder
    private var controls: some View {
        if model.laptop {
            LaptopTransport(deck: deck, model: model)
        } else {
            vinylControls
        }
    }

    private var vinylControls: some View {
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
        // Every element has a fixed size so nothing moves when lock or
        // signal changes during mixing.
        HStack(alignment: .top, spacing: Theme.space4) {
            VStack(alignment: .leading, spacing: Theme.space2) {
                Text(Self.clock(t.playhead))
                    .font(Theme.readoutXL)
                    .foregroundStyle(Theme.ink)
                    .frame(width: 150, alignment: .leading)
                Text(deck.track.map { "−" + Self.clock(max(0, $0.duration - t.playhead)) } ?? " ")
                    .font(Theme.readout)
                    .foregroundStyle(Theme.inkMuted)
                    .frame(width: 150, alignment: .leading)
                HStack(spacing: Theme.space3) {
                    readout("Pitch", Self.pitch(t.pitch), width: 84)
                    readout("Dir", abs(t.pitch) < 0.005 ? "■" : (t.pitch >= 0 ? "▶" : "◀"), width: 28)
                    readout("Mode", t.absolute ? "ABS" : "REL", width: 40,
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
                        readout("Position", t.lockHeld && !t.coasting ? Self.clock(t.timecodeSeconds) : "—", width: 110)
                        readout("Signal", Self.db(t.signal), width: 110)
                        SignalMeter(level: t.signal)
                            .frame(width: 96, height: 4)
                        if t.coasting {
                            Button { model.stopCoasting(deck: deck) } label: {
                                Text("■ Stop deck")
                                    .font(Theme.readoutSm)
                                    .foregroundStyle(Theme.ink)
                                    .padding(.horizontal, 6)
                                    .frame(height: 14)
                                    .background(Theme.control)
                                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSm))
                            }
                            .buttonStyle(.plain)
                                .help("The needle is up and the track is playing on. Stop it here, or put the needle back on a turning record.")
                                .frame(width: 130, height: 14, alignment: .leading)
                        } else {
                            Text(t.lockHeld ? DecoderConfig.all[Int(t.activeConfig)].label : " ")
                                .font(Theme.readoutSm)
                                .foregroundStyle(Theme.inkFaint)
                                .frame(width: 130, height: 14, alignment: .leading)
                        }
                    }
                }
            }
        }
        .frame(height: 140, alignment: .top)
    }

    /// One fixed-width line: time, remaining, pitch, mode, lock.
    /// The numbers change every frame, so they're drawn into a canvas: a
    /// canvas redraws without SwiftUI measuring the window again (text that
    /// changed every frame made the whole window re-lay out, ~20 fps).
    private var liveCompact: some View {
        HStack(spacing: Theme.space3) {
            TimelineView(.animation(minimumInterval: 1 / 30)) { _ in
                let t = engine?.telemetry.pointee ?? DeckTelemetry()
                let duration = deck.track?.duration
                let bpm = model.laptop ? model.liveBPM(deck).map { String(format: "%.1f BPM", $0 * max(abs(t.pitch), 0.0001) / max(abs(deck.pitch), 0.0001)) } ?? "" : (t.absolute ? "ABS" : "REL")
                Canvas { context, size in
                    func put(_ s: String, _ x: CGFloat, _ font: Font, _ color: Color) {
                        context.draw(Text(s).font(font).foregroundStyle(color), at: CGPoint(x: x, y: size.height / 2), anchor: .leading)
                    }
                    put(Self.clock(t.playhead), 0, Theme.readout, Theme.ink)
                    put(duration.map { "−" + Self.clock(max(0, $0 - t.playhead)) } ?? "", 104, Theme.readoutSm, Theme.inkMuted)
                    put(Self.pitch(t.pitch), 186, Theme.readoutSm, Theme.ink)
                    put(abs(t.pitch) < 0.005 ? "■" : (t.pitch >= 0 ? "▶" : "◀"), 262, Theme.readoutSm, Theme.ink)
                    put(bpm, 288, Theme.readoutSm, Theme.ink)
                }
            }
            .frame(width: 400, height: 22)
            Spacer(minLength: 0)
            // Lock and needle-up state: a few times a second is plenty.
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                let t = engine?.telemetry.pointee ?? DeckTelemetry()
                HStack(spacing: Theme.space2) {
                    if t.coasting {
                        Button("■ Stop deck") { model.stopCoasting(deck: deck) }
                            .font(Theme.readoutSm).buttonStyle(.plain).foregroundStyle(Theme.ink)
                            .padding(.horizontal, 6).background(Theme.control)
                    }
                    if !model.laptop { lockBadge(t) }
                }
            }
        }
        .frame(height: 22)
    }

    private var simulatorCompact: some View {
        HStack(spacing: Theme.space2) {
            LabelText("Sim", color: Theme.inkFaint)
            Button("◀") { model.setSimulatedPitch(-1, deck: deck) }
            Button("■") { model.setSimulatedPitch(0, deck: deck) }
            Button("▶") { model.setSimulatedPitch(1, deck: deck) }
            Button("+8%") { model.setSimulatedPitch(1.08, deck: deck) }
            Button(deck.simulatorLifted ? "Drop" : "Lift") { model.setSimulatorLifted(!deck.simulatorLifted, deck: deck) }
            Button("To start") { model.seekSimulator(seconds: 1, deck: deck) }
            Spacer(minLength: 0)
            Text(Self.pitch(deck.simulatedPitch)).font(Theme.readoutSm).foregroundStyle(Theme.inkFaint)
        }
        .buttonStyle(.plain)
        .font(Theme.caption)
        .foregroundStyle(Theme.inkMuted)
    }

    private func lockBadge(_ t: DeckTelemetry) -> some View {
        let noSignal = t.signal < 0.002 && !t.lockHeld
        let text = t.coasting ? "Needle up" : noSignal ? "No signal" : (t.lockHeld ? "Locked" : "Searching")
        let color = t.coasting ? deck.color : noSignal ? Theme.warn : (t.lockHeld ? Theme.match : Theme.inkMuted)
        return HStack(spacing: Theme.space1) {
            Circle().fill(color).frame(width: 6, height: 6)
            LabelText(text, color: color)
        }
        .frame(width: 110, alignment: .leading)
    }

    private func readout(_ label: String, _ value: String, width: CGFloat, color: Color = Theme.ink) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            LabelText(label, color: Theme.inkFaint)
            Text(value).font(Theme.readout).foregroundStyle(color).lineLimit(1)
        }
        .frame(width: width, alignment: .leading)
    }

    private var simulator: some View {
        VStack(alignment: .leading, spacing: Theme.space2) {
            HStack {
                LabelText("Simulated turntable · \(model.engine?.definition.name ?? "")")
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
                Button(deck.simulatorLifted ? "Drop needle" : "Lift needle") {
                    model.setSimulatorLifted(!deck.simulatorLifted, deck: deck)
                }
                Button("Needle to start") { model.seekSimulator(seconds: 1, deck: deck) }
            }
            .buttonStyle(FlatButtonStyle())
        }
    }

    static func clock(_ seconds: Double) -> String {
        let negative = seconds < 0
        let tenths = Int((abs(seconds) * 10).rounded())
        return (negative ? "-" : "") + String(format: "%02d:%02d.%d", tenths / 600, tenths / 10 % 60, tenths % 10)
    }

    static func pitch(_ p: Double) -> String {
        // Speed relative to 33⅓ rpm, sign ignored (direction has its own readout).
        abs(p) < 0.01 ? "Stopped" : String(format: "%+.2f%%", (abs(p) - 1) * 100)
    }

    static func db(_ level: Float) -> String {
        level < 0.0001 ? "−∞ dB" : String(format: "%.0f dB", 20 * log10(level))
    }
}

struct ZoomButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.readoutSm)
            .foregroundStyle(Theme.ink)
            .frame(width: 18, height: 18)
            .background(configuration.isPressed ? Theme.line : Theme.control)
    }
}

/// Laptop mode: play/pause, cue, sync, tempo and nudge for one deck.
struct LaptopTransport: View {
    @Bindable var deck: DeckModel
    let model: AppModel

    var body: some View {
        HStack(spacing: Theme.space2) {
            Button {
                model.setPlaying(!deck.transportPlaying, deck: deck)
            } label: {
                Image(systemName: deck.transportPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 34, height: 22)
                    .foregroundStyle(deck.transportPlaying ? Theme.onAccent : Theme.ink)
                    .background(deck.transportPlaying ? deck.color : Theme.control)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSm))
            }
            .buttonStyle(.plain)
            .disabled(deck.track == nil)
            Button("CUE") { model.cue(deck: deck) }
                .buttonStyle(FlatButtonStyle())
                .help("Back to cue 1 (IN), or the start, and stop")
            Button("SYNC") { model.sync(deck: deck) }
                .buttonStyle(FlatButtonStyle())
                .disabled(deck.track == nil || model.decks[1 - deck.id].track == nil)
                .help("Match the other deck's tempo and line up the beats")
            Divider().frame(height: 18)
            Button("‹") { model.scrub(deck: deck, by: -0.02) }.buttonStyle(FlatButtonStyle()).help("Nudge back 20 ms")
            Button("›") { model.scrub(deck: deck, by: 0.02) }.buttonStyle(FlatButtonStyle()).help("Nudge forward 20 ms")
            Divider().frame(height: 18)
            Text("TEMPO").font(Theme.label).foregroundStyle(Theme.inkMuted)
            Slider(value: Binding(get: { deck.tempo }, set: { model.setTempo($0, deck: deck) }),
                   in: -deck.tempoRange...deck.tempoRange)
                .frame(minWidth: 90)
            Text(String(format: "%+.2f%%", deck.tempo * 100))
                .font(Theme.readoutSm).foregroundStyle(Theme.ink).frame(width: 56, alignment: .trailing)
            Button("0") { model.setTempo(0, deck: deck) }.buttonStyle(FlatButtonStyle()).help("Back to the track's own tempo")
            Picker("", selection: $deck.tempoRange) {
                Text("±8").tag(0.08)
                Text("±16").tag(0.16)
                Text("±50").tag(0.5)
            }
            .frame(width: 64)
        }
        .tint(deck.color)
        .font(Theme.caption)
        .foregroundStyle(Theme.inkMuted)
        .padding(.horizontal, Theme.space3)
        .padding(.vertical, Theme.space2)
        .background(Theme.panelRaised)
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

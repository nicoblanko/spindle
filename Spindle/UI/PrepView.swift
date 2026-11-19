//
//  PrepView.swift
//  Spindle
//
//  Build step 3: Prep. Pick a track, check the suggested beatgrid, place
//  the four cues (1 IN, 2 DROP, 3 BRK, 4 OUT), save loops, set the clip's FX
//  and mark it mix-ready.
//

import SwiftUI

struct PrepView: View {
    @Bindable var library: LibraryModel
    let model: AppModel
    @Bindable var page: PrepPageModel

    var body: some View {
        HStack(spacing: 1) {
            CrateList(library: library, model: model)
                .frame(width: 200)
            SharedTrackList(model: model, library: library, key: "prep",
                            selection: Binding(get: { page.selected.map { [$0] } ?? [] },
                                               set: { if let url = $0.first { model.selectForPrep(url) } }),
                            onOpen: { model.selectForPrep($0.id) },
                            nameWidth: 220)
                .frame(width: 520)
            editor
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.line)
    }

    @ViewBuilder
    private var editor: some View {
        if let url = page.selected, let prep = model.prep.prep(for: url) {
            PrepEditor(url: url, prep: prep, model: model, page: page)
        } else {
            VStack(spacing: Theme.space2) {
                if page.loading { ProgressView().controlSize(.small) }
                Text(page.loading ? "Analysing…" : (page.error ?? "Select a track to prep it."))
                    .font(Theme.caption)
                    .foregroundStyle(Theme.inkFaint)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.panel)
        }
    }
}

/// Four small dots in the cue colours; hollow when the cue isn't set.
struct CueDots: View {
    let prep: TrackPrep?
    var body: some View {
        HStack(spacing: 3) {
            ForEach(CueRole.allCases) { role in
                let set = prep?.cue(role) != nil
                Circle()
                    .fill(set ? role.color : Color.clear)
                    .overlay(Circle().stroke(set ? role.color : Theme.inkFaint.opacity(0.6), lineWidth: 1))
                    .frame(width: 6, height: 6)
            }
        }
    }
}

private struct PrepEditor: View {
    let url: URL
    let prep: TrackPrep
    let model: AppModel
    @Bindable var page: PrepPageModel
    @State private var newLoopBeats = 16

    private var duration: Double {
        page.waveform.map { Double($0.peaks.count) / PrepSuggestion.peaksPerSecond }
            ?? model.analysis.analysis(for: url)?.duration ?? 300
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Theme.line).frame(height: 1)
            PrepWaveform(prep: prep, waveform: page.waveform, duration: duration, cursor: $page.cursor, zoom: page.zoom, overview: true)
                .frame(height: 44)
            Rectangle().fill(Theme.line).frame(height: 1)
            PrepWaveform(prep: prep, waveform: page.waveform, duration: duration, cursor: $page.cursor, zoom: page.zoom, overview: false)
                .frame(height: 200)
                .overlay(alignment: .topLeading) {
                    if page.loading {
                        Text("Loading waveform…").font(Theme.caption).foregroundStyle(Theme.inkFaint).padding(Theme.space2)
                    }
                }
            Rectangle().fill(Theme.line).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.space4) {
                    gridTools
                    cueTools
                    loopTools
                    fxTools
                }
                .padding(Theme.space3)
            }
        }
        .background(Theme.panel)
    }

    private func edit(_ change: (inout TrackPrep) -> Void) { model.prep.update(url, change) }

    private var header: some View {
        HStack(spacing: Theme.space3) {
            VStack(alignment: .leading, spacing: 2) {
                Text(url.deletingPathExtension().lastPathComponent).font(Theme.title).foregroundStyle(Theme.ink).lineLimit(1)
                HStack(spacing: Theme.space3) {
                    Text(String(format: "%.2f BPM", prep.bpm)).font(Theme.readoutSm)
                    if let a = model.analysis.analysis(for: url) {
                        Text("\(a.camelotNumber) \(KeyStyle.mood(minor: a.keyMinor))").font(Theme.readoutSm)
                        Text("E\(a.energy)").font(Theme.readoutSm)
                    }
                    Text("Cursor \(Self.clock(page.cursor)) · bar \(Int((prep.beatIndex(at: page.cursor) / 4).rounded(.down)) + 1)")
                        .font(Theme.readoutSm)
                }
                .foregroundStyle(Theme.inkMuted)
            }
            Spacer()
            Toggle("Mix-ready", isOn: Binding(get: { prep.mixReady }, set: { v in edit { $0.mixReady = v } }))
                .toggleStyle(.checkbox)
                .font(Theme.body)
                .foregroundStyle(Theme.ink)
            ForEach(model.decks) { deck in
                Button("Load \(deck.label)") { Task { await model.load(url: url, into: deck) } }
                    .buttonStyle(FlatButtonStyle())
            }
        }
        .padding(.horizontal, Theme.space3)
        .padding(.vertical, Theme.space2)
        .background(Theme.panelRaised)
    }

    private var gridTools: some View {
        VStack(alignment: .leading, spacing: Theme.space2) {
            LabelText("Beatgrid")
            HStack(spacing: Theme.space2) {
                Button("−1") { edit { $0.bpm -= 1 } }
                Button("−0.01") { edit { $0.bpm -= 0.01 } }
                Text(String(format: "%.2f", prep.bpm)).font(Theme.readout).foregroundStyle(Theme.ink).frame(width: 70)
                Button("+0.01") { edit { $0.bpm += 0.01 } }
                Button("+1") { edit { $0.bpm += 1 } }
                Button("÷2") { edit { $0.bpm /= 2 } }
                Button("×2") { edit { $0.bpm *= 2 } }
                Divider().frame(height: 18)
                Button("◀ Nudge") { edit { $0.gridOffset -= 0.005 } }
                Button("Nudge ▶") { edit { $0.gridOffset += 0.005 } }
                Button("Downbeat at cursor") {
                    let cursor = page.cursor
                    edit { p in
                        let bar = 4 * p.beatSeconds
                        p.gridOffset = cursor - (cursor / bar).rounded(.down) * bar
                    }
                }
                Spacer()
                Button("Suggest again") { model.resuggest(url) }
                    .help("Replaces the grid, cues and loops with a fresh suggestion. FX and mix-ready stay.")
            }
            .buttonStyle(FlatButtonStyle())
            Picker("Zoom", selection: $page.zoom) {
                Text("4 bars").tag(4 * 4 * prep.beatSeconds)
                Text("16 bars").tag(16 * 4 * prep.beatSeconds)
                Text("32 s").tag(32.0)
                Text("64 bars").tag(64 * 4 * prep.beatSeconds)
            }
            .pickerStyle(.segmented)
            .frame(width: 360)
        }
    }

    private var cueTools: some View {
        VStack(alignment: .leading, spacing: Theme.space2) {
            LabelText("Cues")
            HStack(spacing: Theme.space2) {
                ForEach(CueRole.allCases) { role in
                    cuePad(role)
                }
            }
        }
    }

    private func cuePad(_ role: CueRole) -> some View {
        let cue = prep.cue(role)
        return VStack(alignment: .leading, spacing: Theme.space1) {
            HStack {
                Text("\(role.rawValue) \(role.name)").font(Theme.label).foregroundStyle(role.color)
                Spacer()
                if cue?.auto == true { Text("auto").font(Theme.caption).foregroundStyle(Theme.inkFaint) }
            }
            Button {
                if let cue { page.cursor = cue.time }
            } label: {
                Text(cue.map { Self.clock($0.time) } ?? "—")
                    .font(Theme.readout)
                    .foregroundStyle(cue == nil ? Theme.inkFaint : Theme.ink)
            }
            .buttonStyle(.plain)
            .help("Move the cursor here")
            HStack(spacing: Theme.space1) {
                Button("Set") {
                    let t = prep.snap(page.cursor)
                    edit { $0.setCue(role, time: t) }
                }
                .help("Places the cue on the beat nearest the cursor")
                Button("Clear") { edit { $0.setCue(role, time: nil) } }
                    .disabled(cue == nil)
            }
            .buttonStyle(FlatButtonStyle())
        }
        .padding(Theme.space2)
        .frame(width: 150)
        .background(Theme.panelRaised)
        .overlay(alignment: .leading) { Rectangle().fill(role.color).frame(width: 3) }
    }

    private var loopTools: some View {
        VStack(alignment: .leading, spacing: Theme.space2) {
            LabelText("Loops")
            ForEach(prep.loops) { loop in
                HStack(spacing: Theme.space3) {
                    Text(Self.clock(loop.start)).font(Theme.readoutSm).foregroundStyle(Theme.ink)
                    Text("\(loop.beats) beats").font(Theme.readoutSm).foregroundStyle(Theme.inkMuted)
                    Button("Go") { page.cursor = loop.start }
                    Button("Remove") { edit { $0.loops.removeAll { $0.id == loop.id } } }
                    Spacer()
                }
                .buttonStyle(FlatButtonStyle())
            }
            HStack(spacing: Theme.space2) {
                Picker("", selection: $newLoopBeats) {
                    ForEach([4, 8, 16, 32], id: \.self) { Text("\($0) beats").tag($0) }
                }
                .frame(width: 110)
                Button("Add loop at cursor") {
                    let start = prep.snap(page.cursor)
                    let beats = newLoopBeats
                    edit { $0.loops.append(SavedLoop(start: start, beats: beats)); $0.loops.sort { $0.start < $1.start } }
                }
                .buttonStyle(FlatButtonStyle())
            }
        }
    }

    private var fxTools: some View {
        VStack(alignment: .leading, spacing: Theme.space2) {
            LabelText("Clip FX · applied when the clip is loaded")
            HStack(spacing: Theme.space3) {
                Text("Filter").font(Theme.caption).foregroundStyle(Theme.inkMuted).frame(width: 40, alignment: .leading)
                Slider(value: Binding(get: { prep.fx.filter }, set: { v in edit { $0.fx.filter = abs(v) < 0.03 ? 0 : v } }), in: -1...1)
                    .frame(width: 220)
                Text(prep.fx.filter < -0.01 ? "LP" : prep.fx.filter > 0.01 ? "HP" : "Off")
                    .font(Theme.readoutSm).foregroundStyle(Theme.inkMuted).frame(width: 30)
                Text("Echo").font(Theme.caption).foregroundStyle(Theme.inkMuted)
                Slider(value: Binding(get: { prep.fx.echo }, set: { v in edit { $0.fx.echo = v } }), in: 0...1)
                    .frame(width: 160)
                Button("Reset") { edit { $0.fx = ClipFX() } }.buttonStyle(FlatButtonStyle())
            }
        }
    }

    static func clock(_ s: Double) -> String {
        let tenths = Int((max(0, s) * 10).rounded())
        return String(format: "%d:%02d.%d", tenths / 600, tenths / 10 % 60, tenths % 10)
    }
}

/// The Prep waveform: the whole track (overview) or a zoomed lane around the
/// cursor with the beatgrid. Click or drag to move the cursor.
struct PrepWaveform: View {
    let prep: TrackPrep
    let waveform: PrepSuggestion?
    let duration: Double
    @Binding var cursor: Double
    let zoom: Double
    let overview: Bool
    @State private var dragStart: Double?

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in draw(context, size) }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    if overview {
                        cursor = clamp(Double(g.location.x / geo.size.width) * duration)
                    } else {
                        // Drag the waveform like a record; a click jumps there.
                        let perPoint = zoom / Double(geo.size.width)
                        if dragStart == nil { dragStart = cursor }
                        if abs(g.translation.width) < 2 {
                            cursor = clamp((dragStart ?? cursor) + Double(g.location.x - geo.size.width / 2) * perPoint)
                        } else {
                            cursor = clamp((dragStart ?? cursor) - Double(g.translation.width) * perPoint)
                        }
                    }
                }.onEnded { _ in dragStart = nil })
        }
        .background(Theme.panel)
    }

    private func clamp(_ t: Double) -> Double { min(max(0, t), duration) }

    private func draw(_ context: GraphicsContext, _ size: CGSize) {
        let start = overview ? 0 : cursor - zoom / 2
        let span = overview ? max(duration, 1) : zoom
        func x(_ t: Double) -> CGFloat { CGFloat((t - start) / span) * size.width }
        let mid = size.height / 2

        // Loops, shaded.
        for loop in prep.loops {
            let a = x(loop.start), b = x(loop.start + Double(loop.beats) * prep.beatSeconds)
            context.fill(Path(CGRect(x: a, y: 0, width: max(1, b - a), height: size.height)), with: .color(Theme.match.opacity(0.10)))
        }

        // Beatgrid (lane only): beats faint, bars stronger, 8-bar phrases strongest.
        if !overview {
            let beat = prep.beatSeconds
            var n = ((start - prep.gridOffset) / beat).rounded(.down)
            while prep.gridOffset + n * beat <= start + span {
                let t = prep.gridOffset + n * beat
                let i = Int(n)
                let phrase = i % 32 == 0, bar = i % 4 == 0
                let color = phrase ? Theme.inkMuted : bar ? Theme.line.opacity(1) : Theme.line.opacity(0.45)
                context.fill(Path(CGRect(x: x(t), y: 0, width: phrase ? 1.5 : 1, height: size.height)), with: .color(color))
                n += 1
            }
        }

        // Waveform: kick share tints it towards the ink colour.
        if let w = waveform, !w.peaks.isEmpty {
            let step: CGFloat = overview ? 2 : 1.5
            var col: CGFloat = 0
            var quiet = Path(), punchy = Path()
            while col < size.width {
                let t0 = start + Double(col / size.width) * span
                let t1 = start + Double((col + step) / size.width) * span
                let c0 = max(0, Int(t0 * PrepSuggestion.peaksPerSecond))
                let c1 = min(w.peaks.count, max(c0 + 1, Int(t1 * PrepSuggestion.peaksPerSecond)))
                if c0 < w.peaks.count && c1 > c0 {
                    var peak: Float = 0, low: Float = 0
                    for c in c0..<c1 { peak = max(peak, w.peaks[c]); low = max(low, w.lows[c]) }
                    let h = max(1, CGFloat(peak) * (mid - 3))
                    let rect = CGRect(x: col, y: mid - h, width: step - 0.4, height: h * 2)
                    if low > 0.5 { punchy.addRect(rect) } else { quiet.addRect(rect) }
                }
                col += step
            }
            context.fill(quiet, with: .color(Theme.inkFaint))
            context.fill(punchy, with: .color(Theme.inkMuted))
        }

        // Cues.
        for cue in prep.cues {
            let cx = x(cue.time)
            context.fill(Path(CGRect(x: cx - 1, y: 0, width: 2, height: size.height)), with: .color(cue.role.color))
            if !overview {
                let label = Text("\(cue.role.rawValue) \(cue.role.name)").font(Theme.label).foregroundStyle(Theme.onAccent)
                let resolved = context.resolve(label)
                let s = resolved.measure(in: size)
                context.fill(Path(CGRect(x: cx, y: 0, width: s.width + 8, height: s.height + 4)), with: .color(cue.role.color))
                context.draw(resolved, at: CGPoint(x: cx + 4, y: 2), anchor: .topLeading)
            } else {
                context.fill(Path(CGRect(x: cx - 1, y: 0, width: 6, height: 6)), with: .color(cue.role.color))
            }
        }

        // Cursor (overview: the zoomed window too).
        if overview {
            let a = x(cursor - zoom / 2), b = x(cursor + zoom / 2)
            context.stroke(Path(CGRect(x: a, y: 0.5, width: max(2, b - a), height: size.height - 1)), with: .color(Theme.accent.opacity(0.7)), lineWidth: 1)
        }
        context.fill(Path(CGRect(x: x(cursor) - 1, y: 0, width: 2, height: size.height)), with: .color(Theme.accent))
    }
}

//
//  PrepView.swift
//  Spindle
//
//  Build step 3: Prep, for preparing tracks at the computer. The selected
//  track sits on top: a pre-listen player with a metronome on the grid, the
//  whole-track overview, a zoomed lane that follows the playhead, and the
//  grid, cue, loop and FX tools. The track list is underneath. Almost
//  everything has a key (see `PrepKeys`).
//

import AppKit
import SwiftUI

struct PrepView: View {
    @Bindable var library: LibraryModel
    let model: AppModel
    @Bindable var page: PrepPageModel
    @State private var keys = PrepKeys()

    var body: some View {
        VStack(spacing: 1) {
            editor
                .frame(height: 490)
            HStack(spacing: 1) {
                CrateList(library: library, model: model)
                    .frame(width: 200)
                SharedTrackList(model: model, library: library, key: "prep",
                                selection: Binding(get: { page.selected.map { [$0] } ?? [] },
                                                   set: { if let url = $0.first { model.selectForPrep(url) } }),
                                onOpen: { model.selectForPrep($0.id) },
                                nameWidth: 320)
            }
            .frame(maxHeight: .infinity)
        }
        .background(Theme.line)
        .onAppear {
            keys.install(model)
            // Don't start with the cursor in the search field.
            DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) }
        }
        .onDisappear {
            keys.remove()
            model.prepSetPlaying(false)
        }
    }

    @ViewBuilder
    private var editor: some View {
        if let url = page.selected, let prep = model.prep.prep(for: url) {
            PrepEditor(url: url, prep: prep, model: model, page: page)
        } else {
            VStack(spacing: Theme.space2) {
                if page.loading { ProgressView().controlSize(.small) }
                Text(page.loading ? "Analysing…" : (page.error ?? "Select a track below to prep it."))
                    .font(Theme.caption)
                    .foregroundStyle(Theme.inkFaint)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.panel)
        }
    }
}

// MARK: - Keyboard

/// Prep's keys, active while the page is open and no text field has focus.
final class PrepKeys {
    private var monitor: Any?

    func install(_ model: AppModel) {
        remove()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak model] event in
            guard let model, Self.handle(event, model) else { return event }
            return nil
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit { remove() }

    static let help = "space play · 1–9 jump to cue · ⇧1–9 set cue · Q new cue · L new loop slot · ← → bar · ⇧← → beat · ↑ ↓ track · D bar 1 here · [ ] nudge grid · C click · M mix-ready"
    /// Key codes of the number keys 1–9.
    static let numberKeys: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]

    private static func handle(_ event: NSEvent, _ model: AppModel) -> Bool {
        // Typing in a field (search, notes, rename) keeps its keys, except
        // space in an empty field and Escape, which hand the keys back.
        if let text = event.window?.firstResponder as? NSText {
            if event.keyCode == 53 || (event.keyCode == 49 && text.string.isEmpty) {
                event.window?.makeFirstResponder(nil)
                if event.keyCode == 49 { model.prepTogglePlay() }
                return true
            }
            return false
        }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if flags.contains(.command) || flags.contains(.control) || flags.contains(.option) { return false }
        let shift = flags.contains(.shift)
        let page = model.prepPage

        switch event.keyCode {
        case 49: model.prepTogglePlay()
        case 123: model.prepStep(beats: shift ? -1 : -4)
        case 124: model.prepStep(beats: shift ? 1 : 4)
        case 126, 125:
            model.prepStepTrack(event.keyCode == 126 ? -1 : 1, in: model.pageRecords("prep").map(\.id))
        case 33: model.prepEdit { $0.gridOffset -= 0.005 }
        case 30: model.prepEdit { $0.gridOffset += 0.005 }
        default:
            if let n = numberKeys.firstIndex(of: event.keyCode) {
                if shift { model.prepSetCue(slot: n) } else { model.prepJump(cue: n) }
                return true
            }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "d": model.prepDownbeatHere()
            case "c": model.prepSetMetronome(!page.metronome)
            case "m": model.prepEdit { $0.mixReady.toggle() }
            case "q": model.prepAddCue()
            case "l": model.prepAddLoop()
            default: return false
            }
        }
        return true
    }
}

// MARK: - Editor

private struct PrepEditor: View {
    let url: URL
    let prep: TrackPrep
    let model: AppModel
    @Bindable var page: PrepPageModel
    @State private var editingCue: UUID?

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.line).frame(height: 1)
            PrepOverview(model: model, page: page, prep: prep)
                .frame(height: 48)
            Rectangle().fill(Theme.line).frame(height: 1)
            PrepLane(model: model, page: page, prep: prep)
                .frame(maxHeight: .infinity)
                .overlay(alignment: .topLeading) {
                    if page.preview == nil {
                        Text("Loading audio…").font(Theme.caption).foregroundStyle(Theme.inkFaint)
                            .padding(.horizontal, Theme.space2).padding(.top, 22)
                    }
                }
            Rectangle().fill(Theme.line).frame(height: 1)
            tools
                .frame(height: 128)
        }
        .background(Theme.panel)
    }

    // MARK: Header: transport, readouts, track

    private var header: some View {
        HStack(spacing: Theme.space3) {
            Button { model.prepTogglePlay() } label: {
                Image(systemName: page.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 14))
                    .frame(width: 34, height: 28)
                    .foregroundStyle(page.playing ? Theme.onAccent : Theme.ink)
                    .background(page.playing ? Theme.accent : Theme.control)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMd))
            }
            .buttonStyle(.plain)
            .disabled(page.preview == nil)
            .help("Play / pause (space)")

            TimelineView(.animation(minimumInterval: 1 / 20, paused: !page.playing)) { _ in
                let t = model.prepPosition
                let beat = prep.beatIndex(at: t)
                let whole = Int(beat.rounded(.down))
                let bar = Int((Double(whole) / 4).rounded(.down)) + 1
                let inBar = ((whole % 4) + 4) % 4 + 1
                HStack(spacing: Theme.space3) {
                    Text("\(Self.clock(t)) / \(Self.clock(model.prepDuration))")
                        .font(Theme.readout).foregroundStyle(Theme.ink)
                    Text("bar \(bar).\(inBar)")
                        .font(Theme.readout).foregroundStyle(Theme.inkMuted)
                        .frame(width: 90, alignment: .leading)
                }
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(url.deletingPathExtension().lastPathComponent)
                    .font(Theme.title).foregroundStyle(Theme.ink).lineLimit(1)
                HStack(spacing: Theme.space3) {
                    if let a = model.analysis.analysis(for: url) {
                        Text("\(a.camelotNumber) \(KeyStyle.mood(minor: a.keyMinor))")
                        Text("E\(a.energy)")
                    }
                }
                .font(Theme.readoutSm).foregroundStyle(Theme.inkMuted)
            }
            .frame(minWidth: 120, alignment: .leading)

            Spacer(minLength: Theme.space2)

            HStack(spacing: 4) {
                Text(String(format: "%.2f", prep.bpm)).font(Theme.readout).foregroundStyle(Theme.ink)
                Text("BPM").font(Theme.caption).foregroundStyle(Theme.inkMuted)
            }

            Button { model.prepSetMetronome(!page.metronome) } label: {
                Label("Click", systemImage: "metronome")
                    .font(Theme.body)
                    .padding(.horizontal, Theme.space2).frame(height: 24)
                    .foregroundStyle(page.metronome ? Theme.onAccent : Theme.ink)
                    .background(page.metronome ? Theme.ink : Theme.control)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMd))
            }
            .buttonStyle(.plain)
            .help("Metronome on the beatgrid (C): if it drifts from the kick, fix the BPM; if it's early or late, nudge.")

            HStack(spacing: 4) {
                Image(systemName: "speaker.wave.2").font(.system(size: 11)).foregroundStyle(Theme.inkMuted)
                Slider(value: Binding(get: { page.volume }, set: { model.prepSetVolume($0) }), in: 0...1)
                    .frame(width: 80)
            }
            .help("Pre-listen volume")

            if let engine = model.engine, engine.device.outputChannels >= 4 {
                Picker("", selection: Binding(get: { engine.previewOutput }, set: { model.prepSetOutput($0) })) {
                    ForEach(Array(stride(from: 0, to: engine.device.outputChannels - 1, by: 2)), id: \.self) { first in
                        Text("Out \(first + 1)–\(first + 2)").tag(first)
                    }
                }
                .frame(width: 96)
                .help("Where the pre-listen plays. It is never recorded.")
            }

            Rectangle().fill(Theme.line).frame(width: 1, height: 22)

            Toggle("Mix-ready", isOn: Binding(get: { prep.mixReady }, set: { v in model.prepEdit { $0.mixReady = v } }))
                .toggleStyle(.checkbox)
                .font(Theme.body)
                .foregroundStyle(Theme.ink)
                .help("M")
            ForEach(model.decks) { deck in
                Button("Load \(deck.label)") { Task { await model.load(url: url, into: deck) } }
                    .buttonStyle(FlatButtonStyle())
            }
        }
        .padding(.horizontal, Theme.space3)
        .frame(height: 50)
        .background(Theme.panelRaised)
    }

    // MARK: Tools strip

    private var tools: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 1) {
                cueTools
                    .frame(maxWidth: .infinity)
                gridTools
                    .frame(width: 286)
                loopTools
                    .frame(width: 440)
            }
            .background(Theme.line)
            .frame(maxHeight: .infinity)
            Rectangle().fill(Theme.line).frame(height: 1)
            Text(PrepKeys.help)
                .font(Theme.caption).foregroundStyle(Theme.inkFaint)
                .lineLimit(1)
                .padding(.horizontal, Theme.space3)
                .frame(height: 22, alignment: .leading)
        }
    }

    private func section<Trailing: View, Content: View>(_ title: String, @ViewBuilder trailing: () -> Trailing,
                                                         @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.space2) {
            HStack(spacing: Theme.space2) {
                LabelText(title)
                Spacer(minLength: 0)
                trailing()
            }
            content()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.space3).padding(.top, Theme.space2).padding(.bottom, Theme.space2)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.panel)
    }

    // Cues: as many as you like, each with a name and colour. Its number is
    // its place in the row (the number keys and pads use it).

    private var cueTools: some View {
        section("Cues") {
            Button { model.prepAddCue() } label: { Label("Cue", systemImage: "plus") }
                .buttonStyle(SmallButtonStyle())
                .help("New cue on the beat at the playhead (Q)")
        } content: {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.space2) {
                    ForEach(Array(prep.cues.enumerated()), id: \.element.id) { n, cue in cueCard(n, cue) }
                    if prep.cues.isEmpty {
                        Text("No cues yet. Play to a spot and press Q.")
                            .font(Theme.caption).foregroundStyle(Theme.inkFaint)
                    }
                }
            }
        }
    }

    private func cueCard(_ n: Int, _ cue: Cue) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text("\(n + 1)").font(Theme.readoutSm).foregroundStyle(Theme.inkMuted)
                Text(cue.name).font(Theme.label).foregroundStyle(cue.swatch).lineLimit(1)
                Spacer(minLength: 0)
            }
            Text(Self.clock(cue.time))
                .font(Theme.readout)
                .foregroundStyle(Theme.ink)
        }
        .padding(.vertical, 6).padding(.leading, 9).padding(.trailing, 6)
        .frame(width: 104, alignment: .leading)
        .background(Theme.panelRaised)
        .overlay(alignment: .leading) { Rectangle().fill(cue.swatch).frame(width: 3) }
        .contentShape(Rectangle())
        .onTapGesture { model.prepJump(cue: n) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { editingCue = cue.id })
        .help("Click to jump (\(n + 1)) · double-click to edit · ⇧\(n + 1) moves it to the playhead")
        .contextMenu {
            Button("Edit…") { editingCue = cue.id }
            Button("Move to playhead") { model.prepSetCue(slot: n) }
            Divider()
            Button("Delete", role: .destructive) { model.prepEdit { $0.cues.removeAll { $0.id == cue.id } } }
        }
        .popover(isPresented: Binding(get: { editingCue == cue.id }, set: { if !$0 { editingCue = nil } })) {
            CueEditor(cue: cue, number: n + 1,
                      onChange: { new in model.prepEdit { p in if let i = p.cues.firstIndex(where: { $0.id == cue.id }) { p.cues[i] = new } } },
                      onMove: { d in model.prepEdit { p in
                          guard let i = p.cues.firstIndex(where: { $0.id == cue.id }), p.cues.indices.contains(i + d) else { return }
                          p.cues.swapAt(i, i + d) } },
                      onDelete: { editingCue = nil; model.prepEdit { $0.cues.removeAll { $0.id == cue.id } } })
        }
    }

    // Loop slots: an in-point and a length in bars. They travel to the Mix
    // page, where each deck has them as small buttons.

    private var loopTools: some View {
        section("Loop slots") {
            Button { model.prepAddLoop() } label: { Label("Loop", systemImage: "plus") }
                .buttonStyle(SmallButtonStyle())
                .help("New 4-bar loop slot on the beat at the playhead (L)")
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(prep.loops.enumerated()), id: \.element.id) { n, loop in loopRow(n, loop) }
                    if prep.loops.isEmpty {
                        Text("No loop slots yet. Play to a spot and press L.")
                            .font(Theme.caption).foregroundStyle(Theme.inkFaint)
                    }
                }
            }
        }
    }

    private func loopRow(_ n: Int, _ loop: SavedLoop) -> some View {
        let active = page.activeLoop == loop.id
        return HStack(spacing: 6) {
            Button { model.prepAudition(loop.id) } label: {
                Text("\(n + 1)")
                    .font(Theme.readoutSm)
                    .frame(width: 22, height: 20)
                    .foregroundStyle(active ? Theme.onAccent : Theme.ink)
                    .background(active ? Theme.match : Theme.control)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSm))
            }
            .buttonStyle(.plain)
            .help(active ? "Stop looping" : "Loop it in the player")
            Button { model.prepSetLoopIn(loop.id) } label: {
                Text(Self.clock(loop.start)).font(Theme.readoutSm).foregroundStyle(Theme.ink)
                    .frame(width: 54, alignment: .leading)
            }
            .buttonStyle(.plain)
            .help("Set the in-point to the beat at the playhead")
            HStack(spacing: 1) {
                ForEach(SavedLoop.barChoices, id: \.self) { bars in
                    let on = abs(loop.bars - bars) < 0.01
                    Button { model.prepSetLoopBars(loop.id, bars) } label: {
                        Text(SavedLoop.barLabel(bars))
                            .font(Theme.readoutSm)
                            .frame(width: 24, height: 20)
                            .foregroundStyle(on ? Theme.onAccent : Theme.inkMuted)
                            .background(on ? Theme.ink : Theme.control)
                    }
                    .buttonStyle(.plain)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSm))
            .help("Length in bars")
            Spacer(minLength: 0)
            Button { model.prepRemoveLoop(loop.id) } label: { Image(systemName: "xmark") }
                .buttonStyle(SmallButtonStyle())
        }
    }

    // The beatgrid: Spindle snaps cues and loops to it, counts bars with it
    // and syncs with it. Turn on Click to check it by ear.

    private var gridTools: some View {
        section("Beatgrid") {
            Button("Detect again") { model.resuggest(url) }
                .buttonStyle(SmallButtonStyle())
                .help("Replaces the grid, cues and loop slots with a fresh suggestion. FX and mix-ready stay.")
        } content: {
            HStack(spacing: 3) {
                Button("−") { model.prepEdit { $0.bpm -= 0.01 } }.help("−0.01 BPM")
                Text(String(format: "%.2f", prep.bpm)).font(Theme.readout).foregroundStyle(Theme.ink).frame(width: 62)
                Button("+") { model.prepEdit { $0.bpm += 0.01 } }.help("+0.01 BPM")
                Button("−1") { model.prepEdit { $0.bpm -= 1 } }
                Button("+1") { model.prepEdit { $0.bpm += 1 } }
                Button("÷2") { model.prepEdit { $0.bpm /= 2 } }
                Button("×2") { model.prepEdit { $0.bpm *= 2 } }
            }
            HStack(spacing: 3) {
                Button { model.prepEdit { $0.gridOffset -= 0.005 } } label: { Image(systemName: "chevron.left") }
                    .help("Grid earlier ([)")
                Button { model.prepEdit { $0.gridOffset += 0.005 } } label: { Image(systemName: "chevron.right") }
                    .help("Grid later (])")
                Button("Bar 1 here") { model.prepDownbeatHere() }
                    .help("The bar starts on the playhead (D)")
            }
        }
        .buttonStyle(SmallButtonStyle())
    }

    static func clock(_ s: Double) -> String {
        let tenths = Int((max(0, s) * 10).rounded())
        return String(format: "%d:%02d.%d", tenths / 600, tenths / 10 % 60, tenths % 10)
    }
}

/// A compact flat button for the tool strip.
struct SmallButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.caption)
            .padding(.horizontal, 7)
            .frame(minHeight: 20)
            .foregroundStyle(enabled ? Theme.ink : Theme.inkFaint)
            .background(configuration.isPressed ? Theme.line : Theme.control)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSm))
    }
}

// MARK: - Waveforms

/// Draws one waveform column range as two layers: peaks (outline) and
/// loudness (solid core). Columns are fixed to the track's timeline, so they
/// keep their shape as the view moves.
private func drawWave(_ context: GraphicsContext, track: LoadedTrack, start: Double, span: Double,
                      size: CGSize, top: CGFloat, height: CGFloat, playhead: Double, columnPoints: CGFloat) {
    let peaks = track.peaks, rms = track.rms
    guard !peaks.isEmpty, span > 0 else { return }
    let rate = LoadedTrack.peaksPerSecond
    let secondsPerPoint = span / Double(size.width)
    let bins = max(1, Int((Double(columnPoints) * secondsPerPoint * rate).rounded()))
    let columnSeconds = Double(bins) / rate
    let columnWidth = CGFloat(columnSeconds / secondsPerPoint)
    let first = max(0, Int((start / columnSeconds).rounded(.down)))
    let last = Int(((start + span) / columnSeconds).rounded(.up))
    let mid = top + height / 2
    let half = height / 2 - 1
    var outerPlayed = Path(), innerPlayed = Path(), outerAhead = Path(), innerAhead = Path()
    for column in first...max(first, last) {
        let b0 = column * bins
        guard b0 < peaks.count else { break }
        let b1 = min(peaks.count, b0 + bins)
        var peak: Float = 0, loud: Float = 0
        for b in b0..<b1 { peak = max(peak, peaks[b]); loud += rms[b] }
        loud /= Float(b1 - b0)          // average loudness: the body, not the spikes
        let t = Double(column) * columnSeconds
        let x = CGFloat((t - start) / secondsPerPoint)
        let w = max(columnWidth - (columnWidth > 2 ? 0.6 : 0), 0.8)
        let hp = max(0.5, CGFloat(peak) * half)
        let hr = max(0.5, CGFloat(min(loud, peak)) * half)
        let outer = CGRect(x: x, y: mid - hp, width: w, height: hp * 2)
        let inner = CGRect(x: x, y: mid - hr, width: w, height: hr * 2)
        if t + columnSeconds <= playhead { outerPlayed.addRect(outer); innerPlayed.addRect(inner) }
        else { outerAhead.addRect(outer); innerAhead.addRect(inner) }
    }
    context.fill(outerPlayed, with: .color(Theme.waveLow.opacity(0.45)))
    context.fill(innerPlayed, with: .color(Theme.waveMid.opacity(0.45)))
    context.fill(outerAhead, with: .color(Theme.waveLow))
    context.fill(innerAhead, with: .color(Theme.waveMid))
}

/// The whole track: click or drag anywhere to go there.
private struct PrepOverview: View {
    let model: AppModel
    @Bindable var page: PrepPageModel
    let prep: TrackPrep

    var body: some View {
        let duration = max(model.prepDuration, 1)
        ZStack {
            // The waveform only changes with the track: draw it once.
            Canvas { context, size in
                for loop in prep.loops {
                    let a = CGFloat(loop.start / duration) * size.width
                    let b = CGFloat((loop.start + Double(loop.beats) * prep.beatSeconds) / duration) * size.width
                    context.fill(Path(CGRect(x: a, y: 0, width: max(1, b - a), height: size.height)), with: .color(Theme.match.opacity(0.12)))
                }
                if let track = page.preview {
                    drawWave(context, track: track, start: 0, span: duration, size: size,
                             top: 4, height: size.height - 8, playhead: 0, columnPoints: 2)
                }
                for cue in prep.cues {
                    let x = CGFloat(cue.time / duration) * size.width
                    context.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: size.height)), with: .color(cue.swatch))
                    context.fill(Path(CGRect(x: x - 1, y: 0, width: 8, height: 7)), with: .color(cue.swatch))
                }
            }
            // Played part, visible window and playhead move.
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !page.playing)) { _ in
                let t = model.prepPosition
                Canvas { context, size in
                    let x = CGFloat(t / duration) * size.width
                    context.fill(Path(CGRect(x: 0, y: 0, width: max(0, x), height: size.height)), with: .color(Theme.bg.opacity(0.45)))
                    let a = CGFloat((t - page.zoom / 2) / duration) * size.width
                    let w = CGFloat(page.zoom / duration) * size.width
                    context.stroke(Path(CGRect(x: a, y: 0.5, width: max(2, w), height: size.height - 1)),
                                   with: .color(Theme.ink.opacity(0.35)), lineWidth: 1)
                    context.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: size.height)), with: .color(Theme.accent))
                }
            }
            WaveformInteraction(onScroll: { model.prepSeek(by: Double($0) * duration / 1000) },
                                onClick: { model.prepSeek(to: Double($0) * duration) },
                                dragsAbsolutely: true)
        }
        .background(Theme.panel)
    }
}

/// The zoomed lane: playhead fixed in the centre, bar ruler on top, cues
/// and loops on the grid. Scroll or drag to move, click to jump, pinch or
/// ⌘-scroll to zoom.
private struct PrepLane: View {
    let model: AppModel
    @Bindable var page: PrepPageModel
    let prep: TrackPrep
    static let ruler: CGFloat = 18

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                TimelineView(.animation(paused: !page.playing)) { _ in
                    let t = model.prepPosition
                    Canvas { context, size in draw(context, size, playhead: t) }
                }
                WaveformInteraction(
                    onScroll: { model.prepSeek(by: Double($0) * page.zoom / Double(max(geo.size.width, 1))) },
                    onClick: { f in model.prepSeek(to: model.prepPosition + (Double(f) - 0.5) * page.zoom) },
                    onZoom: { f in page.zoom = min(max(page.zoom / Double(f), 2), 120) })
                zoomButtons
                    .padding(Theme.space2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
        .background(Theme.panel)
    }

    private var zoomButtons: some View {
        HStack(spacing: 2) {
            ForEach([(1, "1"), (4, "4"), (16, "16"), (64, "64")], id: \.0) { bars, label in
                let seconds = Double(bars) * 4 * prep.beatSeconds
                Button(label) { page.zoom = min(max(seconds, 2), 240) }
                    .buttonStyle(SmallButtonStyle())
                    .opacity(abs(page.zoom - seconds) < 0.01 ? 1 : 0.7)
            }
            Text("bars").font(Theme.caption).foregroundStyle(Theme.inkFaint).padding(.leading, 2)
        }
    }

    private func draw(_ context: GraphicsContext, _ size: CGSize, playhead: Double) {
        let span = page.zoom
        let start = playhead - span / 2
        let secondsPerPoint = span / Double(size.width)
        func x(_ t: Double) -> CGFloat { CGFloat((t - start) / secondsPerPoint) }
        let ruler = Self.ruler
        let laneTop = ruler
        let laneHeight = size.height - ruler

        context.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: ruler)), with: .color(Theme.panelRaised))

        // Loops.
        for loop in prep.loops {
            let a = x(loop.start), b = x(loop.start + Double(loop.beats) * prep.beatSeconds)
            guard b > 0, a < size.width else { continue }
            context.fill(Path(CGRect(x: a, y: laneTop, width: max(1, b - a), height: laneHeight)), with: .color(Theme.match.opacity(0.10)))
            context.fill(Path(CGRect(x: a, y: laneTop, width: max(1, b - a), height: 3)), with: .color(Theme.match.opacity(0.7)))
        }

        // Beatgrid: beats faint, bars stronger, 8-bar phrases strongest; bar
        // numbers in the ruler, thinned out when zoomed far out.
        let beat = prep.beatSeconds
        let beatPoints = beat / secondsPerPoint
        let barPoints = beatPoints * 4
        var labelEvery = 1
        while Double(labelEvery) * barPoints < 34 { labelEvery *= 2 }
        var beats = Path(), bars = Path(), phrases = Path()
        var n = ((start - prep.gridOffset) / beat).rounded(.down)
        while prep.gridOffset + n * beat <= start + span {
            let t = prep.gridOffset + n * beat
            let i = Int(n)
            let px = x(t)
            if i % 32 == 0 {
                phrases.addRect(CGRect(x: px, y: 0, width: 1.5, height: size.height))
            } else if i % 4 == 0 {
                bars.addRect(CGRect(x: px, y: 0, width: 1, height: size.height))
            } else if beatPoints > 6 {
                beats.addRect(CGRect(x: px, y: laneTop, width: 1, height: laneHeight))
            }
            if i % 4 == 0 {
                let bar = i / 4 + (i >= 0 ? 1 : 0)
                if bar % labelEvery == 0 || labelEvery == 1 {
                    context.draw(Text("\(bar)").font(Theme.readoutSm).foregroundStyle(i % 32 == 0 ? Theme.ink : Theme.inkMuted),
                                 at: CGPoint(x: px + 3, y: ruler / 2), anchor: .leading)
                }
            }
            n += 1
        }
        context.fill(beats, with: .color(Theme.line.opacity(0.5)))
        context.fill(bars, with: .color(Theme.line))
        context.fill(phrases, with: .color(Theme.inkFaint))

        // Waveform.
        if let track = page.preview {
            drawWave(context, track: track, start: start, span: span, size: size,
                     top: laneTop + 4, height: laneHeight - 8, playhead: playhead, columnPoints: 2)
        } else if let w = page.waveform {
            // The quick analysis waveform until the audio is decoded.
            var path = Path()
            var col: CGFloat = 0
            let mid = laneTop + laneHeight / 2
            while col < size.width {
                let c = Int((start + Double(col) * secondsPerPoint) * PrepSuggestion.peaksPerSecond)
                if c >= 0 && c < w.peaks.count {
                    let h = max(0.5, CGFloat(w.peaks[c]) * (laneHeight / 2 - 4))
                    path.addRect(CGRect(x: col, y: mid - h, width: 1.4, height: h * 2))
                }
                col += 2
            }
            context.fill(path, with: .color(Theme.waveLow.opacity(0.6)))
        }

        // Cues: a line and a flag with the role.
        for (n, cue) in prep.cues.enumerated() {
            let cx = x(cue.time)
            guard cx > -80, cx < size.width + 2 else { continue }
            context.fill(Path(CGRect(x: cx - 1, y: laneTop, width: 2, height: laneHeight)), with: .color(cue.swatch))
            let label = context.resolve(Text("\(n + 1) \(cue.name)").font(Theme.label).foregroundStyle(Theme.onAccent))
            let s = label.measure(in: size)
            context.fill(Path(CGRect(x: cx - 1, y: laneTop, width: s.width + 9, height: s.height + 4)), with: .color(cue.swatch))
            context.draw(label, at: CGPoint(x: cx + 4, y: laneTop + 2), anchor: .topLeading)
        }

        // Playhead.
        context.fill(Path(CGRect(x: size.width / 2 - 1, y: 0, width: 2, height: size.height)), with: .color(Theme.accent))
    }
}

/// Name, colour and order of one cue.
private struct CueEditor: View {
    let cue: Cue
    let number: Int
    let onChange: (Cue) -> Void
    let onMove: (Int) -> Void
    let onDelete: () -> Void
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.space3) {
            HStack {
                Text("Cue \(number)").font(Theme.label).foregroundStyle(Theme.inkMuted)
                Spacer()
                Button { onMove(-1) } label: { Image(systemName: "chevron.left") }.help("Earlier slot")
                Button { onMove(1) } label: { Image(systemName: "chevron.right") }.help("Later slot")
            }
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { commitName() }
                .onChange(of: name) { commitName() }
            HStack(spacing: 6) {
                ForEach(Cue.palette.indices, id: \.self) { i in
                    Button { var c = cue; c.color = i; onChange(c) } label: {
                        RoundedRectangle(cornerRadius: Theme.radiusSm)
                            .fill(Cue.palette[i])
                            .frame(width: 22, height: 22)
                            .overlay(RoundedRectangle(cornerRadius: Theme.radiusSm)
                                .stroke(cue.color == i ? Theme.ink : Color.clear, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                ForEach(["IN", "DROP", "BRK", "BUILD", "VOX", "OUT"], id: \.self) { preset in
                    Button(preset) { name = preset }
                }
                Spacer()
            }
            Button("Delete cue", role: .destructive) { onDelete() }
        }
        .buttonStyle(SmallButtonStyle())
        .padding(Theme.space3)
        .frame(width: 280)
        .onAppear { name = cue.name }
    }

    private func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != cue.name else { return }
        var c = cue
        c.name = String(trimmed.prefix(12)).uppercased()
        onChange(c)
    }
}

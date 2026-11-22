//
//  MixView.swift
//  Spindle
//
//  Build step 4: Mix. The clip grid sits above the two timecode decks, like
//  Ableton's session view: one column per crate, one clip per track. Clips
//  that would mix with a playing deck (key and tempo) are outlined in that
//  deck's colour. Each clip shows its cues and FX. Click a clip to select it,
//  double-click (or press A / B) to load it.
//

import SwiftUI

struct MixView: View {
    let model: AppModel
    @Bindable var library: LibraryModel
    @AppStorage("mix.dimUnfit") private var dimUnfit = true
    @State private var keys = MixKeys()

    /// Fits a playing deck: compatible key and tempo within 6% (half and
    /// double time count). With nothing playing, everything fits.
    private func fits(_ url: URL) -> Bool {
        let playing = model.decks.filter { $0.playing && $0.track != nil && $0.track?.url != url }
        guard !playing.isEmpty, let clip = model.analysis.analysis(for: url) else { return true }
        let bpm = model.bpm(of: url) ?? clip.bpm
        return playing.contains { deck in
            guard let a = model.analysis.analysis(for: deck.track!.url), let live = model.liveBPM(deck) else { return false }
            return Compatibility.keys(a, clip) && Compatibility.tempo(live, bpm, tolerance: 0.06)
        }
    }

    var body: some View {
        page
            .onAppear {
                keys.install(model)
                DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) }
            }
            .onDisappear { keys.remove(); model.prepSetPlaying(false) }
    }

    private var page: some View {
        VStack(spacing: 0) {
            HStack(spacing: 1) {
                CrateList(library: library, model: model)
                    .frame(width: 200)
                VStack(spacing: 0) {
                    SharedTrackList(model: model, library: library, key: "mix",
                                    selection: Binding(get: { model.mixSelection }, set: { model.mixSelection = $0 }),
                                    dimmed: dimUnfit ? { !fits($0.id) } : nil,
                                    played: { model.playedURLs.contains($0.id) },
                                    leading: { AnyView(RowControls(model: model, url: $0.id)) },
                                    leadingWidth: 78,
                                    listen: { AnyView(ListenCell(model: model, url: $0.track.url)) },
                                    follow: keys.follow,
                                    trailing: AnyView(HStack(spacing: Theme.space2) {
                                        if !model.playedURLs.isEmpty {
                                            Image(systemName: "checkmark.circle.fill").font(.system(size: 10)).foregroundStyle(Theme.inkMuted)
                                            Text("Played \(model.playedURLs.count)").font(Theme.caption).foregroundStyle(Theme.inkMuted)
                                            Button("Reset") { model.resetPlayed() }
                                                .buttonStyle(SmallButtonStyle())
                                                .help("Start a fresh played list, e.g. for a new set")
                                        }
                                        Toggle("Dim what doesn't fit", isOn: $dimUnfit)
                                            .toggleStyle(.checkbox)
                                            .font(Theme.caption)
                                            .foregroundStyle(Theme.inkMuted)
                                            .help("Grey out tracks whose key or tempo doesn't fit a playing deck")
                                    }))
                }
            }
            .background(Theme.line)
            .frame(maxHeight: .infinity)
            Rectangle().fill(Theme.line).frame(height: 1)
            HStack(spacing: 1) {
                ForEach(model.decks) { deck in
                    VStack(spacing: 0) {
                        DeckPanel(deck: deck, model: model, compact: true)
                        DeckPerformance(deck: deck, model: model)
                    }
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { keys.hovered = deck.id } else if keys.hovered == deck.id { keys.hovered = nil }
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .background(Theme.line)
            if model.laptop {
                Rectangle().fill(Theme.line).frame(height: 1)
                LaptopMixer(model: model)
            }
        }
    }
}

/// Laptop mode's mixer: a volume fader per deck and the crossfader.
private struct LaptopMixer: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: Theme.space3) {
            fader(model.decks[0])
            Spacer()
            Text("A").font(Theme.label).foregroundStyle(Theme.deckA)
            Slider(value: Binding(get: { model.crossfader }, set: { model.setCrossfader(abs($0) < 0.04 ? 0 : $0) }), in: -1...1)
                .frame(width: 260)
                .tint(Theme.inkMuted)
            Text("B").font(Theme.label).foregroundStyle(Theme.deckB)
            Button("Centre") { model.setCrossfader(0) }.buttonStyle(FlatButtonStyle())
            Spacer()
            fader(model.decks[1])
        }
        .padding(.horizontal, Theme.space3)
        .padding(.vertical, Theme.space2)
        .background(Theme.panelRaised)
    }

    private func fader(_ deck: DeckModel) -> some View {
        HStack(spacing: Theme.space2) {
            Text("VOL \(deck.label)").font(Theme.label).foregroundStyle(deck.color).fixedSize()
            Slider(value: Binding(get: { deck.volume }, set: { model.setVolume($0, deck: deck) }), in: 0...1)
                .frame(width: 160)
                .tint(deck.color)
            Text(String(format: "%3.0f", deck.volume * 100)).font(Theme.readoutSm).foregroundStyle(Theme.inkMuted).frame(width: 28)
        }
    }
}

// MARK: Row controls

/// At the start of each Mix row: played (ticks itself after 20 s of play,
/// or click it) and A / B to load the track, lit in the deck's colour while
/// it's on that deck.
private struct RowControls: View {
    let model: AppModel
    let url: URL

    var body: some View {
        let played = model.playedURLs.contains(url)
        HStack(spacing: 4) {
            Button { model.togglePlayed(url) } label: {
                Image(systemName: played ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13))
                    .foregroundStyle(played ? Theme.ink : Theme.inkFaint)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help(played ? "Played · click to untick" : "Not played yet · click to tick")
            ForEach(model.decks) { deck in
                let on = deck.track?.url == url
                Button { Task { await model.load(url: url, into: deck) } } label: {
                    Text(deck.label)
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 20, height: 18)
                        .foregroundStyle(on ? Theme.onAccent : deck.color)
                        .background(on ? deck.color : Theme.control)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSm))
                }
                .buttonStyle(.plain)
                .help(on ? "On deck \(deck.label)" : "Load on deck \(deck.label)")
            }
        }
        .padding(.leading, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Deck performance strip

/// Cue pads, loop slots and FX under each deck on the Mix page: the
/// compact version of what you set up on Prep.
private struct DeckPerformance: View {
    @Bindable var deck: DeckModel
    let model: AppModel

    var body: some View {
        let prep = deck.track.flatMap { model.prep.prep(for: $0.url) }
        HStack(spacing: Theme.space2) {
            // Cues: the first eight.
            group("Cues") { HStack(spacing: 3) {
                let cues = Array((prep?.cues ?? []).prefix(8))
                ForEach(Array(cues.enumerated()), id: \.element.id) { n, cue in
                    Button { model.jump(deck: deck, toCue: n) } label: {
                        Text("\(n + 1)")
                            .font(Theme.label)
                            .foregroundStyle(Theme.onAccent)
                            .frame(width: 24, height: 22)
                            .background(cue.swatch)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSm))
                    }
                    .buttonStyle(.plain)
                    .help("\(cue.name) · \(PrepEditorClock.clock(cue.time))")
                }
                if cues.isEmpty {
                    Text("None").font(Theme.caption).foregroundStyle(Theme.inkFaint).frame(height: 22)
                }
            } }
            Divider().frame(height: 30)
            // Free loop: on/off and its length.
            group("Loop") {
                HStack(spacing: 2) {
                    let on = deck.loopActive && deck.activeSlot == nil
                    Button { model.setLoop(!on, deck: deck) } label: {
                        Image(systemName: "repeat")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(on ? Theme.onAccent : Theme.ink)
                            .frame(width: 28, height: 22)
                            .background(on ? deck.color : Theme.control)
                    }
                    .buttonStyle(.plain)
                    .disabled(deck.track == nil)
                    .help(on ? "End the loop" : "Loop from the beat just played")
                    Button { model.setLoopBeats(deck.loopBeats / 2, deck: deck) } label: {
                        Image(systemName: "minus").font(.system(size: 9, weight: .bold)).frame(width: 20, height: 22).background(Theme.control)
                    }
                    .buttonStyle(.plain).help("Half as long")
                    Text(Self.loopLength(deck.loopBeats))
                        .font(Theme.readoutSm).foregroundStyle(Theme.ink)
                        .frame(width: 58, height: 22).background(Theme.panel)
                    Button { model.setLoopBeats(deck.loopBeats * 2, deck: deck) } label: {
                        Image(systemName: "plus").font(.system(size: 9, weight: .bold)).frame(width: 20, height: 22).background(Theme.control)
                    }
                    .buttonStyle(.plain).help("Twice as long")
                }
                .foregroundStyle(Theme.ink)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSm))
            }
            // Loop slots from Prep.
            if let loops = prep?.loops, !loops.isEmpty {
                group("Loop slots") {
                    HStack(spacing: 3) {
                        ForEach(Array(loops.prefix(6).enumerated()), id: \.element.id) { n, loop in
                            let on = deck.loopActive && deck.activeSlot == loop.id
                            Button { model.playLoopSlot(loop, deck: deck) } label: {
                                HStack(spacing: 3) {
                                    Text("L\(n + 1)").font(.system(size: 10, weight: .semibold))
                                    Text(SavedLoop.barLabel(loop.bars)).font(Theme.readoutSm)
                                        .foregroundStyle(on ? Theme.onAccent : Theme.inkMuted)
                                }
                                .foregroundStyle(on ? Theme.onAccent : loop.swatch)
                                .padding(.horizontal, 6)
                                .frame(height: 22)
                                .background(on ? loop.swatch : Theme.control)
                                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSm))
                            }
                            .buttonStyle(.plain)
                            .help("Loop slot L\(n + 1): \(SavedLoop.barLabel(loop.bars)) bars from \(PrepEditorClock.clock(loop.start)). Press again to let the track run on.")
                        }
                    }
                }
            }
            Spacer(minLength: Theme.space2)
            FXKnobs(fx: deck.fx, size: 24, spacing: 6, tint: deck.color) { kind, v in model.setFX(kind, v, deck: deck) }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Theme.space3)
        .padding(.vertical, 6)
        .background(Theme.panelRaised)
    }

    private func group<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased()).font(.system(size: 9, weight: .medium)).tracking(0.3).foregroundStyle(Theme.inkFaint)
            content()
        }
    }

    static func loopLength(_ beats: Int) -> String {
        if beats >= 4 && beats % 4 == 0 { return beats == 4 ? "1 bar" : "\(beats / 4) bars" }
        return beats == 1 ? "1 beat" : "\(beats) beats"
    }
}

enum PrepEditorClock {
    static func clock(_ s: Double) -> String {
        let tenths = Int((max(0, s) * 10).rounded())
        return String(format: "%d:%02d.%d", tenths / 600, tenths / 10 % 60, tenths % 10)
    }
}


/// Mix's keys: space plays or stops the deck under the mouse.
/// Mix's keys (all changeable in Keyboard shortcuts): the track list's
/// arrows, pre-listen (to the headphones: outputs 5–6, the Xone:24C's
/// AUX/USB channel) and loading on deck A or B. Over a deck, the pre-listen
/// key plays or stops that deck instead.
@Observable
final class MixKeys {
    @ObservationIgnored var hovered: Int?
    /// The row to keep in view (moved to with the arrow keys).
    var follow: URL?
    @ObservationIgnored private var monitor: Any?

    func install(_ model: AppModel) {
        remove()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak model] event in
            guard let self, let model, self.handle(event, model) else { return event }
            return nil
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

    /// The list in the order shown (groups opened out).
    private func order(_ model: AppModel) -> [URL] {
        let view = model.pageView("mix")
        let recs = model.pageRecords("mix")
        return (view.groupBy.map { by in
            model.records.group(recs, by: by).filter { !view.collapsed.contains($0.id) }.flatMap(\.records)
        } ?? recs).map(\.id)
    }

    private func handle(_ event: NSEvent, _ model: AppModel) -> Bool {
        guard Shortcuts.shared.forPages(event) else { return false }
        if let text = event.window?.firstResponder as? NSText {
            guard event.keyCode == 53 || (event.keyCode == 49 && text.string.isEmpty) else { return false }
            event.window?.makeFirstResponder(nil)
            if event.keyCode == 53 { return true }
        }
        let keys = Shortcuts.shared
        func on(_ a: ShortcutAction) -> Bool { keys.matches(a, event) }

        if on(.mixListen), let id = hovered, model.decks.indices.contains(id) {
            let deck = model.decks[id]
            model.setPlaying(!deck.transportPlaying, deck: deck)
            return true
        }
        let selection = model.mixSelection
        let list = order(model)
        let current = follow.flatMap { selection.contains($0) ? $0 : nil } ?? list.first(where: selection.contains)

        if on(.mixDown) || on(.mixUp) {
            if let next = ListStep.next(in: list, from: current, by: on(.mixDown) ? 1 : -1) {
                model.mixSelection = [next]
                follow = next
            }
        } else if on(.mixListen) {
            if let url = current { model.listen(url, at: nil) }
        } else if on(.mixBack) || on(.mixForward) {
            if model.prepPage.preview != nil { model.prepSeek(by: on(.mixForward) ? 10 : -10) }
        } else if on(.mixLoadA) || on(.mixLoadB) {
            guard let url = current else { return true }
            let deck = model.decks[on(.mixLoadA) ? 0 : 1]
            Task { await model.load(url: url, into: deck) }
        } else {
            return false
        }
        return true
    }
}

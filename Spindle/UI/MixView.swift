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
        VStack(spacing: 0) {
            HStack(spacing: 1) {
                CrateList(library: library, model: model)
                    .frame(width: 200)
                VStack(spacing: 0) {
                    SharedTrackList(model: model, library: library, key: "mix",
                                    selection: Binding(get: { model.mixSelection }, set: { model.mixSelection = $0 }),
                                    dimmed: dimUnfit ? { !fits($0.id) } : nil,
                                    trailing: AnyView(
                                        Toggle("Dim what doesn't fit", isOn: $dimUnfit)
                                            .toggleStyle(.checkbox)
                                            .font(Theme.caption)
                                            .foregroundStyle(Theme.inkMuted)
                                            .help("Grey out tracks whose key or tempo doesn't fit a playing deck")))
                    Rectangle().fill(Theme.line).frame(height: 1)
                    LoadBar(model: model, fits: fits)
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

// MARK: Load bar

/// The one place tracks are loaded from: the selected track, why it fits,
/// its cues, and Load A / Load B. (Double-click loads into the free deck;
/// tracks can also be dragged onto a deck.)
private struct LoadBar: View {
    let model: AppModel
    let fits: (URL) -> Bool

    var body: some View {
        let url = model.mixSelection.first
        HStack(spacing: Theme.space4) {
            if let url {
                let a = model.analysis.analysis(for: url)
                let prep = model.prep.prep(for: url)
                VStack(alignment: .leading, spacing: 2) {
                    Text(url.deletingPathExtension().lastPathComponent).font(Theme.title).foregroundStyle(Theme.ink).lineLimit(1)
                    Text(a.map { "\(String(format: "%.1f", prep?.bpm ?? $0.bpm)) · \($0.camelotNumber) \(KeyStyle.mood(minor: $0.keyMinor)) · E\($0.energy) · \(OrganizeView.length($0.duration))" } ?? "Not analysed yet")
                        .font(Theme.readoutSm).foregroundStyle(Theme.inkMuted)
                }
                .frame(width: 320, alignment: .leading)
                cueLine(prep, duration: a?.duration ?? 1)
                Text(reason(url)).font(Theme.caption).foregroundStyle(Theme.inkMuted).lineLimit(1)
                    .frame(width: 220, alignment: .leading)
            } else {
                Text("Select a track to load it. Double-click loads into the free deck; you can also drag a track onto a deck.")
                    .font(Theme.caption).foregroundStyle(Theme.inkFaint)
                Spacer()
            }
            ForEach(model.decks) { deck in
                Button {
                    if let url { Task { await model.load(url: url, into: deck) } }
                } label: {
                    Text("Load \(deck.label)")
                        .font(Theme.label)
                        .foregroundStyle(Theme.ink)
                        .frame(width: 70, height: 26)
                        .background(Theme.control)
                        .overlay(RoundedRectangle(cornerRadius: Theme.radiusMd).stroke(deck.color, lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMd))
                }
                .buttonStyle(.plain)
                .disabled(url == nil)
            }
        }
        .padding(.horizontal, Theme.space3)
        .frame(height: 56)
        .background(Theme.panelRaised)
    }

    /// The four cues as ticks on a line through the track.
    private func cueLine(_ prep: TrackPrep?, duration: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.line).frame(height: 2)
                ForEach(prep?.cues ?? [], id: \.role) { cue in
                    Rectangle().fill(cue.role.color).frame(width: 2, height: 14)
                        .offset(x: CGFloat(cue.time / max(duration, 1)) * geo.size.width)
                        .help("\(cue.role.rawValue) \(cue.role.name)")
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: 18)
    }

    /// "Lift from deck A · −0.8%", or why it doesn't fit.
    private func reason(_ url: URL) -> String {
        guard let clip = model.analysis.analysis(for: url) else { return "" }
        let bpm = model.bpm(of: url) ?? clip.bpm
        for deck in model.decks where deck.playing {
            guard let t = deck.track, t.url != url, let a = model.analysis.analysis(for: t.url), let live = model.liveBPM(deck) else { continue }
            let ratio = [bpm, bpm * 2, bpm / 2].map { $0 / live - 1 }.min { abs($0) < abs($1) } ?? 0
            let move = MixRelation.between(a, clip)?.title ?? "Key clash"
            return "\(move) after deck \(deck.label) · " + String(format: "%+.1f%%", ratio * 100)
        }
        return fits(url) ? "Nothing playing" : ""
    }
}

// MARK: Deck performance strip

/// Cue pads, loop and FX under each deck on the Mix page.
private struct DeckPerformance: View {
    @Bindable var deck: DeckModel
    let model: AppModel

    var body: some View {
        let prep = deck.track.flatMap { model.prep.prep(for: $0.url) }
        HStack(spacing: Theme.space2) {
            ForEach(CueRole.allCases) { role in
                let cue = prep?.cue(role)
                Button {
                    model.jump(deck: deck, to: role)
                } label: {
                    Text("\(role.rawValue) \(role.name)")
                        .font(Theme.label)
                        .foregroundStyle(cue == nil ? Theme.inkFaint : Theme.onAccent)
                        .frame(width: 52, height: 22)
                        .background(cue == nil ? Theme.control : role.color)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSm))
                }
                .buttonStyle(.plain)
                .disabled(cue == nil)
                .help(cue.map { "Jump to \(role.name) at \(PrepEditorClock.clock($0.time))" } ?? "\(role.name) not set (Prep page)")
            }
            Divider().frame(height: 20)
            Button {
                model.setLoop(!deck.loopActive, deck: deck)
            } label: {
                Text("LOOP \(deck.loopBeats)")
                    .font(Theme.label)
                    .foregroundStyle(deck.loopActive ? Theme.onAccent : Theme.ink)
                    .frame(width: 64, height: 22)
                    .background(deck.loopActive ? Theme.match : Theme.control)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSm))
            }
            .buttonStyle(.plain)
            .disabled(deck.track == nil)
            Button("÷2") { model.setLoopBeats(deck.loopBeats / 2, deck: deck) }.buttonStyle(FlatButtonStyle())
            Button("×2") { model.setLoopBeats(deck.loopBeats * 2, deck: deck) }.buttonStyle(FlatButtonStyle())
            Divider().frame(height: 20)
            Text("FLT").font(Theme.label).foregroundStyle(Theme.inkMuted)
            Slider(value: Binding(get: { deck.filter }, set: { model.setFilter(abs($0) < 0.03 ? 0 : $0, deck: deck) }), in: -1...1)
                .frame(width: 90)
            Text("ECHO").font(Theme.label).foregroundStyle(Theme.inkMuted)
            Slider(value: Binding(get: { deck.echo }, set: { model.setEcho($0, deck: deck) }), in: 0...1)
                .frame(width: 70)
            Spacer(minLength: 0)
        }
        .tint(deck.color)
        .padding(.horizontal, Theme.space3)
        .padding(.vertical, Theme.space2)
        .background(Theme.panelRaised)
    }
}

enum PrepEditorClock {
    static func clock(_ s: Double) -> String {
        let tenths = Int((max(0, s) * 10).rounded())
        return String(format: "%d:%02d.%d", tenths / 600, tenths / 10 % 60, tenths % 10)
    }
}

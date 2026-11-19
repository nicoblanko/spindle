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

    var body: some View {
        VStack(spacing: 0) {
            ClipGrid(model: model, library: library)
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
        }
    }
}

// MARK: Clip grid

private struct ClipGrid: View {
    let model: AppModel
    @Bindable var library: LibraryModel
    @State private var onlyMatches = false
    @State private var onlyReady = false

    private var columns: [String] { library.crates }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(Theme.line).frame(height: 1)
            GeometryReader { geo in
                // Columns share the width (at least 200 pt each), from the left.
                let count = max(columns.count, 1)
                let width = max(200, (geo.size.width - CGFloat(count - 1)) / CGFloat(count))
                ScrollView([.horizontal, .vertical]) {
                    HStack(alignment: .top, spacing: 1) {
                        ForEach(columns, id: \.self) { crate in
                            column(crate).frame(width: width)
                        }
                    }
                    .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .topLeading)
                    .background(Theme.line)
                }
            }
            .background(Theme.bg)
        }
    }

    private var toolbar: some View {
        HStack(spacing: Theme.space3) {
            LabelText("Clips")
            ForEach(model.decks) { deck in
                if let bpm = model.liveBPM(deck), deck.track != nil {
                    HStack(spacing: Theme.space1) {
                        Circle().fill(deck.color).frame(width: 6, height: 6)
                        Text("\(deck.label) \(String(format: "%.1f", bpm))\(model.analysis.analysis(for: deck.track!.url).map { " · " + $0.camelot } ?? "")\(deck.playing ? "" : " · stopped")")
                            .font(Theme.readoutSm)
                            .foregroundStyle(deck.playing ? Theme.ink : Theme.inkFaint)
                    }
                }
            }
            Spacer()
            Toggle("Matches only", isOn: $onlyMatches).toggleStyle(.checkbox)
            Toggle("Mix-ready only", isOn: $onlyReady).toggleStyle(.checkbox)
            TextField("Search", text: $library.search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
        }
        .font(Theme.caption)
        .foregroundStyle(Theme.inkMuted)
        .padding(.horizontal, Theme.space3)
        .frame(height: 34)
        .background(Theme.panelRaised)
    }

    private func clips(in crate: String) -> [LibraryTrack] {
        library.tracks.filter { track in
            track.crate == crate
                && (library.search.isEmpty || track.name.localizedCaseInsensitiveContains(library.search))
                && (!onlyReady || model.prep.prep(for: track.url)?.mixReady == true)
                && (!onlyMatches || !matchingDecks(track.url).isEmpty)
        }
        .sorted { a, b in
            // Sort by tempo so neighbours mix.
            (model.analysis.analysis(for: a.url)?.bpm ?? 0) < (model.analysis.analysis(for: b.url)?.bpm ?? 0)
        }
    }

    private func column(_ crate: String) -> some View {
        let items = clips(in: crate)
        return VStack(spacing: 1) {
            HStack {
                Text(crate).font(Theme.label).foregroundStyle(Theme.ink).lineLimit(1)
                Spacer()
                Text("\(items.count)").font(Theme.readoutSm).foregroundStyle(Theme.inkFaint)
            }
            .padding(.horizontal, Theme.space2)
            .frame(height: 26)
            .background(Theme.panelRaised)
            ForEach(items) { track in
                ClipCell(track: track, model: model, matches: matchingDecks(track.url))
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.panel)
    }

    /// Decks this clip would mix with: playing, compatible key, tempo within 6%.
    private func matchingDecks(_ url: URL) -> [DeckModel] {
        guard let clip = model.analysis.analysis(for: url) else { return [] }
        return model.decks.filter { deck in
            guard deck.playing, let track = deck.track, track.url != url,
                  let playing = model.analysis.analysis(for: track.url),
                  let live = model.liveBPM(deck) else { return false }
            let clipBPM = model.prep.prep(for: url)?.bpm ?? clip.bpm
            // Half/double time counts too.
            let ratio = [clipBPM, clipBPM * 2, clipBPM / 2].map { abs($0 - live) / live }.min() ?? 1
            return Compatibility.keys(playing, clip) && ratio < 0.06
        }
    }
}

private struct ClipCell: View {
    let track: LibraryTrack
    let model: AppModel
    let matches: [DeckModel]
    @State private var hovering = false

    var body: some View {
        let analysis = model.analysis.analysis(for: track.url)
        let prep = model.prep.prep(for: track.url)
        let selected = model.highlightedClip == track.url
        let loadedOn = model.decks.first { $0.track?.url == track.url }
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: Theme.space1) {
                if let loadedOn {
                    Text(loadedOn.label).font(Theme.label).foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 3).background(loadedOn.color)
                }
                Text(track.name).font(Theme.caption).foregroundStyle(Theme.ink).lineLimit(1)
                Spacer(minLength: 0)
                if prep?.mixReady == true {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.match)
                }
            }
            HStack(spacing: Theme.space2) {
                Text(analysis.map { String(format: "%.0f", prep?.bpm ?? $0.bpm) } ?? "—").font(Theme.readoutSm)
                Text(analysis?.camelot ?? "").font(Theme.readoutSm)
                Text(analysis.map { "E\($0.energy)" } ?? "").font(Theme.readoutSm)
                Spacer(minLength: 0)
                CueDots(prep: prep)
            }
            .foregroundStyle(Theme.inkMuted)
            if let fx = prep?.fx, !fx.isEmpty {
                Text(fx.summary).font(Theme.readoutSm).foregroundStyle(Theme.inkMuted).lineLimit(1)
            }
            if hovering {
                HStack(spacing: Theme.space1) {
                    ForEach(model.decks) { deck in
                        Button("→ \(deck.label)") { load(deck) }
                            .font(Theme.label)
                            .buttonStyle(.plain)
                            .foregroundStyle(deck.color)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Theme.control)
                    }
                }
            }
        }
        .padding(.horizontal, Theme.space2)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Theme.accentSoft : (hovering ? Theme.panelRaised : Theme.panel))
        .overlay {
            // Match outline in the matching deck's colour (both: split).
            if let first = matches.first {
                Rectangle().strokeBorder(matches.count > 1 ? Theme.match : first.color, lineWidth: 2)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { load(model.freeDeck) }
        .onTapGesture { model.highlightedClip = track.url }
        .help(matches.isEmpty ? track.name : "\(track.name) — mixes with deck \(matches.map(\.label).joined(separator: " and "))")
    }

    private func load(_ deck: DeckModel) {
        model.highlightedClip = track.url
        Task { await model.load(url: track.url, into: deck) }
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

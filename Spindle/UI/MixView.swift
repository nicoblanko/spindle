//
//  MixView.swift
//  Spindle
//
//  Build step 4: Mix. Left, the stack: decks A and B as full cards on top,
//  then "Up next", an endless queue you drag to reorder, send to a deck or
//  remove; Next ▸ on a deck loads the next card onto it. Right, your tracks
//  in tabs (All tracks and each playlist), each tab an Airtable-style grid
//  with its own filter, grouping and hidden fields. Drag the divider to
//  share the width; both sides scroll.
//

import SwiftUI

struct MixView: View {
    let model: AppModel
    @Bindable var library: LibraryModel

    var body: some View {
        HSplitView {
            StackPanel(model: model)
                .frame(minWidth: 480, idealWidth: 760, maxWidth: .infinity, maxHeight: .infinity)
            TrackBrowser(model: model, library: library)
                .frame(minWidth: 380, idealWidth: 640, maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.line)
    }
}

/// Tracks that would mix with a deck that is playing: compatible key and
/// tempo within 6% (half and double time count).
@MainActor
func mixesWithPlayingDeck(_ url: URL, model: AppModel) -> [DeckModel] {
    guard let clip = model.analysis.analysis(for: url) else { return [] }
    return model.decks.filter { deck in
        guard deck.playing, let track = deck.track, track.url != url,
              let playing = model.analysis.analysis(for: track.url),
              let live = model.liveBPM(deck) else { return false }
        let clipBPM = model.prep.prep(for: url)?.bpm ?? clip.bpm
        return Compatibility.keys(playing, clip) && Compatibility.tempo(live, clipBPM, tolerance: 0.06)
    }
}

// MARK: Stack

private struct StackPanel: View {
    let model: AppModel
    @State private var showPlayed = false
    @State private var confirmClear = false
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.space3) {
                LabelText("Stack")
                Text("\(model.stack.count) up next").font(Theme.caption).foregroundStyle(Theme.inkMuted)
                Spacer()
                if !model.stack.isEmpty {
                    Button("Clear queue") { confirmClear = true }.buttonStyle(FlatButtonStyle())
                }
            }
            .padding(.horizontal, Theme.space3)
            .frame(height: 34)
            .background(Theme.panelRaised)
            if model.laptop {
                LaptopMixer(model: model)
                Rectangle().fill(Theme.line).frame(height: 1)
            }
            List {
                Section {
                    ForEach(model.decks) { deck in
                        VStack(spacing: 0) {
                            DeckPanel(deck: deck, model: model, compact: true)
                            DeckPerformance(deck: deck, model: model)
                        }
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Theme.panel)
                        .padding(.bottom, 1)
                        .background(Theme.line)
                    }
                }
                Section {
                    ForEach(Array(model.stack.enumerated()), id: \.element.id) { index, item in
                        QueueCard(item: item, position: index + 1, model: model)
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 1, trailing: 0))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Theme.line)
                    }
                    .onMove { model.moveInStack(from: $0, to: $1) }
                    .dropDestination(for: URL.self) { urls, index in model.addToStack(urls, at: index) }
                    if model.stack.isEmpty {
                        Text("The queue is empty. Drag tracks here from the right, or double-click them.")
                            .font(Theme.caption).foregroundStyle(Theme.inkFaint)
                            .frame(maxWidth: .infinity, minHeight: 60)
                            .listRowBackground(Theme.panel)
                    }
                } header: {
                    sectionTitle("Up next", count: model.stack.count)
                }
                if !model.played.isEmpty {
                    Section {
                        if showPlayed {
                            ForEach(model.played) { item in
                                PlayedRow(item: item, model: model)
                                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 1, trailing: 0))
                                    .listRowSeparator(.hidden)
                                    .listRowBackground(Theme.line)
                            }
                        }
                    } header: {
                        Button { showPlayed.toggle() } label: {
                            HStack(spacing: 4) {
                                Image(systemName: showPlayed ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold))
                                sectionTitle("Played", count: model.played.count)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .environment(\.defaultMinListRowHeight, 1)
        }
        .background(Theme.bg)
        .overlay {
            if dropTargeted { Rectangle().strokeBorder(Theme.accent, lineWidth: 2) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.addToStack(urls)
            return true
        } isTargeted: { dropTargeted = $0 }
        .confirmationDialog("Clear the queue?", isPresented: $confirmClear) {
            Button("Clear queue", role: .destructive) { model.clearStack() }
        } message: {
            Text("The \(model.stack.count) queued tracks are taken off the stack. The decks keep playing.")
        }
    }

    private func sectionTitle(_ title: String, count: Int) -> some View {
        HStack(spacing: Theme.space2) {
            LabelText(title)
            Text("\(count)").font(Theme.readoutSm).foregroundStyle(Theme.inkFaint)
            Spacer()
        }
        .padding(.horizontal, Theme.space2)
        .padding(.vertical, Theme.space1)
    }
}

/// A queued track: its place, key, tempo, cues and tags; send it to a deck
/// (swapping with what's there) or take it off the stack.
private struct QueueCard: View {
    let item: StackItem
    let position: Int
    let model: AppModel
    @State private var hovering = false

    var body: some View {
        let analysis = model.analysis.analysis(for: item.url)
        let prep = model.prep.prep(for: item.url)
        let matches = mixesWithPlayingDeck(item.url, model: model)
        let tags = model.library.tags.manualTags(for: item.path)
        HStack(spacing: Theme.space2) {
            Image(systemName: "line.3.horizontal").font(.system(size: 10)).foregroundStyle(Theme.inkFaint)
            Text("\(position)").font(Theme.readoutSm).foregroundStyle(Theme.inkFaint).frame(width: 22, alignment: .trailing)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Theme.space1) {
                    if !matches.isEmpty {
                        Circle().fill(Theme.match).frame(width: 6, height: 6)
                            .help("Mixes with deck \(matches.map(\.label).joined(separator: " and ")) (key and tempo)")
                    }
                    Text(item.url.deletingPathExtension().lastPathComponent)
                        .font(Theme.body).foregroundStyle(Theme.ink).lineLimit(1)
                }
                HStack(spacing: Theme.space2) {
                    Text(analysis.map { String(format: "%.0f", prep?.bpm ?? $0.bpm) } ?? "—").font(Theme.readoutSm)
                    KeyChip(analysis: analysis)
                    Text(analysis.map { "E\($0.energy)" } ?? "").font(Theme.readoutSm)
                    CueDots(prep: prep)
                    ForEach(tags.prefix(3)) { Pill(name: $0.name, color: $0.color) }
                }
                .foregroundStyle(Theme.inkMuted)
            }
            Spacer(minLength: 0)
            ForEach(model.decks) { deck in
                Button("→ \(deck.label)") { model.sendToDeck(item, deck: deck) }
                    .font(Theme.label)
                    .buttonStyle(.plain)
                    .foregroundStyle(deck.color)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Theme.control)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSm))
                    .help("Load on deck \(deck.label) now; its current track goes back to the top of the queue")
            }
            Button { model.removeFromStack(item.id) } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(hovering ? Theme.ink : Theme.inkFaint)
            .help("Take off the stack")
        }
        .padding(.horizontal, Theme.space3)
        .padding(.vertical, Theme.space2)
        .background(hovering ? Theme.panelRaised : Theme.panel)
        .overlay(alignment: .leading) {
            if !matches.isEmpty { Rectangle().fill(matches.count > 1 ? Theme.match : matches[0].color).frame(width: 3) }
        }
        .onHover { hovering = $0 }
        .contextMenu {
            ForEach(model.decks) { deck in
                Button("Load on deck \(deck.label) now") { model.sendToDeck(item, deck: deck) }
            }
            Button("Move to top") {
                if let i = model.stack.firstIndex(of: item) { model.moveInStack(from: [i], to: 0) }
            }
            Divider()
            Button("Remove from stack") { model.removeFromStack(item.id) }
        }
    }
}

private struct PlayedRow: View {
    let item: StackItem
    let model: AppModel

    var body: some View {
        HStack(spacing: Theme.space2) {
            Image(systemName: "checkmark").font(.system(size: 9)).foregroundStyle(Theme.inkFaint)
            Text(item.url.deletingPathExtension().lastPathComponent)
                .font(Theme.caption).foregroundStyle(Theme.inkMuted).lineLimit(1)
            Spacer()
            Button("Queue again") { model.addToStack([item.url]) }
                .buttonStyle(.plain).font(Theme.caption).foregroundStyle(Theme.inkMuted)
        }
        .padding(.horizontal, Theme.space3)
        .padding(.vertical, 5)
        .background(Theme.panel)
    }
}

// MARK: Track browser

/// Right side: tabs for All tracks and each playlist; each tab is a grid
/// with its own filter, grouping, sort and hidden fields.
private struct TrackBrowser: View {
    let model: AppModel
    @Bindable var library: LibraryModel
    @State private var search = ""
    @State private var showFilter = false
    @State private var showGroup = false
    @State private var showHide = false

    private var tabs: [(id: String, title: String)] {
        [("all", "All tracks")] + library.playlists.playlists.map { ($0.node.id.uuidString, $0.path) }
    }

    private var tab: String { tabs.contains { $0.id == model.mixTab } ? model.mixTab : "all" }

    private var view: Binding<ViewSettings> {
        Binding(get: { model.mixView(for: tab) }, set: { model.mixTabViews[tab] = $0 })
    }

    private var records: [Record] {
        let tracks = tab == "all" ? library.allTracks : UUID(uuidString: tab).map(library.tracks(inPlaylist:)) ?? []
        let base = tracks.enumerated()
            .filter { search.isEmpty || $1.name.localizedCaseInsensitiveContains(search) }
            .map { Record(track: $1, analysis: model.analysis.analysis(for: $1.url), index: $0 + 1) }
        return model.records.apply(view.wrappedValue, to: base)
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Rectangle().fill(Theme.line).frame(height: 1)
            toolbar
            Rectangle().fill(Theme.line).frame(height: 1)
            RecordGrid(model: model, records: records, view: view,
                       mixes: { !mixesWithPlayingDeck($0.id, model: model).isEmpty },
                       menu: { AnyView(menu($0)) },
                       selection: Binding(get: { model.mixSelection }, set: { model.mixSelection = $0 }),
                       onOpen: { model.addToStack([$0.id]) })
        }
        .background(Theme.panel)
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(tabs, id: \.id) { t in
                    let active = t.id == tab
                    Button { model.mixTab = t.id } label: {
                        VStack(spacing: 4) {
                            HStack(spacing: 4) {
                                if t.id != "all" { Image(systemName: "music.note.list").font(.system(size: 10)) }
                                Text(t.title).lineLimit(1)
                            }
                            .font(Theme.body)
                            .foregroundStyle(active ? Theme.ink : Theme.inkMuted)
                            Rectangle().fill(active ? Theme.accent : Color.clear).frame(height: 2)
                        }
                        .padding(.horizontal, Theme.space3)
                        .padding(.top, Theme.space2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .dropDestination(for: URL.self) { urls, _ in
                        guard let id = UUID(uuidString: t.id) else { return false }
                        model.addToPlaylist(urls, playlist: id)
                        return true
                    }
                }
            }
        }
        .frame(height: 38)
        .background(Theme.panelRaised)
    }

    private var toolbar: some View {
        let v = view.wrappedValue
        return HStack(spacing: Theme.space2) {
            Menu {
                ForEach(model.savedViews) { saved in
                    Button(saved.name) { view.wrappedValue = saved.settings }
                }
                if !model.savedViews.isEmpty { Divider() }
                Button("Default columns") { view.wrappedValue = model.defaultMixView() }
            } label: {
                Label("Views", systemImage: "tablecells").font(Theme.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Apply a saved view (filter, grouping, columns) to this tab")
            chip(v.hidden.isEmpty ? "Fields" : "\(v.hidden.count) hidden", icon: "eye.slash", active: false) { showHide = true }
                .popover(isPresented: $showHide) { HideFieldsView(view: view, context: model.records) }
            chip(v.conditions.isEmpty ? "Filter" : "Filtered (\(v.conditions.count))", icon: "line.3.horizontal.decrease",
                 active: !v.conditions.isEmpty) { showFilter = true }
                .popover(isPresented: $showFilter) { FilterView(view: view, context: model.records) }
            chip(v.groupBy.map { "Grouped by \(model.records.name($0))" } ?? "Group", icon: "rectangle.grid.1x2",
                 active: v.groupBy != nil) { showGroup = true }
                .popover(isPresented: $showGroup) { GroupView(view: view, context: model.records) }
            Spacer()
            Text("\(records.count)").font(Theme.readoutSm).foregroundStyle(Theme.inkFaint)
            TextField("Search", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 160)
        }
        .padding(.horizontal, Theme.space3)
        .frame(height: 36)
        .background(Theme.panelRaised)
    }

    private func chip(_ title: String, icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10))
                Text(title).lineLimit(1)
            }
            .font(Theme.caption)
            .foregroundStyle(active ? TagDef.textColor : Theme.inkMuted)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(active ? TagStore.palette[3] : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMd))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func menu(_ urls: Set<URL>) -> some View {
        let ordered = records.map(\.id).filter { urls.contains($0) }
        Button("Add to stack") { model.addToStack(ordered) }
        Button("Play next") { model.playNext(ordered) }
        if let url = ordered.first {
            Divider()
            ForEach(model.decks) { deck in
                Button("Load on deck \(deck.label) now") { Task { await model.load(url: url, into: deck) } }
            }
        }
        Divider()
        Menu("Add to playlist") {
            ForEach(library.playlists.playlists, id: \.node.id) { item in
                Button(item.path) { model.addToPlaylist(ordered, playlist: item.node.id) }
            }
        }
        if let id = UUID(uuidString: tab) {
            Button("Remove from this playlist") { library.playlists.remove(urls, from: id) }
        }
    }
}

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
            Button {
                model.next(deck: deck)
            } label: {
                Text("NEXT ▸")
                    .font(Theme.label)
                    .foregroundStyle(model.stack.isEmpty ? Theme.inkFaint : Theme.ink)
                    .frame(width: 64, height: 22)
                    .background(Theme.control)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSm))
            }
            .buttonStyle(.plain)
            .disabled(model.stack.isEmpty)
            .help(model.stack.first.map { "Done with this track: load “\($0.url.deletingPathExtension().lastPathComponent)” on deck \(deck.label)" } ?? "The queue is empty")
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

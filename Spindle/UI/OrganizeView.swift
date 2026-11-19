//
//  OrganizeView.swift
//  Spindle
//
//  Page 1, Organize: find tracks that work together and build playlists
//  for sets. Library and playlists on the left, the track table in the
//  middle, and on the right a key map plus, for the selected track, the
//  tracks that would mix well after it, explained in plain words.
//

import SwiftUI

struct OrganizeRow: Identifiable {
    let track: LibraryTrack
    let analysis: TrackAnalysis?
    /// Position in the playlist (or list) being shown.
    let index: Int
    var id: URL { track.url }
    var name: String { track.name }
    var crate: String { track.crate }
    var bpm: Double { analysis?.bpm ?? 0 }
    var keySort: Int { analysis.map { $0.camelotNumber * 2 + ($0.keyMinor ? 0 : 1) } ?? 99 }
    var energy: Int { analysis?.energy ?? 0 }
    var intro: String { analysis?.intro.rawValue ?? "" }
    var outro: String { analysis?.outro.rawValue ?? "" }
    var duration: Double { analysis?.duration ?? 0 }
}

enum Compatibility {
    /// Same or neighbouring key colour, or the same number with the other mood.
    static func keys(_ a: TrackAnalysis, _ b: TrackAnalysis) -> Bool {
        MixRelation.between(a, b) != nil
    }

    /// Tempo within `tolerance`, counting half and double time.
    static func tempo(_ a: Double, _ b: Double, tolerance: Double = 0.08) -> Bool {
        [b, b * 2, b / 2].contains { abs($0 - a) / a < tolerance }
    }

    static func mixes(_ a: TrackAnalysis, _ b: TrackAnalysis) -> Bool {
        keys(a, b) && abs(a.energy - b.energy) <= 1 && tempo(a.bpm, b.bpm)
    }
}

struct OrganizeView: View {
    @Bindable var library: LibraryModel
    let analysis: AnalysisStore
    let model: AppModel
    private var selection: Set<URL> {
        get { model.organizeSelection }
        nonmutating set { model.organizeSelection = newValue }
    }
    private var selectionBinding: Binding<Set<URL>> {
        Binding(get: { model.organizeSelection }, set: { model.organizeSelection = $0 })
    }
    @State private var sortOrder = [KeyPathComparator(\OrganizeRow.index)]
    @State private var dropTargeted = false

    private var rows: [OrganizeRow] {
        library.visibleTracks.enumerated()
            .map { OrganizeRow(track: $1, analysis: analysis.analysis(for: $1.url), index: $0 + 1) }
            .sorted(using: sortOrder)
    }

    /// The track the right-hand panel talks about.
    private var focused: URL? {
        selection.count == 1 ? selection.first : rows.first { selection.contains($0.id) }?.id
    }

    var body: some View {
        HStack(spacing: 1) {
            CrateList(library: library, model: model)
                .frame(width: 210)
            VStack(spacing: 1) {
                toolbar
                table
                    .frame(minHeight: 200)
            }
            VStack(spacing: 1) {
                KeyEnergyMap(rows: rows, focused: focused, select: { selection = [$0] })
                    .frame(minHeight: 240)
                NextTracksPanel(focused: focused, rows: rows, model: model, select: { selection = [$0] })
                    .frame(height: 300)
            }
            .frame(width: 400)
        }
        .background(Theme.line)
        .onChange(of: library.playlist) { sortOrder = [KeyPathComparator(\OrganizeRow.index)] }
    }

    private var toolbar: some View {
        HStack(spacing: Theme.space3) {
            LabelText(library.selectionName)
            if analysis.pending > 0 {
                Text("Analysing… \(analysis.pending) left")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.inkMuted)
            }
            Spacer()
            if let playlist = library.selectedPlaylist {
                Button("Add files…") { model.chooseFilesForPlaylist(playlist.id) }
                    .buttonStyle(FlatButtonStyle())
                    .help("Add audio files or folders from anywhere on your Mac")
            }
            if selection.count > 1 {
                Button("New playlist from \(selection.count) tracks") {
                    let id = library.playlists.create(name: "New playlist", folder: false, in: nil)
                    model.addToPlaylist(rows.filter { selection.contains($0.id) }.map(\.id), playlist: id)
                    library.playlist = id
                }
                .buttonStyle(FlatButtonStyle())
            }
            TextField("Search", text: $library.search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
        }
        .padding(.horizontal, Theme.space3)
        .padding(.vertical, Theme.space2)
        .background(Theme.panelRaised)
    }

    private var table: some View {
        let focusedAnalysis = focused.flatMap { analysis.analysis(for: $0) }
        return Table(of: OrganizeRow.self, selection: selectionBinding, sortOrder: $sortOrder) {
            TableColumn("#", value: \.index) { Text("\($0.index)").font(Theme.readoutSm).foregroundStyle(Theme.inkFaint) }
                .width(30)
            TableColumn("Track", value: \.name) { row in
                HStack(spacing: Theme.space1) {
                    if let a = focusedAnalysis, let b = row.analysis, row.id != focused, Compatibility.mixes(a, b) {
                        Circle().fill(Theme.match).frame(width: 6, height: 6)
                    }
                    Text(row.name).lineLimit(1)
                }
            }
            .width(min: 180, ideal: 300)
            TableColumn("Folder", value: \.crate) { Text($0.crate).foregroundStyle(Theme.inkMuted) }
                .width(min: 60, ideal: 90)
            TableColumn("BPM", value: \.bpm) { row in
                Text(row.analysis == nil ? "—" : String(format: "%.1f", row.bpm)).font(Theme.readoutSm)
            }
            .width(52)
            TableColumn("Key", value: \.keySort) { KeyChip(analysis: $0.analysis) }
                .width(80)
            TableColumn("Energy", value: \.energy) { EnergyBar(energy: $0.energy) }
                .width(64)
            TableColumn("Intro", value: \.intro) { Text($0.intro).foregroundStyle(Theme.inkMuted) }
                .width(70)
            TableColumn("Outro", value: \.outro) { Text($0.outro).foregroundStyle(Theme.inkMuted) }
                .width(70)
            TableColumn("Length", value: \.duration) { row in
                Text(row.analysis == nil ? "—" : Self.length(row.duration)).font(Theme.readoutSm)
            }
            .width(48)
        } rows: {
            ForEach(rows) { row in
                TableRow(row).draggable(row.track.url)
            }
        }
        .font(Theme.body)
        .contextMenu(forSelectionType: URL.self) { urls in
            contextMenu(urls)
        } primaryAction: { urls in
            if let url = urls.first { Task { await model.load(url: url, into: model.freeDeck) } }
        }
        .overlay {
            if dropTargeted {
                Rectangle().strokeBorder(Theme.accent, lineWidth: 2)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let playlist = library.selectedPlaylist else { return false }
            model.addToPlaylist(urls, playlist: playlist.id)
            return true
        } isTargeted: { dropTargeted = $0 && library.selectedPlaylist != nil }
        .overlay {
            if library.visibleTracks.isEmpty && library.selectedPlaylist != nil && library.search.isEmpty {
                VStack(spacing: Theme.space2) {
                    Text("This playlist is empty").font(Theme.body).foregroundStyle(Theme.inkMuted)
                    Text("Drag tracks here from All tracks, or files and folders from Finder, or use Add files….")
                        .font(Theme.caption).foregroundStyle(Theme.inkFaint)
                }
            }
        }
    }

    @ViewBuilder
    private func contextMenu(_ urls: Set<URL>) -> some View {
        let ordered = rows.filter { urls.contains($0.id) }.map(\.id)
        if let url = ordered.first {
            Button("Load into deck A") { Task { await model.load(url: url, into: model.decks[0]) } }
            Button("Load into deck B") { Task { await model.load(url: url, into: model.decks[1]) } }
            Divider()
        }
        Menu("Add to playlist") {
            ForEach(library.playlists.playlists, id: \.node.id) { item in
                Button(item.path) { model.addToPlaylist(ordered, playlist: item.node.id) }
            }
            if !library.playlists.playlists.isEmpty { Divider() }
            Button("New playlist…") {
                let id = library.playlists.create(name: "New playlist", folder: false, in: nil)
                model.addToPlaylist(ordered, playlist: id)
            }
        }
        if let playlist = library.selectedPlaylist {
            Button("Move to top") { move(urls, in: playlist, to: 0) }
            Button("Move to bottom") { move(urls, in: playlist, to: playlist.tracks.count) }
            Divider()
            Button("Remove from \(playlist.name)") {
                library.playlists.remove(urls, from: playlist.id)
                selection = selection.subtracting(urls)
            }
        }
        Divider()
        if let url = ordered.first {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }

    private func move(_ urls: Set<URL>, in playlist: PlaylistNode, to destination: Int) {
        let paths = Set(urls.map(\.path))
        let offsets = IndexSet(playlist.tracks.indices.filter { paths.contains(playlist.tracks[$0]) })
        library.playlists.reorder(playlist.id, from: offsets, to: destination)
        sortOrder = [KeyPathComparator(\OrganizeRow.index)]
    }

    static func length(_ seconds: Double) -> String {
        String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}

struct EnergyBar: View {
    let energy: Int
    var body: some View {
        HStack(spacing: 1) {
            ForEach(1...10, id: \.self) { i in
                Rectangle()
                    .fill(i <= energy ? Theme.inkMuted : Theme.control)
                    .frame(width: 4, height: 10)
            }
        }
        .help(energy > 0 ? "Energy \(energy) of 10 (1 = calm, 10 = peak time)" : "Not analysed yet")
    }
}

// MARK: Next tracks

/// For the selected track: which tracks would mix well after it, grouped by
/// how (same key, lift, drop, mood change), with tempo and energy close.
private struct NextTracksPanel: View {
    let focused: URL?
    let rows: [OrganizeRow]
    let model: AppModel
    let select: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                LabelText("Good next tracks")
                Spacer()
                if let url = focused, let a = model.analysis.analysis(for: url) {
                    KeyChip(analysis: a)
                    Text(String(format: "%.0f BPM · energy %d", a.bpm, a.energy))
                        .font(Theme.readoutSm).foregroundStyle(Theme.inkMuted)
                }
            }
            .padding(.horizontal, Theme.space3)
            .frame(height: 34)
            .background(Theme.panelRaised)
            if let url = focused, let a = model.analysis.analysis(for: url) {
                let groups = suggestions(for: url, a)
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.space3) {
                        if groups.isEmpty {
                            Text("Nothing in this list mixes easily after this track (key, tempo within 8% and energy within 2).")
                                .font(Theme.caption).foregroundStyle(Theme.inkFaint)
                        }
                        ForEach(groups, id: \.relation) { group in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: Theme.space2) {
                                    Text(group.relation.title).font(Theme.label).foregroundStyle(Theme.ink)
                                    Text(group.relation.explanation).font(Theme.caption).foregroundStyle(Theme.inkFaint)
                                }
                                ForEach(group.rows) { row in suggestion(row, from: a) }
                            }
                        }
                    }
                    .padding(Theme.space3)
                }
            } else {
                Text("Select a track to see which tracks sound good after it.\n\n\(KeyStyle.explanation)\n\nEnergy runs from 1 (calm) to 10 (peak time).")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.inkMuted)
                    .padding(Theme.space3)
                Spacer(minLength: 0)
            }
        }
        .background(Theme.panel)
    }

    private struct Group { let relation: MixRelation; let rows: [OrganizeRow] }

    private func suggestions(for url: URL, _ a: TrackAnalysis) -> [Group] {
        var byRelation: [MixRelation: [OrganizeRow]] = [:]
        for row in rows where row.id != url {
            guard let b = row.analysis, let relation = MixRelation.between(a, b),
                  Compatibility.tempo(a.bpm, b.bpm), abs(a.energy - b.energy) <= 2 else { continue }
            byRelation[relation, default: []].append(row)
        }
        return MixRelation.allCases.compactMap { relation in
            guard let list = byRelation[relation], !list.isEmpty else { return nil }
            // Closest tempo first.
            let sorted = list.sorted { abs($0.bpm - a.bpm) < abs($1.bpm - a.bpm) }
            return Group(relation: relation, rows: Array(sorted.prefix(8)))
        }
    }

    private func suggestion(_ row: OrganizeRow, from a: TrackAnalysis) -> some View {
        HStack(spacing: Theme.space2) {
            KeyChip(analysis: row.analysis, showMood: false)
            Text(row.name).font(Theme.caption).foregroundStyle(Theme.ink).lineLimit(1)
            Spacer(minLength: 0)
            Text(String(format: "%.0f", row.bpm)).font(Theme.readoutSm).foregroundStyle(Theme.inkMuted)
            let delta = row.energy - a.energy
            Text(delta == 0 ? "=" : (delta > 0 ? "↑\(delta)" : "↓\(-delta)"))
                .font(Theme.readoutSm).foregroundStyle(Theme.inkMuted).frame(width: 22)
                .help("Energy \(row.energy) (\(delta >= 0 ? "+" : "")\(delta))")
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { select(row.id) }
        .contextMenu {
            Button("Load into deck A") { Task { await model.load(url: row.id, into: model.decks[0]) } }
            Button("Load into deck B") { Task { await model.load(url: row.id, into: model.decks[1]) } }
        }
    }
}

// MARK: Key map

/// Key colour across (the 12 colours of the wheel), energy up. Dark keys
/// are filled dots, Bright keys rings. The selected track is accent; tracks
/// that mix with it are ringed green.
struct KeyEnergyMap: View {
    let rows: [OrganizeRow]
    let focused: URL?
    let select: (URL) -> Void
    @State private var hovered: OrganizeRow?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                LabelText("Key map")
                Spacer()
                Text(hovered.map { "\($0.name) · energy \($0.energy)" } ?? "● Dark   ○ Bright · neighbours mix well")
                    .font(Theme.caption).foregroundStyle(Theme.inkMuted).lineLimit(1)
            }
            .padding(.horizontal, Theme.space3)
            .frame(height: 34)
            .background(Theme.panelRaised)
            GeometryReader { geo in
                let plot = CGRect(x: 40, y: 8, width: geo.size.width - 52, height: geo.size.height - 36)
                ZStack(alignment: .topLeading) {
                    Canvas { context, _ in draw(context, plot) }
                    ForEach(placed(in: plot), id: \.row.id) { item in
                        Circle()
                            .fill(Color.clear)
                            .contentShape(Circle())
                            .frame(width: 14, height: 14)
                            .position(item.point)
                            .onHover { inside in hovered = inside ? item.row : (hovered?.id == item.row.id ? nil : hovered) }
                            .onTapGesture { select(item.row.id) }
                    }
                }
            }
            .background(Theme.panel)
        }
    }

    private struct Placed { let row: OrganizeRow; let point: CGPoint }

    private func placed(in plot: CGRect) -> [Placed] {
        var cellCount: [String: Int] = [:]
        return rows.compactMap { row in
            guard let a = row.analysis else { return nil }
            let cell = "\(a.camelotNumber)\(a.keyMinor)\(a.energy)"
            let n = cellCount[cell, default: 0]
            cellCount[cell] = n + 1
            let colW = plot.width / 12, rowH = plot.height / 10
            let half = colW / 2
            let x = plot.minX + CGFloat(a.camelotNumber - 1) * colW + (a.keyMinor ? half * 0.5 : half * 1.5)
            let y = plot.maxY - (CGFloat(a.energy) - 0.5) * rowH
            let jitter = CGFloat(n) * 5
            return Placed(row: row, point: CGPoint(x: x + (n % 2 == 0 ? jitter / 2 : -jitter / 2), y: y - CGFloat(n / 2) * 5))
        }
    }

    private func draw(_ context: GraphicsContext, _ plot: CGRect) {
        let colW = plot.width / 12, rowH = plot.height / 10
        // A faint band of each key colour, so neighbours read as similar.
        for c in 1...12 {
            let band = CGRect(x: plot.minX + CGFloat(c - 1) * colW, y: plot.minY, width: colW, height: plot.height)
            context.fill(Path(band), with: .color(KeyStyle.color(number: c, minor: true).opacity(0.07)))
            context.fill(Path(CGRect(x: band.minX + 2, y: plot.maxY + 4, width: colW - 4, height: 5)),
                         with: .color(KeyStyle.color(number: c, minor: true)))
            context.draw(Text("\(c)").font(Theme.readoutSm).foregroundStyle(Theme.inkFaint),
                         at: CGPoint(x: band.midX, y: plot.maxY + 18))
        }
        var grid = Path()
        for c in 0...12 { grid.addRect(CGRect(x: plot.minX + CGFloat(c) * colW, y: plot.minY, width: 1, height: plot.height)) }
        for r in [0, 5, 10] { grid.addRect(CGRect(x: plot.minX, y: plot.minY + CGFloat(r) * rowH, width: plot.width, height: 1)) }
        context.fill(grid, with: .color(Theme.line.opacity(0.6)))
        context.draw(Text("Peak").font(Theme.caption).foregroundStyle(Theme.inkFaint),
                     at: CGPoint(x: plot.minX - 20, y: plot.minY + rowH * 0.5))
        context.draw(Text("Calm").font(Theme.caption).foregroundStyle(Theme.inkFaint),
                     at: CGPoint(x: plot.minX - 20, y: plot.maxY - rowH * 0.5))

        let focusedAnalysis = rows.first { $0.id == focused }?.analysis
        for item in placed(in: plot) {
            guard let a = item.row.analysis else { continue }
            let rect = CGRect(x: item.point.x - 4, y: item.point.y - 4, width: 8, height: 8)
            let isFocused = item.row.id == focused
            let mixes = focusedAnalysis.map { !isFocused && Compatibility.mixes($0, a) } ?? false
            let dimmed = focusedAnalysis != nil && !isFocused && !mixes
            let color = isFocused ? Theme.accent : KeyStyle.color(a).opacity(dimmed ? 0.3 : 1)
            if a.keyMinor {
                context.fill(Path(ellipseIn: rect), with: .color(color))
            } else {
                context.stroke(Path(ellipseIn: rect), with: .color(color), lineWidth: 1.5)
            }
            if mixes {
                context.stroke(Path(ellipseIn: rect.insetBy(dx: -3, dy: -3)), with: .color(Theme.match), lineWidth: 1.5)
            }
        }
    }
}

// MARK: Sidebar

/// Library (the music folder's subfolders) and playlists, shared by the
/// Organize and Prep pages.
struct CrateList: View {
    @Bindable var library: LibraryModel
    let model: AppModel
    @State private var renaming: UUID?
    @State private var draft = ""
    @State private var collapsed = Set<UUID>()
    @State private var dropTarget: UUID?
    @State private var pendingDelete: PlaylistNode?

    private var store: PlaylistStore { library.playlists }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    LabelText("Library")
                        .padding(.horizontal, Theme.space3)
                        .padding(.vertical, Theme.space2)
                    plainRow(title: "All tracks", count: library.tracks.count,
                             selected: library.crate == nil && library.playlist == nil) { library.selectAll() }
                    ForEach(library.crates, id: \.self) { crate in
                        plainRow(title: crate, count: library.tracks.filter { $0.crate == crate }.count,
                                 selected: library.crate == crate, icon: "folder") { library.crate = crate }
                    }
                    HStack {
                        LabelText("Playlists")
                        Spacer()
                        Menu {
                            Button("New playlist") { create(folder: false, in: nil) }
                            Button("New folder") { create(folder: true, in: nil) }
                        } label: {
                            Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("New playlist or folder")
                    }
                    .padding(.horizontal, Theme.space3)
                    .padding(.top, Theme.space4)
                    .padding(.bottom, Theme.space2)
                    tree(parent: nil, depth: 0)
                    if store.nodes.isEmpty {
                        Text("Make a playlist for each set. Add tracks from anywhere: drag them in, or right-click a track.")
                            .font(Theme.caption).foregroundStyle(Theme.inkFaint)
                            .padding(.horizontal, Theme.space3)
                        Button("New playlist") { create(folder: false, in: nil) }
                            .buttonStyle(FlatButtonStyle())
                            .padding(Theme.space3)
                    }
                }
            }
            Button("Choose music folder…") {
                Task {
                    await library.chooseFolder()
                    await model.analysis.analyze(library.allTracks.map(\.url))
                    await model.prepareAll()
                }
            }
            .buttonStyle(FlatButtonStyle())
            .padding(Theme.space2)
        }
        .frame(maxHeight: .infinity)
        .background(Theme.panel)
        .confirmationDialog("Delete \(pendingDelete?.name ?? "")?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let node = pendingDelete {
                    if library.playlist == node.id { library.selectAll() }
                    store.delete(node.id)
                }
                pendingDelete = nil
            }
        } message: {
            Text(pendingDelete?.isFolder == true
                 ? "The folder and the playlists in it are removed from Spindle. Your audio files stay where they are."
                 : "The playlist is removed from Spindle. Your audio files stay where they are.")
        }
    }

    private func create(folder: Bool, in parent: UUID?) {
        let id = store.create(name: folder ? "New folder" : "New playlist", folder: folder, in: parent)
        if let parent { collapsed.remove(parent) }
        if !folder { library.playlist = id }
        draft = store.node(id)?.name ?? ""
        renaming = id
    }

    private func tree(parent: UUID?, depth: Int) -> AnyView {
        AnyView(ForEach(store.children(of: parent)) { node in
            VStack(alignment: .leading, spacing: 0) {
                nodeRow(node, depth: depth)
                if node.isFolder && !collapsed.contains(node.id) {
                    tree(parent: node.id, depth: depth + 1)
                }
            }
        })
    }

    private func nodeRow(_ node: PlaylistNode, depth: Int) -> some View {
        let selected = library.playlist == node.id
        return HStack(spacing: Theme.space1) {
            if node.isFolder {
                Image(systemName: collapsed.contains(node.id) ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 10)
                    .onTapGesture {
                        if collapsed.contains(node.id) { collapsed.remove(node.id) } else { collapsed.insert(node.id) }
                    }
            } else {
                Spacer().frame(width: 10)
            }
            Image(systemName: node.isFolder ? "folder" : "music.note.list")
                .font(.system(size: 11))
                .frame(width: 14)
            if renaming == node.id {
                TextField("Name", text: $draft)
                    .textFieldStyle(.plain)
                    .font(Theme.body)
                    .onSubmit { store.rename(node.id, to: draft); renaming = nil }
                    .onExitCommand { renaming = nil }
            } else {
                Text(node.name).font(Theme.body).lineLimit(1)
            }
            Spacer()
            Text("\(store.count(node))").font(Theme.readoutSm)
        }
        .foregroundStyle(selected ? Theme.ink : Theme.inkMuted)
        .padding(.leading, Theme.space2 + CGFloat(depth) * 14)
        .padding(.trailing, Theme.space3)
        .padding(.vertical, 5)
        .background(selected ? Theme.accentSoft : (dropTarget == node.id ? Theme.panelRaised : Color.clear))
        .overlay {
            if dropTarget == node.id { Rectangle().strokeBorder(Theme.accent, lineWidth: 1) }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { draft = node.name; renaming = node.id }
        .onTapGesture { library.playlist = node.id }
        .dropDestination(for: URL.self) { urls, _ in
            guard !node.isFolder else { return false }
            model.addToPlaylist(urls, playlist: node.id)
            return true
        } isTargeted: { inside in
            if inside && !node.isFolder { dropTarget = node.id } else if dropTarget == node.id { dropTarget = nil }
        }
        .contextMenu {
            Button("Rename") { draft = node.name; renaming = node.id }
            if node.isFolder {
                Button("New playlist inside") { create(folder: false, in: node.id) }
                Button("New folder inside") { create(folder: true, in: node.id) }
            } else {
                Button("Add files…") { model.chooseFilesForPlaylist(node.id) }
            }
            Menu("Move to") {
                Button("Top level") { store.move(node.id, to: nil) }
                ForEach(store.folders.filter { $0.node.id != node.id }, id: \.node.id) { folder in
                    Button(folder.path) { store.move(node.id, to: folder.node.id) }
                }
            }
            Divider()
            Button("Delete…", role: .destructive) { pendingDelete = node }
        }
    }

    private func plainRow(title: String, count: Int, selected: Bool, icon: String = "music.note", action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.space1) {
                Spacer().frame(width: 10)
                Image(systemName: icon).font(.system(size: 11)).frame(width: 14)
                Text(title).font(Theme.body).lineLimit(1)
                Spacer()
                Text("\(count)").font(Theme.readoutSm)
            }
            .foregroundStyle(selected ? Theme.ink : Theme.inkMuted)
            .padding(.leading, Theme.space2)
            .padding(.trailing, Theme.space3)
            .padding(.vertical, 5)
            .background(selected ? Theme.accentSoft : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

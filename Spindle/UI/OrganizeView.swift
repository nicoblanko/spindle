//
//  OrganizeView.swift
//  Spindle
//
//  Page 1, Organize: find tracks that work together and build playlists
//  for sets. Library and playlists on the left, the track table in the
//  middle, and on the right a key wheel plus, for the selected track, the
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
    @State private var dropTargeted = false
    @State private var keyFilter: KeySlot?
    @State private var showFilter = false
    @State private var showGroup = false
    @State private var showHide = false
    @State private var naming: Naming?
    @State private var nameDraft = ""

    private enum Naming: Identifiable { case saveAs, rename; var id: Int { self == .saveAs ? 0 : 1 } }

    private var viewBinding: Binding<ViewSettings> {
        Binding(get: { model.organizeView }, set: { model.organizeView = $0 })
    }

    /// The list shown (folder, playlist or tag), narrowed by the key wheel.
    private var baseRecords: [Record] {
        library.visibleTracks.enumerated()
            .map { Record(track: $1, analysis: analysis.analysis(for: $1.url), index: $0 + 1) }
            .filter { r in keyFilter.map { f in r.analysis.map(KeySlot.init) == f } ?? true }
    }

    /// After the view's filter and sort.
    private var records: [Record] { model.records.apply(model.organizeView, to: baseRecords) }

    private var rows: [OrganizeRow] {
        records.map { OrganizeRow(track: $0.track, analysis: $0.analysis, index: $0.index) }
    }

    /// The wheel counts everything in the list, not only the filtered key.
    private var wheelRows: [OrganizeRow] {
        library.visibleTracks.enumerated()
            .map { OrganizeRow(track: $1, analysis: analysis.analysis(for: $1.url), index: $0 + 1) }
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
                grid
                    .frame(minHeight: 200)
            }
            VStack(spacing: 1) {
                KeyWheel(rows: wheelRows, focused: focused, filter: $keyFilter)
                    .frame(minHeight: 300)
                NextTracksPanel(focused: focused, rows: wheelRows, model: model, select: { selection = [$0] })
                    .frame(height: 300)
            }
            .frame(width: 380)
        }
        .background(Theme.line)
        .onChange(of: library.crate) { keyFilter = nil }
    }

    private var toolbar: some View {
        let view = model.organizeView
        return HStack(spacing: Theme.space2) {
            viewMenu
            LabelText(library.selectionName)
            if analysis.pending > 0 {
                Text("Analysing… \(analysis.pending) left")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.inkMuted)
            }
            Spacer()
            toolbarButton(view.hidden.isEmpty ? "Hide fields" : "\(view.hidden.count) hidden fields",
                          icon: "eye.slash", active: !view.hidden.isEmpty) { showHide = true }
                .popover(isPresented: $showHide) { HideFieldsView(view: viewBinding, context: model.records) }
            toolbarButton(view.conditions.isEmpty ? "Filter" : "Filtered by \(Set(view.conditions.map(\.field)).map(model.records.name).sorted().joined(separator: ", "))",
                          icon: "line.3.horizontal.decrease", active: !view.conditions.isEmpty) { showFilter = true }
                .popover(isPresented: $showFilter) { FilterView(view: viewBinding, context: model.records) }
            toolbarButton(view.groupBy.map { "Grouped by \(model.records.name($0))" } ?? "Group",
                          icon: "rectangle.grid.1x2", active: view.groupBy != nil) { showGroup = true }
                .popover(isPresented: $showGroup) { GroupView(view: viewBinding, context: model.records) }
            if let sort = view.sortField {
                toolbarButton("Sorted by \(model.records.name(sort))", icon: "arrow.up.arrow.down", active: true) {
                    model.organizeView.sortField = nil
                }
                .help("Click to stop sorting (or click a column header)")
            }
            if let playlist = library.selectedPlaylist {
                Button("Add files…") { model.chooseFilesForPlaylist(playlist.id) }
                    .buttonStyle(FlatButtonStyle())
                    .help("Add audio files or folders from anywhere on your Mac")
            }
            if selection.count > 1 {
                Button("New playlist from \(selection.count)") {
                    let id = library.playlists.create(name: "New playlist", folder: false, in: nil)
                    model.addToPlaylist(rows.filter { selection.contains($0.id) }.map(\.id), playlist: id)
                    library.playlist = id
                }
                .buttonStyle(FlatButtonStyle())
            }
            TextField("Search", text: $library.search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 180)
        }
        .padding(.horizontal, Theme.space3)
        .padding(.vertical, Theme.space2)
        .background(Theme.panelRaised)
    }

    /// Airtable-style view switcher: saved filter/group/sort templates.
    private var viewMenu: some View {
        HStack(spacing: Theme.space1) {
            Menu {
                ForEach(model.savedViews) { v in
                    Button { model.applyView(v.id) } label: {
                        Label(v.name, systemImage: v.id == model.currentViewID ? "checkmark" : "tablecells")
                    }
                }
                if !model.savedViews.isEmpty { Divider() }
                Button("Save as new view…") { nameDraft = model.currentView.map { $0.name + " 2" } ?? ""; naming = .saveAs }
                if let current = model.currentView {
                    Button("Save changes to “\(current.name)”") { model.updateCurrentView() }
                        .disabled(!model.viewModified)
                    Button("Revert changes") { model.revertCurrentView() }
                        .disabled(!model.viewModified)
                    Divider()
                    Button("Rename view…") { nameDraft = current.name; naming = .rename }
                    Button("Duplicate view") { model.duplicateView(current.id) }
                    Button("Delete view", role: .destructive) { model.deleteView(current.id) }
                    Divider()
                    Button("Leave view (keep settings)") { model.currentViewID = nil }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "tablecells").font(.system(size: 11))
                    Text(model.currentView?.name ?? "Unsaved view").lineLimit(1)
                }
                .font(Theme.body)
                .foregroundStyle(Theme.ink)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Views: saved combinations of filter, grouping, sort and hidden fields")
            .popover(item: $naming) { mode in
                VStack(alignment: .leading, spacing: Theme.space2) {
                    Text(mode == .saveAs ? "Save this filter and grouping as a view" : "Rename view")
                        .font(Theme.caption).foregroundStyle(Theme.inkMuted)
                    TextField("View name, e.g. Warm-up set", text: $nameDraft)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                        .onSubmit(commitName)
                    Text(model.organizeView.summary(model.records)).font(Theme.caption).foregroundStyle(Theme.inkFaint)
                    HStack {
                        Spacer()
                        Button("Cancel") { naming = nil }.buttonStyle(FlatButtonStyle())
                        Button(mode == .saveAs ? "Save view" : "Rename", action: commitName)
                            .buttonStyle(FlatButtonStyle(primary: true))
                    }
                }
                .padding(Theme.space3)
            }
            if model.viewModified {
                Text("Edited").font(Theme.caption).foregroundStyle(TagDef.textColor)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(TagStore.palette[4]).clipShape(Capsule())
                Button("Save") { model.updateCurrentView() }.buttonStyle(FlatButtonStyle())
                    .help("Save these settings into “\(model.currentView?.name ?? "")”")
                Button("Revert") { model.revertCurrentView() }.buttonStyle(FlatButtonStyle())
            } else if model.currentView == nil && model.organizeView != ViewSettings() {
                Button("Save as view…") { nameDraft = ""; naming = .saveAs }
                    .buttonStyle(FlatButtonStyle())
                    .help("Keep this filter and grouping as a template you can switch back to")
            }
            Rectangle().fill(Theme.line).frame(width: 1, height: 18).padding(.horizontal, Theme.space1)
        }
    }

    private func commitName() {
        switch naming {
        case .saveAs: model.saveViewAs(nameDraft)
        case .rename: if let id = model.currentViewID { model.renameView(id, to: nameDraft) }
        case nil: break
        }
        naming = nil
    }

    private func toolbarButton(_ title: String, icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 11))
                Text(title).lineLimit(1)
            }
            .font(Theme.caption)
            .foregroundStyle(active ? TagDef.textColor : Theme.inkMuted)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(active ? TagStore.palette[3] : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMd))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var grid: some View {
        let focusedAnalysis = focused.flatMap { analysis.analysis(for: $0) }
        return RecordGrid(
            model: model,
            records: records,
            view: viewBinding,
            mixes: { r in
                guard let a = focusedAnalysis, let b = r.analysis, r.id != focused else { return false }
                return Compatibility.mixes(a, b)
            },
            menu: { AnyView(contextMenu($0)) })
        .overlay {
            if dropTargeted { Rectangle().strokeBorder(Theme.accent, lineWidth: 2) }
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
            } else if records.isEmpty && !model.organizeView.conditions.isEmpty {
                VStack(spacing: Theme.space2) {
                    Text("No tracks match the filter").font(Theme.body).foregroundStyle(Theme.inkMuted)
                    Button("Clear filter") { model.organizeView.conditions = [] }.buttonStyle(FlatButtonStyle())
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
        Menu("Tags") {
            let paths = ordered.map(\.path)
            ForEach(library.tags.manualTags) { tag in
                let all = paths.allSatisfy { library.tags.ids(for: $0).contains(tag.id) }
                Button {
                    library.tags.set(tag.id, on: paths, !all)
                } label: {
                    Label(tag.name, systemImage: all ? "checkmark" : "circle")
                }
            }
            if !library.tags.manualTags.isEmpty { Divider() }
            Button("New tag…") {
                let id = library.tags.create(name: "New tag")
                library.tags.set(id, on: paths, true)
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
        model.organizeView.sortField = nil
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

// MARK: Key wheel

/// A key: wheel position 1–12 and mood (minor = Dark).
struct KeySlot: Hashable {
    let number: Int
    let minor: Bool
    init(number: Int, minor: Bool) { self.number = number; self.minor = minor }
    init(_ a: TrackAnalysis) { number = a.camelotNumber; minor = a.keyMinor }
    var label: String { "\(number) \(KeyStyle.mood(minor: minor))" }
}

/// The 12 key colours as a wheel: Bright keys in the outer ring, Dark keys
/// in the inner ring. Each slice shows how many tracks are in that key.
/// With a track selected, its slice is outlined in accent and the slices
/// that mix with it in green; the rest fade. Click a slice to show only
/// its tracks.
struct KeyWheel: View {
    let rows: [OrganizeRow]
    let focused: URL?
    @Binding var filter: KeySlot?
    @State private var hovered: KeySlot?

    private var counts: [KeySlot: Int] {
        var c: [KeySlot: Int] = [:]
        for row in rows { if let a = row.analysis { c[KeySlot(a), default: 0] += 1 } }
        return c
    }

    private var focusedSlot: KeySlot? {
        rows.first { $0.id == focused }?.analysis.map(KeySlot.init)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                LabelText("Key wheel")
                Spacer()
                if let filter {
                    Button {
                        self.filter = nil
                    } label: {
                        HStack(spacing: 4) {
                            Circle().fill(KeyStyle.color(number: filter.number, minor: filter.minor)).frame(width: 8, height: 8)
                            Text("Showing \(filter.label)")
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                        }
                        .font(Theme.caption)
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Theme.control)
                    }
                    .buttonStyle(.plain)
                    .help("Show all keys again")
                }
            }
            .padding(.horizontal, Theme.space3)
            .frame(height: 34)
            .background(Theme.panelRaised)
            GeometryReader { geo in
                let size = min(geo.size.width, geo.size.height)
                let centre = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                let radius = size / 2 - 22
                Canvas { context, _ in draw(context, centre: centre, radius: radius) }
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        if case .active(let p) = phase { hovered = slot(at: p, centre: centre, radius: radius) } else { hovered = nil }
                    }
                    .onTapGesture(coordinateSpace: .local) { p in
                        guard let s = slot(at: p, centre: centre, radius: radius) else { return }
                        filter = filter == s ? nil : s
                    }
            }
            .padding(Theme.space2)
            Text(caption)
                .font(Theme.caption)
                .foregroundStyle(Theme.inkMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.space3)
                .padding(.bottom, Theme.space2)
        }
        .background(Theme.panel)
    }

    private var caption: String {
        if let h = hovered {
            let n = counts[h] ?? 0
            return "Key \(h.label): \(n) track\(n == 1 ? "" : "s"). Click to \(filter == h ? "show all keys" : "show only these")."
        }
        if focusedSlot != nil {
            return "Orange: the selected track. Green: keys that mix with it."
        }
        return "Outer ring: Bright keys · inner ring: Dark keys. Neighbouring slices mix well. Click a slice to show its tracks."
    }

    // Rings as fractions of the radius.
    private let inner: CGFloat = 0.30, middle: CGFloat = 0.64

    private func angle(_ number: Int) -> Double { Double(number - 1) * 30 - 90 }   // 1 at the top, clockwise

    private func slot(at p: CGPoint, centre: CGPoint, radius: CGFloat) -> KeySlot? {
        let dx = p.x - centre.x, dy = p.y - centre.y
        let r = (dx * dx + dy * dy).squareRoot() / radius
        guard r >= inner && r <= 1 else { return nil }
        var deg = atan2(Double(dy), Double(dx)) * 180 / .pi + 90 + 15
        deg = deg.truncatingRemainder(dividingBy: 360)
        if deg < 0 { deg += 360 }
        return KeySlot(number: Int(deg / 30) % 12 + 1, minor: r < middle)
    }

    private func sector(_ s: KeySlot, centre: CGPoint, radius: CGFloat) -> Path {
        let a0 = Angle.degrees(angle(s.number) - 15 + 0.8), a1 = Angle.degrees(angle(s.number) + 15 - 0.8)
        let r0 = radius * (s.minor ? inner : middle) + 1, r1 = radius * (s.minor ? middle : 1) - 1
        var path = Path()
        path.addArc(center: centre, radius: r1, startAngle: a0, endAngle: a1, clockwise: false)
        path.addArc(center: centre, radius: r0, startAngle: a1, endAngle: a0, clockwise: true)
        path.closeSubpath()
        return path
    }

    private func point(_ number: Int, _ r: CGFloat, centre: CGPoint) -> CGPoint {
        let a: Double = angle(number) * Double.pi / 180
        return CGPoint(x: centre.x + CGFloat(Foundation.cos(a)) * r, y: centre.y + CGFloat(Foundation.sin(a)) * r)
    }

    private func draw(_ context: GraphicsContext, centre: CGPoint, radius: CGFloat) {
        let counts = counts
        let most = max(counts.values.max() ?? 1, 1)
        let focus = focusedSlot
        var mixes = Set<KeySlot>()
        if let f = focus {
            mixes.insert(f)
            mixes.insert(KeySlot(number: f.number, minor: !f.minor))
            mixes.insert(KeySlot(number: f.number % 12 + 1, minor: f.minor))
            mixes.insert(KeySlot(number: (f.number + 10) % 12 + 1, minor: f.minor))
        }

        for n in 1...12 {
            for minor in [true, false] {
                let s = KeySlot(number: n, minor: minor)
                let count = counts[s] ?? 0
                let path = sector(s, centre: centre, radius: radius)
                let dimmed = (focus != nil && !mixes.contains(s)) || (filter != nil && filter != s)
                let strength = count == 0 ? 0.18 : 0.6 + 0.4 * Double(count) / Double(most)
                context.fill(path, with: .color(KeyStyle.color(number: n, minor: minor).opacity(strength * (dimmed ? 0.35 : 1))))
                if s == hovered { context.stroke(path, with: .color(Theme.ink), lineWidth: 1.5) }
                if let focus, mixes.contains(s) && s != focus { context.stroke(path, with: .color(Theme.match), lineWidth: 2) }
                if s == focus || s == filter { context.stroke(path, with: .color(Theme.accent), lineWidth: 2.5) }
                if count > 0 {
                    let mid = radius * (minor ? (inner + middle) / 2 : (middle + 1) / 2)
                    var label = context
                    label.addFilter(.shadow(color: .black.opacity(dimmed ? 0 : 0.6), radius: 2))
                    label.draw(Text("\(count)").font(Theme.readout).foregroundStyle(dimmed ? Theme.inkMuted : .white),
                               at: point(n, mid, centre: centre))
                }
            }
            // Wheel number outside the ring.
            context.draw(Text("\(n)").font(Theme.readoutSm).foregroundStyle(Theme.inkMuted),
                         at: point(n, radius + 12, centre: centre))
        }
        context.draw(Text("BRIGHT").font(Theme.label).foregroundStyle(Theme.inkFaint),
                     at: CGPoint(x: centre.x, y: centre.y - radius * 0.08))
        context.draw(Text("DARK").font(Theme.label).foregroundStyle(Theme.inkFaint),
                     at: CGPoint(x: centre.x, y: centre.y + radius * 0.10))
    }
}

// MARK: Tags

/// Small coloured tag labels for a table row or clip.
struct TagChips: View {
    let tags: [TagDef]
    var body: some View {
        HStack(spacing: 3) {
            ForEach(tags.prefix(3)) { tag in
                Text(tag.name)
                    .font(Theme.caption)
                    .lineLimit(1)
                    .foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 4)
                    .background(tag.color.opacity(0.85))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSm))
            }
            if tags.count > 3 { Text("+\(tags.count - 3)").font(Theme.caption).foregroundStyle(Theme.inkFaint) }
        }
        .help(tags.map(\.name).joined(separator: ", "))
    }
}

/// Make or change a tempo group: a BPM range (and optionally energy and
/// mood) that tracks join by themselves.
struct TempoGroupEditor: View {
    @State var group: TagDef
    let library: LibraryModel
    let onSave: (TagDef) -> Void
    @Environment(\.dismiss) private var dismiss

    private var rule: TagRule { group.rule ?? TagRule() }

    private func edit(_ change: (inout TagRule) -> Void) {
        var r = rule
        change(&r)
        group.rule = r
    }

    private var matching: Int {
        library.allTracks.filter { t in library.analysisLookup(t.url).map(rule.matches) ?? false }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.space3) {
            Text(group.name.isEmpty ? "New tempo group" : group.name).font(Theme.title).foregroundStyle(Theme.ink)
            Text("Tracks in this BPM range join the group by themselves, including ones you add later.")
                .font(Theme.caption).foregroundStyle(Theme.inkMuted)
            TextField("Name (leave empty to use the range)", text: $group.name)
                .textFieldStyle(.roundedBorder)
            Grid(alignment: .leading, horizontalSpacing: Theme.space3, verticalSpacing: Theme.space2) {
                GridRow {
                    Text("From").foregroundStyle(Theme.inkMuted)
                    Stepper(value: Binding(get: { rule.minBPM }, set: { v in edit { $0.minBPM = min(v, $0.maxBPM) } }), in: 60...200, step: 1) {
                        Text(String(format: "%.0f BPM", rule.minBPM)).font(Theme.readout).frame(width: 90, alignment: .leading)
                    }
                }
                GridRow {
                    Text("To").foregroundStyle(Theme.inkMuted)
                    Stepper(value: Binding(get: { rule.maxBPM }, set: { v in edit { $0.maxBPM = max(v, $0.minBPM) } }), in: 60...200, step: 1) {
                        Text(String(format: "%.0f BPM", rule.maxBPM)).font(Theme.readout).frame(width: 90, alignment: .leading)
                    }
                }
                GridRow {
                    Text("Energy").foregroundStyle(Theme.inkMuted)
                    HStack {
                        Stepper("\(rule.minEnergy)", value: Binding(get: { rule.minEnergy }, set: { v in edit { $0.minEnergy = min(v, $0.maxEnergy) } }), in: 1...10)
                        Text("to")
                        Stepper("\(rule.maxEnergy)", value: Binding(get: { rule.maxEnergy }, set: { v in edit { $0.maxEnergy = max(v, $0.minEnergy) } }), in: 1...10)
                    }
                }
                GridRow {
                    Text("Mood").foregroundStyle(Theme.inkMuted)
                    Picker("", selection: Binding(get: { rule.minor.map { $0 ? 1 : 2 } ?? 0 },
                                                  set: { v in edit { $0.minor = v == 0 ? nil : v == 1 } })) {
                        Text("Any").tag(0)
                        Text("Dark").tag(1)
                        Text("Bright").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                }
            }
            .font(Theme.body)
            HStack(spacing: Theme.space2) {
                Image(systemName: rule.span <= 0.06 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(rule.span <= 0.06 ? Theme.match : Theme.warn)
                Text(rule.span <= 0.06
                     ? String(format: "Range %.1f%%: every track mixes with every other with a small tempo change.", rule.span * 100)
                     : String(format: "Range %.1f%%: the outer tracks are far apart; keep it under 6%% for easy mixing.", rule.span * 100))
                    .font(Theme.caption).foregroundStyle(Theme.inkMuted)
            }
            Text("\(matching) tracks match").font(Theme.readoutSm).foregroundStyle(Theme.ink)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(FlatButtonStyle())
                Button("Save") {
                    var saved = group
                    if saved.name.trimmingCharacters(in: .whitespaces).isEmpty { saved.name = String(format: "%.0f–%.0f BPM", rule.minBPM, rule.maxBPM) }
                    saved.automatic = false
                    onSave(saved)
                    dismiss()
                }
                .buttonStyle(FlatButtonStyle(primary: true))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.space4)
        .frame(width: 440)
        .background(Theme.panel)
        .preferredColorScheme(.dark)
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
    /// Tempo group being edited (or a new one).
    @State private var editingGroup: TagDef?
    @State private var editingTags = false

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
                    viewsSection
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
                    tagSection
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

    // MARK: Views

    @ViewBuilder
    private var viewsSection: some View {
        sectionHeader("Views") {
            Button("Save current as view") {
                let id = model.saveViewAs("View \(model.savedViews.count + 1)")
                draft = model.savedViews.first { $0.id == id }?.name ?? ""
                renaming = id
            }
        }
        ForEach(model.savedViews) { v in viewRow(v) }
        if model.savedViews.isEmpty {
            Text("Set a filter and grouping on the grid, then save it here to switch back with one click.")
                .font(Theme.caption).foregroundStyle(Theme.inkFaint)
                .padding(.horizontal, Theme.space3)
        }
    }

    private func viewRow(_ v: SavedView) -> some View {
        let selected = model.currentViewID == v.id
        return HStack(spacing: Theme.space1) {
            Spacer().frame(width: 10)
            Image(systemName: "tablecells").font(.system(size: 11)).frame(width: 14)
            if renaming == v.id {
                TextField("Name", text: $draft)
                    .textFieldStyle(.plain)
                    .font(Theme.body)
                    .onSubmit { model.renameView(v.id, to: draft); renaming = nil }
                    .onExitCommand { renaming = nil }
            } else {
                Text(v.name).font(Theme.body).lineLimit(1)
            }
            Spacer()
            if selected && model.viewModified {
                Circle().fill(TagStore.palette[4]).frame(width: 6, height: 6).help("Edited, not saved")
            }
        }
        .foregroundStyle(selected ? Theme.ink : Theme.inkMuted)
        .padding(.leading, Theme.space2)
        .padding(.trailing, Theme.space3)
        .padding(.vertical, 5)
        .background(selected ? Theme.accentSoft : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { draft = v.name; renaming = v.id }
        .onTapGesture { model.applyView(v.id) }
        .help(v.settings.summary(model.records))
        .contextMenu {
            Button("Rename") { draft = v.name; renaming = v.id }
            Button("Duplicate") { model.duplicateView(v.id) }
            if selected && model.viewModified {
                Button("Save changes") { model.updateCurrentView() }
                Button("Revert changes") { model.revertCurrentView() }
            }
            Divider()
            Button("Delete view", role: .destructive) { model.deleteView(v.id) }
        }
    }

    // MARK: Tags

    private var tagStore: TagStore { library.tags }

    @ViewBuilder
    private var tagSection: some View {
        sectionHeader("Tags") {
            Button("New tag") {
                let id = tagStore.create(name: "New tag")
                draft = "New tag"
                renaming = id
            }
            Button("Edit tags…") { editingTags = true }
        }
        ForEach(tagStore.manualTags) { tag in tagRow(tag) }
        if tagStore.manualTags.isEmpty {
            Text("Add tags in the Tags column: click a cell, type a name, press Enter.")
                .font(Theme.caption).foregroundStyle(Theme.inkFaint)
                .padding(.horizontal, Theme.space3)
        }
        sectionHeader("Tempo groups") {
            Button("Make tempo groups") { makeTempoGroups() }
            Button("New tempo group…") {
                editingGroup = TagDef(name: "", colorIndex: tagStore.tempoGroups.count, rule: TagRule())
            }
        }
        ForEach(tagStore.tempoGroups) { tag in groupRow(tag) }
        if tagStore.tempoGroups.isEmpty {
            Text("Tempo groups collect tracks in a BPM range that mix with each other.")
                .font(Theme.caption).foregroundStyle(Theme.inkFaint)
                .padding(.horizontal, Theme.space3)
            Button("Make tempo groups") { makeTempoGroups() }
                .buttonStyle(FlatButtonStyle())
                .padding(Theme.space3)
                .help("Splits your tracks into BPM ranges no wider than 6%, so tracks in a group mix with a small tempo change")
        }
        EmptyView()
            .sheet(item: $editingGroup) { group in
                TempoGroupEditor(group: group, library: library) { saved in
                    if tagStore.tag(saved.id) != nil { tagStore.update(saved) }
                    else {
                        let id = tagStore.create(name: saved.name, rule: saved.rule)
                        library.tag = id
                    }
                }
            }
            .sheet(isPresented: $editingTags) {
                ManageOptionsView(
                    title: "Tags",
                    items: tagStore.manualTags.map { .init(id: $0.id.uuidString, name: $0.name, colorIndex: $0.colorIndex) },
                    onRename: { id, name in if var t = tagStore.tag(UUID(uuidString: id)), !name.isEmpty { t.name = name; tagStore.update(t) } },
                    onRecolor: { id, c in if var t = tagStore.tag(UUID(uuidString: id)) { t.colorIndex = c; tagStore.update(t) } },
                    onDelete: { id in if let u = UUID(uuidString: id) { tagStore.delete(u) } },
                    onMove: { tagStore.moveOptions(from: $0, to: $1) },
                    onAdd: { _ = tagStore.create(name: $0) })
            }
    }

    private func sectionHeader<M: View>(_ title: String, @ViewBuilder menu: () -> M) -> some View {
        HStack {
            LabelText(title)
            Spacer()
            Menu { menu() } label: {
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, Theme.space3)
        .padding(.top, Theme.space4)
        .padding(.bottom, Theme.space2)
    }

    /// Clicking a tag filters the grid to tracks that have it (Airtable's
    /// "Tags has any of …"), over all tracks.
    private func showTag(_ tag: TagDef) {
        library.selectAll()
        model.organizeView.conditions = [FilterCondition(field: .tags, op: .hasAny, options: [tag.id.uuidString])]
    }

    private func isShowing(_ tag: TagDef) -> Bool {
        let c = model.organizeView.conditions
        return c.count == 1 && c[0].field == .tags && c[0].op == .hasAny && c[0].options == [tag.id.uuidString]
    }

    private func makeTempoGroups() {
        let bpms = library.allTracks.compactMap { library.analysisLookup($0.url)?.bpm }
        tagStore.makeTempoGroups(bpms: bpms)
    }

    private func tagRow(_ tag: TagDef) -> some View {
        let selected = isShowing(tag)
        let count = tagStore.assigned.values.filter { $0.contains(tag.id) }.count
        return HStack(spacing: Theme.space1) {
            Spacer().frame(width: 10)
            if renaming == tag.id {
                TextField("Name", text: $draft)
                    .textFieldStyle(.plain)
                    .font(Theme.body)
                    .onSubmit {
                        var t = tag
                        let name = draft.trimmingCharacters(in: .whitespaces)
                        if !name.isEmpty { t.name = name; tagStore.update(t) }
                        renaming = nil
                    }
                    .onExitCommand { renaming = nil }
            } else {
                Pill(name: tag.name, color: tag.color)
            }
            Spacer()
            Text("\(count)").font(Theme.readoutSm)
        }
        .foregroundStyle(selected ? Theme.ink : Theme.inkMuted)
        .padding(.leading, Theme.space2)
        .padding(.trailing, Theme.space3)
        .padding(.vertical, 4)
        .background(selected ? Theme.accentSoft : (dropTarget == tag.id ? Theme.panelRaised : Color.clear))
        .overlay { if dropTarget == tag.id { Rectangle().strokeBorder(Theme.accent, lineWidth: 1) } }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { draft = tag.name; renaming = tag.id }
        .onTapGesture { if selected { model.organizeView.conditions = [] } else { showTag(tag) } }
        .help("Show tracks with this tag. Drag tracks here to tag them.")
        .dropDestination(for: URL.self) { urls, _ in
            tagStore.set(tag.id, on: PlaylistStore.audioFiles(in: urls).map(\.path), true)
            return true
        } isTargeted: { inside in
            if inside { dropTarget = tag.id } else if dropTarget == tag.id { dropTarget = nil }
        }
        .contextMenu {
            Button("Rename") { draft = tag.name; renaming = tag.id }
            Button("Edit tags…") { editingTags = true }
            Divider()
            Button("Delete tag", role: .destructive) {
                if isShowing(tag) { model.organizeView.conditions = [] }
                tagStore.delete(tag.id)
            }
        }
    }

    private func groupRow(_ tag: TagDef) -> some View {
        let selected = library.tag == tag.id
        let count = library.tracks(withTag: tag.id).count
        return HStack(spacing: Theme.space1) {
            Spacer().frame(width: 10)
            Image(systemName: "metronome").font(.system(size: 10)).frame(width: 14)
            Text(tag.name).font(Theme.body).lineLimit(1)
            if let rule = tag.rule, rule.minEnergy > 1 || rule.maxEnergy < 10 || rule.minor != nil {
                Image(systemName: "slider.horizontal.3").font(.system(size: 9)).foregroundStyle(Theme.inkFaint)
            }
            Spacer()
            Text("\(count)").font(Theme.readoutSm)
        }
        .foregroundStyle(selected ? Theme.ink : Theme.inkMuted)
        .padding(.leading, Theme.space2)
        .padding(.trailing, Theme.space3)
        .padding(.vertical, 5)
        .background(selected ? Theme.accentSoft : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { editingGroup = tag }
        .onTapGesture { library.tag = tag.id }
        .help(tag.rule.map { "Tempo group: \($0.summary). Tracks join by themselves." } ?? "")
        .contextMenu {
            Button("Edit range…") { editingGroup = tag }
            Divider()
            Button("Delete group", role: .destructive) {
                if library.tag == tag.id { library.selectAll() }
                tagStore.delete(tag.id)
            }
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

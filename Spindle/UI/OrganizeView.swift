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
    @State private var keys = OrganizeKeys()
    @AppStorage("organize.showArt") private var showArt = true
    @State private var showFilter = false
    @State private var showGroup = false
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
    }

    /// After the view's filter and sort.
    private var records: [Record] { model.records.apply(model.organizeView, to: baseRecords) }

    private var rows: [OrganizeRow] {
        records.map { OrganizeRow(track: $0.track, analysis: $0.analysis, index: $0.index) }
    }


    var body: some View {
        HStack(spacing: 1) {
            CrateList(library: library, model: model, keys: keys)
                .frame(width: 210)
                .simultaneousGesture(TapGesture().onEnded { keys.focus = .library })
            VStack(spacing: 1) {
                toolbar
                grid
                    .frame(minHeight: 200)
                    .overlay(alignment: .top) { if keys.focus == .tracks { Theme.accent.frame(height: 2) } }
                    .simultaneousGesture(TapGesture().onEnded { keys.focus = .tracks })
            }
            if showArt {
                AlbumArtPanel(model: model)
                    .frame(width: 320)
            }
        }
        .background(Theme.line)
        .onAppear {
            keys.install(model)
            model.openSet = nil       // the Set panel is gone; it only greyed rows
            // Don't start with the cursor in the search field.
            DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) }
        }
        .onDisappear {
            keys.remove()
            model.prepSetPlaying(false)
        }
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
                Button("New set from \(selection.count)") {
                    let id = library.playlists.create(name: "New set", folder: false, in: nil)
                    model.addToPlaylist(rows.filter { selection.contains($0.id) }.map(\.id), playlist: id)
                    library.playlist = id
                }
                .buttonStyle(FlatButtonStyle())
            }
            SearchField(text: $library.search)
                .frame(maxWidth: 180)
            Button { showArt.toggle() } label: {
                Image(systemName: "sidebar.right").font(.system(size: 12))
                    .foregroundStyle(showArt ? Theme.ink : Theme.inkMuted)
                    .frame(width: 24, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(showArt ? "Hide album art" : "Show album art")
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

    /// Tracks already in the open set are greyed in the list (not when the
    /// list shows that set itself).
    private var dimmedInSet: ((Record) -> Bool)? {
        guard let set = model.openSetNode, library.playlist != set.id else { return nil }
        let paths = Set(set.tracks)
        return { paths.contains($0.path) }
    }

    private var grid: some View {
        let recs = records
        let view = model.organizeView
        let _ = keys.order = (view.groupBy.map { by in
            model.records.group(recs, by: by).filter { !view.collapsed.contains($0.id) }.flatMap(\.records)
        } ?? recs).map(\.id)
        return RecordGrid(
            model: model,
            records: recs,
            view: viewBinding,
            mixes: { _ in false },
            menu: { AnyView(contextMenu($0)) },
            dimmed: dimmedInSet,
            listen: { AnyView(ListenCell(model: model, url: $0.track.url)) },
            listenWidth: ListenCell.width,
            follow: keys.follow)
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
                    Text("This set is empty").font(Theme.body).foregroundStyle(Theme.inkMuted)
                    Text("Drag tracks here from All tracks, or files and folders from Finder, or use Add files….")
                        .font(Theme.caption).foregroundStyle(Theme.inkFaint)
                }
            } else if recs.isEmpty && !model.organizeView.conditions.isEmpty {
                VStack(spacing: Theme.space2) {
                    Text("No tracks match the filter").font(Theme.body).foregroundStyle(Theme.inkMuted)
                    Button("Clear filter") { model.organizeView.conditions = [] }.buttonStyle(FlatButtonStyle())
                }
            }
        }
    }

    @ViewBuilder
    private func contextMenu(_ urls: Set<URL>) -> some View {
        // In list order, from the order the grid already worked out (this menu
        // is built for every row on every redraw).
        let ordered = urls.count == 1 ? Array(urls) : keys.order.filter(urls.contains)
        if let url = ordered.first {
            Button("Load into deck A") { Task { await model.load(url: url, into: model.decks[0]) } }
            Button("Load into deck B") { Task { await model.load(url: url, into: model.decks[1]) } }
            Divider()
        }
        Menu("Add to set") {
            ForEach(library.playlists.playlists, id: \.node.id) { item in
                Button(item.path) { model.addToPlaylist(ordered, playlist: item.node.id) }
            }
            if !library.playlists.playlists.isEmpty { Divider() }
            Button("New set…") {
                let id = library.playlists.create(name: "New set", folder: false, in: nil)
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
                GridRow {
                    Text("Half / double").foregroundStyle(Theme.inkMuted)
                    Toggle("Also match at half or double the tempo",
                           isOn: Binding(get: { rule.octaves == true }, set: { v in edit { $0.octaves = v ? true : nil } }))
                }
            }
            .font(Theme.body)
            HStack(spacing: Theme.space2) {
                Image(systemName: rule.span <= 0.05 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(rule.span <= 0.05 ? Theme.match : Theme.warn)
                Text(rule.span <= 0.05
                     ? String(format: "Range %.1f%%: every track mixes with every other with a small tempo change.", rule.span * 100)
                     : String(format: "Range %.1f%%: the outer tracks are far apart; keep it under 5%% to mix without audible stretching.", rule.span * 100))
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
    /// Organize: clicking a set opens it in the right panel (the list stays).
    var opensSets = false
    /// Organize's keys: the list hands them its rows, in order.
    var keys: OrganizeKeys?
    @State private var renaming: UUID?
    @FocusState private var renameFocus: Bool
    @State private var draft = ""
    @State private var collapsed = Set<UUID>()
    @State private var dropTarget: UUID?
    @State private var pendingDelete: PlaylistNode?
    /// Tempo group being edited (or a new one).
    @State private var editingGroup: TagDef?
    @State private var editingTags = false
    @State private var showDeleted = false
    @State private var showFolders = false

    private var store: PlaylistStore { library.playlists }

    /// Every row the arrow keys can reach, top to bottom.
    private var navItems: [LibraryNavItem] {
        var items: [LibraryNavItem] = []
        items.append(.init(selected: library.crate == nil && library.playlist == nil && library.tag == nil && library.smart == nil,
                           activate: { library.selectAll() }))
        for smart in LibraryModel.SmartList.allCases {
            items.append(.init(selected: library.smart == smart, activate: { library.smart = smart }))
        }
        if showFolders {
            for crate in library.crates {
                items.append(.init(selected: library.crate == crate, activate: { library.crate = crate }))
            }
        }
        func walk(_ parent: UUID?) {
            for node in store.children(of: parent) {
                let open = node.isFolder && !collapsed.contains(node.id)
                items.append(.init(selected: library.playlist == node.id,
                                   activate: { library.playlist = node.id },
                                   rename: { draft = node.name; renaming = node.id },
                                   expand: node.isFolder ? { on in
                                       if on { collapsed.remove(node.id) } else { collapsed.insert(node.id) }
                                   } : nil))
                if open { walk(node.id) }
            }
        }
        walk(nil)
        for tag in tagStore.manualTags {
            let showing = isShowing(tag)
            items.append(.init(selected: showing, activate: { if !isShowing(tag) { showTag(tag) } },
                               rename: { draft = tag.name; renaming = tag.id }))
        }
        for tag in tagStore.tempoGroups {
            items.append(.init(selected: library.tag == tag.id, activate: { library.tag = tag.id },
                               rename: { editingGroup = tag }))
        }
        return items
    }

    var body: some View {
        let _ = keys?.libraryItems = navItems
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    sectionHeader("Library", icon: "ellipsis") {
                        Button("Choose music folder…") {
                            Task {
                                await library.chooseFolder()
                                await model.analysis.analyze(library.allTracks.map(\.url))
                                await model.prepareAll()
                            }
                        }
                    }
                    plainRow(title: "All tracks", count: library.tracks.count,
                             selected: library.crate == nil && library.playlist == nil && library.tag == nil && library.smart == nil) { library.selectAll() }
                    ForEach(LibraryModel.SmartList.allCases) { smart in
                        plainRow(title: smart.rawValue, count: library.tracks(in: smart).count,
                                 selected: library.smart == smart, icon: "line.3.horizontal.decrease") { library.smart = smart }
                    }
                    Button { showFolders.toggle() } label: {
                        HStack(spacing: Theme.space1) {
                            Image(systemName: showFolders ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold)).frame(width: 10)
                            Image(systemName: "folder").font(.system(size: 11)).frame(width: 14)
                            Text("Folders").font(Theme.body)
                            Spacer()
                            Text("\(library.crates.count)").font(Theme.readoutSm)
                        }
                        .foregroundStyle(Theme.inkMuted)
                        .padding(.leading, Theme.space2).padding(.trailing, Theme.space3).padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if showFolders {
                        ForEach(library.crates, id: \.self) { crate in
                            plainRow(title: crate, count: library.tracks.filter { $0.crate == crate }.count,
                                     selected: library.crate == crate, icon: "folder") { library.crate = crate }.padding(.leading, 14)
                        }
                    }
                    HStack {
                        LabelText("Sets")
                        Spacer()
                        Menu {
                            Button("New set") { create(folder: false, in: nil) }
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
                    recentlyDeleted
                    tagSection
                }
            }
        }
        .frame(maxHeight: .infinity)
        .background(Theme.panel)
        .overlay(alignment: .top) {
            // Which pane the keys work in (press 1 or 2).
            if keys?.focus == .library { Theme.accent.frame(height: 2) }
        }
        .onChange(of: renameFocus) { _, focused in
            if !focused { renaming = nil; DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) } }
        }
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
                 ? "The folder and its playlists move to Recently deleted, where you can restore them for 30 days. Your audio files stay where they are."
                 : "The playlist moves to Recently deleted, where you can restore it for 30 days. Your audio files stay where they are.")
        }
    }

    // MARK: Recently deleted

    @ViewBuilder
    private var recentlyDeleted: some View {
        if !store.trash.isEmpty {
            Button { showDeleted.toggle() } label: {
                HStack(spacing: Theme.space1) {
                    Image(systemName: showDeleted ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold)).frame(width: 10)
                    Image(systemName: "trash").font(.system(size: 11)).frame(width: 14)
                    Text("Recently deleted").font(Theme.body)
                    Spacer()
                    Text("\(store.trash.count)").font(Theme.readoutSm)
                }
                .foregroundStyle(Theme.inkMuted)
                .padding(.leading, Theme.space2)
                .padding(.trailing, Theme.space3)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Deleted playlists are kept here for 30 days")
            if showDeleted {
                ForEach(store.trash) { entry in
                    HStack(spacing: Theme.space1) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.name).font(Theme.body).foregroundStyle(Theme.inkMuted).lineLimit(1)
                            Text("\(entry.trackCount) tracks · \(entry.deleted.formatted(date: .abbreviated, time: .shortened))")
                                .font(Theme.caption).foregroundStyle(Theme.inkFaint)
                        }
                        Spacer()
                        Button("Restore") { store.restore(entry) }
                            .buttonStyle(.plain).font(Theme.caption).foregroundStyle(Theme.ink)
                    }
                    .padding(.leading, Theme.space2 + 24)
                    .padding(.trailing, Theme.space3)
                    .padding(.vertical, 3)
                    .contextMenu {
                        Button("Restore") { store.restore(entry) }
                        Button("Delete permanently", role: .destructive) { store.purge(entry) }
                    }
                }
            }
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
        .onTapGesture { model.applyView(v.id) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { draft = v.name; renaming = v.id })
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
        sectionHeader("Tempo groups") {
            Button("Make tempo groups") { makeTempoGroups() }
            Button("Make genre groups") { tagStore.makeGenreGroups() }
            Button("New tempo group…") {
                editingGroup = TagDef(name: "", colorIndex: tagStore.tempoGroups.count, rule: TagRule())
            }
        }
        ForEach(tagStore.tempoGroups) { tag in groupRow(tag) }
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

    private func sectionHeader<M: View>(_ title: String, icon: String = "plus", @ViewBuilder menu: () -> M) -> some View {
        HStack {
            LabelText(title)
            Spacer()
            Menu { menu() } label: {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, Theme.space3)
        .padding(.top, title == "Library" ? Theme.space2 : Theme.space4)
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
                    .focused($renameFocus)
                    .onAppear { renameFocus = true }
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
        .onTapGesture { if selected { model.organizeView.conditions = [] } else { showTag(tag) } }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            if !isShowing(tag) { showTag(tag) }        // the second click toggled it off
            draft = tag.name; renaming = tag.id
        })
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
        .onTapGesture { library.tag = tag.id }
        .simultaneousGesture(TapGesture(count: 2).onEnded { editingGroup = tag })
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
        let id = store.create(name: folder ? "New folder" : "New set", folder: folder, in: parent)
        if let parent { collapsed.remove(parent) }
        if !folder { if opensSets { model.openSet = id } else { library.playlist = id } }
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
        let selected = opensSets && !node.isFolder ? model.openSet == node.id : library.playlist == node.id
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
                    .focused($renameFocus)
                    .onAppear { renameFocus = true }
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
        .onTapGesture {
            if opensSets && !node.isFolder { model.openSet = node.id } else { library.playlist = node.id }
        }
        // Acts on the first click; a double-click renames (onTapGesture(count: 2)
        // made every single click wait ~0.3 s).
        .simultaneousGesture(TapGesture(count: 2).onEnded { draft = node.name; renaming = node.id })
        .dropDestination(for: URL.self) { urls, _ in
            guard !node.isFolder else { return false }
            model.addToPlaylist(urls, playlist: node.id)
            return true
        } isTargeted: { inside in
            if inside && !node.isFolder { dropTarget = node.id } else if dropTarget == node.id { dropTarget = nil }
        }
        .contextMenu {
            Button("Rename") { draft = node.name; renaming = node.id }
            if opensSets && !node.isFolder {
                Button("Show as list") { library.playlist = node.id }
            }
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

/// Organize's listen column: play / pause and the whole track as a tiny
/// waveform. Click or drag on the waveform to play from there.
struct ListenCell: View {
    let model: AppModel
    let url: URL
    static let width: CGFloat = 150

    var body: some View {
        let page = model.prepPage
        let current = page.selected == url
        let playing = current && (page.playing || page.playWhenLoaded != nil)
        HStack(spacing: 4) {
            Button { model.listen(url, at: nil) } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 9))
                    .frame(width: 20, height: 20)
                    .foregroundStyle(playing ? Theme.ink : Theme.inkMuted)
                    .background(current ? Theme.control : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSm))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(playing ? "Pause" : "Pre-listen")
            MiniWaveform(model: model, url: url, current: current, playing: page.playing && current)
        }
        .padding(.horizontal, 6)
        .task(id: url) { model.overviews.request(url) }
    }
}

private struct MiniWaveform: View {
    let model: AppModel
    let url: URL
    let current: Bool
    let playing: Bool

    var body: some View {
        let data = model.overviews.overview(for: url)
        GeometryReader { geo in
            TimelineView(.periodic(from: .now, by: playing ? 1.0 / 15 : 3600)) { _ in
                let progress = current && model.prepDuration > 0 ? model.prepPosition / model.prepDuration : -1
                Canvas { context, size in draw(context, size, data, progress) }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let f = min(max(g.location.x / max(geo.size.width, 1), 0), 1)
                if current, model.prepPage.preview?.url == url { model.prepSeek(to: f * model.prepDuration) }
            }.onEnded { g in
                model.listen(url, at: min(max(g.location.x / max(geo.size.width, 1), 0), 0.999))
            })
        }
        .frame(height: 22)
    }

    private func draw(_ context: GraphicsContext, _ size: CGSize, _ data: TrackOverviewData?, _ progress: Double) {
        let mid = size.height / 2, half = size.height / 2
        guard let data, data.peak.count > 1 else {
            context.fill(Path(CGRect(x: 0, y: mid - 0.5, width: size.width, height: 1)), with: .color(Theme.line))
            return
        }
        let n = data.peak.count
        let px = size.width * CGFloat(max(progress, 0))
        func shape(_ v: Data) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: 0, y: mid))
            for i in 0..<n {
                let x = CGFloat(i) / CGFloat(n - 1) * size.width
                p.addLine(to: CGPoint(x: x, y: mid - max(0.5, CGFloat(v[i]) / 255 * half)))
            }
            for i in (0..<n).reversed() {
                let x = CGFloat(i) / CGFloat(n - 1) * size.width
                p.addLine(to: CGPoint(x: x, y: mid + max(0.5, CGFloat(v[i]) / 255 * half)))
            }
            p.closeSubpath()
            return p
        }
        let peak = shape(data.peak), loud = shape(data.loud)
        let ahead = current ? Theme.inkMuted : Theme.inkFaint
        context.fill(peak, with: .color(ahead.opacity(0.45)))
        context.fill(loud, with: .color(ahead))
        if progress >= 0 {
            var played = context
            played.clip(to: Path(CGRect(x: 0, y: 0, width: px, height: size.height)))
            played.fill(peak, with: .color(Theme.prep.opacity(0.45)))
            played.fill(loud, with: .color(Theme.prep))
            context.fill(Path(CGRect(x: px - 0.5, y: 0, width: 1, height: size.height)), with: .color(Theme.accent))
        }
    }
}

/// Organize's keys, while the page is open and no text field has focus:
/// ↑ ↓ move through the list, space plays or stops the selected track,
/// ← → skip 10 seconds.
@Observable
final class OrganizeKeys {
    enum Pane { case library, tracks }
    /// Where the arrow keys work: 1 = library, 2 = track list.
    var focus: Pane = .tracks
    /// The library's rows, top to bottom, refreshed on every redraw.
    @ObservationIgnored var libraryItems: [LibraryNavItem] = []
    /// The row to keep in view (moved to with the arrow keys).
    var follow: URL?
    /// Rows in display order, refreshed on every redraw.
    @ObservationIgnored var order: [URL] = []
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

    private func handle(_ event: NSEvent, _ model: AppModel) -> Bool {
        // Typing in a field keeps its keys, except space in an empty field
        // and Escape, which hand the keys back.
        if let text = event.window?.firstResponder as? NSText {
            guard event.keyCode == 53 || (event.keyCode == 49 && text.string.isEmpty) else { return false }
            event.window?.makeFirstResponder(nil)
            if event.keyCode == 53 { return true }
        }
        let flags = event.modifierFlags.intersection([.command, .control, .option])
        guard flags.isEmpty else { return false }
        let selection = model.organizeSelection
        // The row the keys act on: the one moved to last, else the first selected.
        let current = follow.flatMap { selection.contains($0) ? $0 : nil } ?? order.first(where: selection.contains)

        switch event.keyCode {
        case 18: focus = .library; return true            // 1
        case 19: focus = .tracks; return true             // 2
        default: break
        }
        if focus == .library, handleLibrary(event) { return true }

        switch event.keyCode {
        case 125, 126:                                    // ↓ ↑
            guard !order.isEmpty else { return true }
            let step = event.keyCode == 125 ? 1 : -1
            let index = current.flatMap { order.firstIndex(of: $0) }.map { $0 + step } ?? (step > 0 ? 0 : order.count - 1)
            let next = order[min(max(index, 0), order.count - 1)]
            model.organizeSelection = [next]
            follow = next
        case 49:                                          // space
            if let url = current { model.listen(url, at: nil) }
        case 123, 124:                                    // ← →
            if model.prepPage.preview != nil { model.prepSeek(by: event.keyCode == 124 ? 10 : -10) }
        default:
            return false
        }
        return true
    }

    /// Library pane: ↑ ↓ move and show that list, Return renames,
    /// ← → close and open folders.
    private func handleLibrary(_ event: NSEvent) -> Bool {
        let items = libraryItems
        guard !items.isEmpty else { return false }
        let current = items.firstIndex(where: \.selected)
        switch event.keyCode {
        case 125, 126:
            let step = event.keyCode == 125 ? 1 : -1
            let next = current.map { min(max($0 + step, 0), items.count - 1) } ?? 0
            items[next].activate()
            return true
        case 36, 76:                                      // Return
            guard let current, let rename = items[current].rename else { return false }
            rename()
            return true
        case 123, 124:                                    // ← →
            guard let current, let expand = items[current].expand else { return false }
            expand(event.keyCode == 124)
            return true
        default:
            return false
        }
    }
}

/// One row of the library list, for the keys.
struct LibraryNavItem {
    var selected: Bool
    var activate: () -> Void
    var rename: (() -> Void)? = nil
    /// Folders: open (true) or close (false).
    var expand: ((Bool) -> Void)? = nil
}

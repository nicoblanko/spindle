//
//  SharedTrackList.swift
//  Spindle
//
//  The Organize track list, reused on Prep and Mix: the same grid, the
//  same sidebar selection (All tracks, smart lists, sets, tags, tempo
//  groups) and search, with each page keeping its own columns, filter,
//  grouping and sort. Your saved views can be applied from the Views menu.
//

import SwiftUI

extension AppModel {
    /// The list settings of a page ("prep", "mix").
    func pageView(_ key: String) -> ViewSettings {
        if let v = mixTabViews[key] { return v }
        var v = ViewSettings()
        let keep: [FieldRef] = key == "prep" ? [.name, .mixReady, .bpm, .key] : [.name, .bpm, .key, .energy, .tags, .length]
        v.hidden = Set(records.allFields).subtracting(keep)
        return v
    }

    func setPageView(_ key: String, _ view: ViewSettings) { mixTabViews[key] = view }
}

struct SharedTrackList: View {
    let model: AppModel
    @Bindable var library: LibraryModel
    /// "prep" or "mix": whose columns and filters these are.
    let key: String
    var selection: Binding<Set<URL>>
    var onOpen: ((Record) -> Void)? = nil
    var dimmed: ((Record) -> Bool)? = nil
    var nameWidth: CGFloat = 300
    /// Extra controls at the right of the toolbar.
    var trailing: AnyView? = nil
    @State private var showFilter = false
    @State private var showGroup = false
    @State private var showHide = false

    private var view: Binding<ViewSettings> {
        Binding(get: { model.pageView(key) }, set: { model.setPageView(key, $0) })
    }

    private var records: [Record] {
        let base = library.visibleTracks.enumerated().map {
            Record(track: $1, analysis: model.analysis.analysis(for: $1.url), index: $0 + 1)
        }
        return model.records.apply(view.wrappedValue, to: base)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(Theme.line).frame(height: 1)
            RecordGrid(model: model, records: records, view: view,
                       mixes: { _ in false },
                       menu: { AnyView(menu($0)) },
                       selection: selection,
                       onOpen: onOpen,
                       dimmed: dimmed,
                       nameWidth: nameWidth)
        }
        .background(Theme.panel)
    }

    private var toolbar: some View {
        let v = view.wrappedValue
        return HStack(spacing: Theme.space2) {
            Text(library.selectionName).font(Theme.label).foregroundStyle(Theme.ink).lineLimit(1)
            Text("\(records.count)").font(Theme.readoutSm).foregroundStyle(Theme.inkFaint)
            Spacer(minLength: Theme.space2)
            Menu {
                ForEach(model.savedViews) { saved in
                    Button(saved.name) {
                        var s = saved.settings
                        s.collapsed = []
                        view.wrappedValue = s
                    }
                }
                if !model.savedViews.isEmpty { Divider() }
                Button("Default columns") { model.mixTabViews[key] = nil }
            } label: {
                Image(systemName: "tablecells").font(.system(size: 11))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Apply a saved view from Organize")
            chip("eye.slash", active: false, "Fields") { showHide = true }
                .popover(isPresented: $showHide) { HideFieldsView(view: view, context: model.records) }
            chip("line.3.horizontal.decrease", active: !v.conditions.isEmpty, v.conditions.isEmpty ? "Filter" : "Filtered") { showFilter = true }
                .popover(isPresented: $showFilter) { FilterView(view: view, context: model.records) }
            chip("rectangle.grid.1x2", active: v.groupBy != nil, v.groupBy.map { model.records.name($0) } ?? "Group") { showGroup = true }
                .popover(isPresented: $showGroup) { GroupView(view: view, context: model.records) }
            if let trailing { trailing }
            TextField("Search", text: $library.search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 160)
        }
        .padding(.horizontal, Theme.space3)
        .frame(height: 36)
        .background(Theme.panelRaised)
    }

    private func chip(_ icon: String, active: Bool, _ title: String, action: @escaping () -> Void) -> some View {
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
        if let url = ordered.first {
            ForEach(model.decks) { deck in
                Button("Load into deck \(deck.label)") { Task { await model.load(url: url, into: deck) } }
            }
            Button("Open in Prep") { model.selectForPrep(url); model.page = .prep }
            Divider()
        }
        Menu("Add to set") {
            ForEach(library.playlists.playlists, id: \.node.id) { item in
                Button(item.path) { model.addToPlaylist(ordered, playlist: item.node.id) }
            }
        }
        if let set = library.selectedPlaylist {
            Button("Remove from \(set.name)") { library.playlists.remove(urls, from: set.id) }
        }
    }
}

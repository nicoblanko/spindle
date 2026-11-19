//
//  OrganizePanel.swift
//  Spindle
//
//  Right side of Organize. With a set open it is the set builder: running
//  time, an energy and tempo curve, the tracks in order (drag to reorder,
//  drop to add) and how each transition works. With several tracks
//  selected, or no set open, it is the inspector: tags, sets, rating, notes
//  and prep for the selection.
//

import SwiftUI

struct OrganizePanel: View {
    let model: AppModel
    @Bindable var library: LibraryModel
    /// The person's choice of tab; cleared when the selection changes.
    @State private var forced: Tab?

    enum Tab: String, CaseIterable, Identifiable { case set = "Set", inspector = "Inspector"; var id: String { rawValue } }

    private var openSet: PlaylistNode? { model.openSetNode }

    private var tab: Tab {
        if openSet == nil { return .inspector }
        if let forced { return forced }
        return model.organizeSelection.count > 1 ? .inspector : .set
    }

    var body: some View {
        VStack(spacing: 0) {
            if openSet != nil {
                Picker("", selection: Binding(get: { tab }, set: { forced = $0 })) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(Theme.space2)
                .background(Theme.panelRaised)
                Rectangle().fill(Theme.line).frame(height: 1)
            }
            if tab == .set, let set = openSet {
                SetBuilder(model: model, library: library, setNode: set)
            } else {
                Inspector(model: model, library: library)
            }
        }
        .background(Theme.panel)
        .onChange(of: model.organizeSelection) { forced = nil }
        .onChange(of: model.openSet) { forced = nil }
    }
}

// MARK: Set builder

private struct SetBuilder: View {
    let model: AppModel
    let library: LibraryModel
    let setNode: PlaylistNode
    @State private var dropTargeted = false

    private var tracks: [LibraryTrack] { setNode.tracks.map(library.track(path:)) }

    var body: some View {
        let items = tracks
        let analyses = items.map { model.analysis.analysis(for: $0.url) }
        let total = analyses.compactMap { $0?.duration }.reduce(0, +)
        let bpms = items.map { model.bpm(of: $0.url) }
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.space2) {
                    Text(setNode.name).font(Theme.title).foregroundStyle(Theme.ink).lineLimit(1)
                    Text("\(items.count) tracks · \(Self.hms(total))").font(Theme.readoutSm).foregroundStyle(Theme.inkMuted)
                    Spacer()
                    Button("Show as list") { library.playlist = setNode.id }
                        .buttonStyle(.plain).font(Theme.caption).foregroundStyle(Theme.inkMuted)
                        .help("Show this set in the main list")
                    Button { model.openSet = nil } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                        .buttonStyle(.plain).foregroundStyle(Theme.inkMuted)
                        .help("Close the set")
                }
                if items.count > 1 {
                    SetCurve(energies: analyses.map { $0.map { Double($0.energy) } }, bpms: bpms)
                        .frame(height: 56)
                    HStack(spacing: Theme.space3) {
                        let e = analyses.compactMap { $0?.energy }
                        let b = bpms.compactMap { $0 }
                        Text("— energy \(e.first ?? 0) → \(e.last ?? 0)").foregroundStyle(Theme.inkMuted)
                        Text("- - tempo \(Int(b.first ?? 0)) → \(Int(b.last ?? 0))").foregroundStyle(Theme.inkFaint)
                    }
                    .font(Theme.caption)
                }
            }
            .padding(Theme.space3)
            Rectangle().fill(Theme.line).frame(height: 1)
            List {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, track in
                    VStack(alignment: .leading, spacing: 0) {
                        if index > 0 { transition(from: items[index - 1], to: track) }
                        row(index, track)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(model.organizeSelection.contains(track.url) ? Theme.accentSoft : Theme.panel)
                }
                .onMove { library.playlists.reorder(setNode.id, from: $0, to: $1) }
                .dropDestination(for: URL.self) { urls, index in
                    library.playlists.insert(PlaylistStore.audioFiles(in: urls), into: setNode.id, at: index)
                    Task { await model.analysis.analyze(urls); await model.prepareAll() }
                }
                if items.isEmpty {
                    Text("Drag tracks here from the list, or right-click tracks › Add to set.")
                        .font(Theme.caption).foregroundStyle(Theme.inkFaint)
                        .frame(maxWidth: .infinity, minHeight: 80)
                        .listRowBackground(Theme.panel)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 1)
            .overlay { if dropTargeted { Rectangle().strokeBorder(Theme.accent, lineWidth: 2) } }
            .dropDestination(for: URL.self) { urls, _ in
                model.addToPlaylist(urls, playlist: setNode.id)
                return true
            } isTargeted: { dropTargeted = $0 }
            Text("Drag tracks in from the list, drag ≡ to reorder.")
                .font(Theme.caption).foregroundStyle(Theme.inkFaint)
                .padding(Theme.space2)
        }
    }

    private func row(_ index: Int, _ track: LibraryTrack) -> some View {
        let a = model.analysis.analysis(for: track.url)
        return HStack(spacing: Theme.space2) {
            Image(systemName: "line.3.horizontal").font(.system(size: 10)).foregroundStyle(Theme.inkFaint)
            Text("\(index + 1)").font(Theme.readoutSm).foregroundStyle(Theme.inkFaint).frame(width: 20, alignment: .trailing)
            Text(track.name).font(Theme.body).foregroundStyle(Theme.ink).lineLimit(1)
            Spacer(minLength: 0)
            Text(model.bpm(of: track.url).map { String(format: "%.0f", $0) } ?? "—").font(Theme.readoutSm).foregroundStyle(Theme.inkMuted)
            Text(a.map { "\($0.camelotNumber) \(KeyStyle.mood(minor: $0.keyMinor))" } ?? "").font(Theme.readoutSm)
                .foregroundStyle(Theme.inkMuted).frame(width: 62, alignment: .leading)
        }
        .padding(.horizontal, Theme.space3)
        .frame(height: 32)
        .contentShape(Rectangle())
        .onTapGesture { model.organizeSelection = [track.url] }
        .contextMenu {
            ForEach(model.decks) { deck in
                Button("Load into deck \(deck.label)") { Task { await model.load(url: track.url, into: deck) } }
            }
            Divider()
            Button("Remove from \(setNode.name)") { library.playlists.remove([track.url], from: setNode.id) }
        }
    }

    /// "Lift · +1.6%", in red when the keys clash or the tempo jumps.
    private func transition(from a: LibraryTrack, to b: LibraryTrack) -> some View {
        let aa = model.analysis.analysis(for: a.url), ba = model.analysis.analysis(for: b.url)
        let ab = model.bpm(of: a.url), bb = model.bpm(of: b.url)
        var text = ""
        var warn = false
        if let aa, let ba {
            if let relation = MixRelation.between(aa, ba) { text = relation.title } else {
                text = "Key clash"
                warn = true
            }
        }
        if let ab, let bb, ab > 0 {
            // Half/double time counts as close.
            let ratio = [bb, bb * 2, bb / 2].map { $0 / ab - 1 }.min { abs($0) < abs($1) } ?? 0
            text += String(format: " · %+.1f%%", ratio * 100)
            if abs(ratio) > 0.08 { warn = true }
        }
        return HStack(spacing: Theme.space2) {
            Rectangle().fill(Theme.line).frame(width: 1, height: 16).padding(.leading, 52)
            Text(text).font(Theme.caption).foregroundStyle(warn ? Theme.warn : Theme.inkFaint)
            Spacer()
        }
        .frame(height: 18)
    }

    static func hms(_ seconds: Double) -> String {
        let s = Int(seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Energy (solid) and tempo (dashed) across a set.
private struct SetCurve: View {
    let energies: [Double?]
    let bpms: [Double?]

    var body: some View {
        Canvas { context, size in
            func path(_ values: [Double?], lo: Double, hi: Double) -> Path {
                var p = Path()
                let n = max(values.count - 1, 1)
                var started = false
                for (i, v) in values.enumerated() {
                    guard let v else { continue }
                    let x = CGFloat(i) / CGFloat(n) * (size.width - 4) + 2
                    let y = size.height - 3 - CGFloat((v - lo) / max(hi - lo, 0.001)) * (size.height - 6)
                    if started { p.addLine(to: CGPoint(x: x, y: y)) } else { p.move(to: CGPoint(x: x, y: y)); started = true }
                }
                return p
            }
            context.fill(Path(CGRect(x: 0, y: size.height - 1, width: size.width, height: 1)), with: .color(Theme.line))
            let b = bpms.compactMap { $0 }
            if let lo = b.min(), let hi = b.max() {
                context.stroke(path(bpms, lo: lo - 2, hi: hi + 2), with: .color(Theme.inkFaint), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
            }
            context.stroke(path(energies, lo: 1, hi: 10), with: .color(Theme.ink), lineWidth: 1.5)
        }
    }
}

// MARK: Inspector

private struct Inspector: View {
    let model: AppModel
    let library: LibraryModel
    @State private var addingTag = false
    @State private var notes = ""

    private var urls: [URL] {
        let s = model.organizeSelection
        return library.visibleTracks.map(\.url).filter { s.contains($0) } + s.filter { u in !library.visibleTracks.contains { $0.url == u } }
    }

    var body: some View {
        let urls = urls
        ScrollView {
            if urls.isEmpty {
                Text("Select tracks to edit their tags, sets, rating and notes. Open a set in the sidebar to build it here.")
                    .font(Theme.caption).foregroundStyle(Theme.inkFaint)
                    .padding(Theme.space3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    header(urls)
                    section("Tags") { tags(urls) }
                    section("In sets") { sets(urls) }
                    section("Rating") { rating(urls) }
                    section("Notes") { notesEditor(urls) }
                    section("Prep") { prep(urls) }
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.space2) {
            LabelText(title)
            content()
        }
        .padding(Theme.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private func header(_ urls: [URL]) -> some View {
        let analyses = urls.compactMap { model.analysis.analysis(for: $0) }
        let bpms = urls.compactMap { model.bpm(of: $0) }
        return VStack(alignment: .leading, spacing: 2) {
            if urls.count == 1, let url = urls.first {
                Text(url.deletingPathExtension().lastPathComponent).font(Theme.title).foregroundStyle(Theme.ink).lineLimit(2)
                if let a = analyses.first {
                    Text("\(String(format: "%.1f", bpms.first ?? a.bpm)) · \(a.camelotNumber) \(KeyStyle.mood(minor: a.keyMinor)) · E\(a.energy) · \(OrganizeView.length(a.duration))")
                        .font(Theme.readoutSm).foregroundStyle(Theme.inkMuted)
                }
            } else {
                Text("\(urls.count) tracks").font(Theme.title).foregroundStyle(Theme.ink)
                if let lo = bpms.min(), let hi = bpms.max() {
                    let e = analyses.map(\.energy)
                    Text("\(Int(lo))–\(Int(hi)) BPM · E\(e.min() ?? 0)–\(e.max() ?? 0)")
                        .font(Theme.readoutSm).foregroundStyle(Theme.inkMuted)
                }
            }
        }
        .padding(Theme.space3)
    }

    private func tags(_ urls: [URL]) -> some View {
        let store = library.tags
        let paths = urls.map(\.path)
        let counts = store.manualTags.map { tag in (tag, paths.filter { store.ids(for: $0).contains(tag.id) }.count) }
        return FlowLayout(spacing: 6) {
            ForEach(counts.filter { $0.1 > 0 }, id: \.0.id) { tag, count in
                if count == paths.count {
                    Pill(name: tag.name, color: tag.color) { store.set(tag.id, on: paths, false) }
                } else {
                    Button { store.set(tag.id, on: paths, true) } label: {
                        Pill(name: "\(tag.name) · \(count) of \(paths.count)", color: tag.color).opacity(0.7)
                    }
                    .buttonStyle(.plain)
                    .help("On \(count) of \(paths.count): click to add to all")
                }
            }
            Button { addingTag = true } label: {
                Text("+ add tag").font(Theme.caption).foregroundStyle(Theme.inkMuted)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $addingTag) {
                OptionPicker(
                    options: model.records.options(.tags),
                    selected: counts.filter { $0.1 == paths.count }.map { $0.0.id.uuidString },
                    multi: true,
                    onToggle: { id in
                        guard let uuid = UUID(uuidString: id) else { return }
                        let all = paths.allSatisfy { store.ids(for: $0).contains(uuid) }
                        store.set(uuid, on: paths, !all)
                    },
                    onCreate: { name in (store.tag(named: name)?.id ?? store.create(name: name)).uuidString })
            }
        }
    }

    private func sets(_ urls: [URL]) -> some View {
        let store = library.playlists
        let paths = Set(urls.map(\.path))
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(store.playlists, id: \.node.id) { item in
                let count = item.node.tracks.filter { paths.contains($0) }.count
                Button {
                    if count == paths.count { store.remove(Set(urls), from: item.node.id) }
                    else { model.addToPlaylist(urls, playlist: item.node.id) }
                } label: {
                    HStack(spacing: Theme.space2) {
                        Image(systemName: count == paths.count ? "checkmark.square.fill" : (count > 0 ? "minus.square.fill" : "square"))
                            .foregroundStyle(count > 0 ? Theme.ink : Theme.inkFaint)
                        Text(item.path).font(Theme.body).foregroundStyle(Theme.ink).lineLimit(1)
                        Spacer()
                        if count > 0 && count < paths.count {
                            Text("\(count) of \(paths.count)").font(Theme.readoutSm).foregroundStyle(Theme.inkFaint)
                        }
                    }
                    .frame(height: 24)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if store.playlists.isEmpty {
                Text("No sets yet: make one with + next to Sets.").font(Theme.caption).foregroundStyle(Theme.inkFaint)
            }
        }
    }

    private func rating(_ urls: [URL]) -> some View {
        let values = Set(urls.map { model.meta.get($0.path).rating })
        let value = values.count == 1 ? values.first! : 0
        return HStack(spacing: Theme.space2) {
            RatingView(value: value) { n in model.meta.update(urls.map(\.path)) { $0.rating = n } }
                .scaleEffect(1.4, anchor: .leading)
                .frame(width: 100, alignment: .leading)
            if values.count > 1 { Text("mixed").font(Theme.caption).foregroundStyle(Theme.inkFaint) }
        }
    }

    @ViewBuilder
    private func notesEditor(_ urls: [URL]) -> some View {
        if urls.count == 1, let url = urls.first {
            TextEditor(text: Binding(get: { model.meta.get(url.path).notes },
                                     set: { v in model.meta.update([url.path]) { $0.notes = v } }))
                .font(Theme.body)
                .scrollContentBackground(.hidden)
                .padding(4)
                .frame(height: 64)
                .background(Theme.bg)
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusMd).stroke(Theme.line, lineWidth: 1))
        } else {
            Text("Notes are per track: select one.").font(Theme.caption).foregroundStyle(Theme.inkFaint)
        }
    }

    private func prep(_ urls: [URL]) -> some View {
        let ready = urls.filter { model.prep.prep(for: $0)?.mixReady == true }.count
        return HStack {
            Text("\(ready) of \(urls.count) mix-ready").font(Theme.body).foregroundStyle(Theme.inkMuted)
            Spacer()
            Button("Open in Prep →") {
                if let first = urls.first { model.selectForPrep(first) }
                model.page = .prep
            }
            .buttonStyle(.plain)
            .font(Theme.body)
            .foregroundStyle(Theme.ink)
        }
    }
}

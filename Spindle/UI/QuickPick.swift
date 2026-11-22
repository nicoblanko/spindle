//
//  QuickPick.swift
//  Spindle
//
//  Small keyboard-first cards for the selected tracks, on every page:
//    ⇧C  colour: ← → pick, 0–9 jump, Return applies, Esc closes
//    ⇧S  set: type to find or name a new set, ↑ ↓ pick, Return adds
//        (or takes the tracks out again when they're all in it)
//  Both keys can be changed in Keyboard shortcuts.
//

import AppKit
import Observation
import SwiftUI

@Observable
final class QuickPick {
    static let shared = QuickPick()
    enum Kind { case color, set }
    var kind: Kind?
    var urls: [URL] = []
    var isOpen: Bool { kind != nil }

    func open(_ kind: Kind, _ urls: [URL]) {
        guard !urls.isEmpty else { return }
        self.urls = urls
        self.kind = kind
    }

    func close() { kind = nil }
}

extension AppModel {
    /// The tracks the quick cards act on: the page's selection.
    var selectedTracks: [URL] {
        switch page {
        case .organize: organizeSelection.sorted { $0.path < $1.path }
        case .mix: mixSelection.sorted { $0.path < $1.path }
        case .prep: prepPage.selected.map { [$0] } ?? []
        case .sessions: []
        }
    }
}

/// Dims the page and shows the open card in the middle.
struct QuickPickOverlay: View {
    let model: AppModel
    @State private var pick = QuickPick.shared

    var body: some View {
        if let kind = pick.kind {
            ZStack {
                Color.black.opacity(0.35)
                    .contentShape(Rectangle())
                    .onTapGesture { pick.close() }
                Group {
                    switch kind {
                    case .color: ColorPickCard(model: model, urls: pick.urls) { pick.close() }
                    case .set: SetPickCard(model: model, urls: pick.urls) { pick.close() }
                    }
                }
                .frame(width: kind == .color ? 480 : 380)
                .background(Theme.panelRaised)
                .overlay(Rectangle().strokeBorder(Theme.line, lineWidth: 1))
            }
        }
    }
}

/// Listens to the keys while a card is open (before anything else gets them).
private final class CardKeys {
    private var monitor: Any?
    func install(_ handle: @escaping (NSEvent) -> Bool) {
        remove()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { handle($0) ? nil : $0 }
    }
    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
    deinit { remove() }
}

private func cardHeader(_ title: String, _ count: Int) -> some View {
    HStack {
        LabelText(title)
        Spacer()
        Text(count == 1 ? "1 track" : "\(count) tracks").font(Theme.readoutSm).foregroundStyle(Theme.inkFaint)
    }
    .padding(.horizontal, Theme.space3)
    .padding(.top, Theme.space3)
}

private func cardHint(_ text: String) -> some View {
    Text(text)
        .font(Theme.caption).foregroundStyle(Theme.inkFaint)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.space3).padding(.vertical, Theme.space2)
        .background(Theme.panel)
}

// MARK: Colour

private struct ColorPickCard: View {
    let model: AppModel
    let urls: [URL]
    let done: () -> Void
    /// nil first (no colour), then the soft colours.
    private let options: [DeckColor?] = [nil] + DeckColor.Group.soft.colors
    @State private var index = 0
    @State private var keys = CardKeys()

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.space3) {
            cardHeader("Colour", urls.count)
            HStack(spacing: 10) {
                ForEach(options.indices, id: \.self) { i in swatch(i) }
            }
            .padding(.horizontal, Theme.space3)
            HStack(spacing: Theme.space2) {
                Text(options[index]?.rawValue ?? "No colour").font(Theme.body).foregroundStyle(Theme.ink)
                Spacer()
                Text("\(index)").font(Theme.readoutSm).foregroundStyle(Theme.inkFaint)
            }
            .padding(.horizontal, Theme.space3)
            cardHint("← → pick · 0–9 jump · Return apply · Esc close")
        }
        .onAppear {
            // Start on the colour the tracks already share.
            let current = Set(urls.map { model.meta.color($0.path) })
            if current.count == 1, let c = current.first, let i = options.firstIndex(of: c) { index = i }
            keys.install(handle)
        }
        .onDisappear { keys.remove() }
    }

    private func swatch(_ i: Int) -> some View {
        let on = i == index
        return ZStack {
            if let c = options[i] {
                Circle().fill(c.color)
            } else {
                Circle().strokeBorder(Theme.inkFaint, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.inkMuted)
            }
        }
        .frame(width: 26, height: 26)
        .padding(3)
        .overlay(Circle().strokeBorder(on ? Theme.ink : Color.clear, lineWidth: 2))
        .scaleEffect(on ? 1.1 : 1)
        .contentShape(Circle())
        .onTapGesture { index = i; apply() }
        .help(options[i]?.rawValue ?? "No colour")
    }

    private func apply() {
        let picked = options[index]
        model.meta.update(urls.map(\.path)) { $0.color = picked?.rawValue }
        done()
    }

    private func handle(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 123: index = (index - 1 + options.count) % options.count
        case 124: index = (index + 1) % options.count
        case 36, 76: apply()
        case 53: done()
        default:
            if let n = Int(event.charactersIgnoringModifiers ?? ""), n < options.count { index = n; return true }
            return true                                    // swallow everything else while open
        }
        return true
    }
}

// MARK: Set

private struct SetPickCard: View {
    let model: AppModel
    let urls: [URL]
    let done: () -> Void
    @State private var query = ""
    @State private var index = 0
    @State private var keys = CardKeys()
    @FocusState private var focused: Bool

    private struct Row: Identifiable {
        let id: String
        let title: String
        let set: UUID?            // nil = make a new set named `title`
        let allIn: Bool
    }

    private var rows: [Row] {
        let store = model.library.playlists
        let paths = Set(urls.map(\.path))
        let q = query.trimmingCharacters(in: .whitespaces)
        var rows = store.playlists
            .filter { q.isEmpty || $0.path.localizedCaseInsensitiveContains(q) }
            .map { item in
                Row(id: item.node.id.uuidString, title: item.path, set: item.node.id,
                    allIn: paths.isSubset(of: Set(item.node.tracks)))
            }
        if !q.isEmpty, !store.playlists.contains(where: { $0.node.name.caseInsensitiveCompare(q) == .orderedSame }) {
            rows.append(Row(id: "new", title: q, set: nil, allIn: false))
        }
        return rows
    }

    var body: some View {
        let rows = rows
        VStack(alignment: .leading, spacing: Theme.space2) {
            cardHeader("Put in set", urls.count)
            TextField("Find a set, or type a new name", text: $query)
                .textFieldStyle(.plain)
                .font(Theme.body)
                .padding(Theme.space2)
                .background(Theme.panel)
                .overlay(Rectangle().strokeBorder(Theme.line, lineWidth: 1))
                .padding(.horizontal, Theme.space3)
                .focused($focused)
                .onChange(of: query) { index = 0 }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                            rowView(row, on: i == min(index, rows.count - 1))
                                .id(row.id)
                                .onTapGesture { choose(row) }
                        }
                        if rows.isEmpty {
                            Text("No sets yet. Type a name to make one.")
                                .font(Theme.caption).foregroundStyle(Theme.inkFaint)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(Theme.space2)
                        }
                    }
                }
                .frame(maxHeight: 260)
                .fixedSize(horizontal: false, vertical: true)
                .onChange(of: index) { _, i in if rows.indices.contains(i) { proxy.scrollTo(rows[i].id) } }
            }
            .padding(.horizontal, Theme.space3)
            cardHint("↑ ↓ pick · Return add (or take out) · Esc close")
        }
        .onAppear {
            keys.install(handle)
            DispatchQueue.main.async { focused = true }
        }
        .onDisappear { keys.remove() }
    }

    private func rowView(_ row: Row, on: Bool) -> some View {
        HStack(spacing: Theme.space2) {
            Image(systemName: row.set == nil ? "plus" : (row.allIn ? "checkmark" : "music.note.list"))
                .font(.system(size: 11)).frame(width: 14)
                .foregroundStyle(row.allIn ? Theme.match : Theme.inkMuted)
            Text(row.set == nil ? "New set “\(row.title)”" : row.title)
                .font(Theme.body).foregroundStyle(Theme.ink).lineLimit(1)
            Spacer()
            if row.allIn { Text("in set").font(Theme.caption).foregroundStyle(Theme.inkFaint) }
        }
        .padding(.horizontal, Theme.space2).padding(.vertical, 6)
        .background(on ? Theme.accentSoft : Color.clear)
        .contentShape(Rectangle())
    }

    private func choose(_ row: Row) {
        let store = model.library.playlists
        if let id = row.set {
            if row.allIn { store.remove(Set(urls), from: id) } else { model.addToPlaylist(urls, playlist: id) }
        } else {
            let id = store.create(name: row.title, folder: false, in: nil)
            model.addToPlaylist(urls, playlist: id)
        }
        done()
    }

    private func handle(_ event: NSEvent) -> Bool {
        let count = rows.count
        switch event.keyCode {
        case 125: if count > 0 { index = min(index + 1, count - 1) }
        case 126: index = max(index - 1, 0)
        case 36, 76:
            let r = rows
            if r.indices.contains(min(index, r.count - 1)), !r.isEmpty { choose(r[min(index, r.count - 1)]) }
        case 53: done()
        default: return false                              // typing goes to the field
        }
        return true
    }
}

//
//  LibraryPanel.swift
//  Spindle
//
//  Crates on the left, tracks on the right. Each row loads into deck A or B
//  with one click; double-click loads into A.
//

import SwiftUI

struct LibraryPanel: View {
    @Bindable var library: LibraryModel
    let model: AppModel

    var body: some View {
        HStack(spacing: 1) {
            crateList
                .frame(width: 180)
            VStack(spacing: 0) {
                toolbar
                Rectangle().fill(Theme.line).frame(height: 1)
                trackList
            }
        }
        .background(Theme.line)
        .task { if library.tracks.isEmpty { await library.rescan() } }
    }

    private var crateList: some View {
        VStack(alignment: .leading, spacing: 0) {
            LabelText("Crates")
                .padding(.horizontal, Theme.space3)
                .padding(.vertical, Theme.space2)
            crateRow(nil, title: "All tracks", count: library.tracks.count)
            ForEach(library.crates, id: \.self) { crate in
                crateRow(crate, title: crate, count: library.tracks.filter { $0.crate == crate }.count)
            }
            Spacer(minLength: 0)
            Button("Choose folder…") { Task { await library.chooseFolder() } }
                .buttonStyle(FlatButtonStyle())
                .padding(Theme.space2)
        }
        .frame(maxHeight: .infinity)
        .background(Theme.panel)
    }

    private func crateRow(_ crate: String?, title: String, count: Int) -> some View {
        let selected = library.crate == crate
        return Button {
            library.crate = crate
        } label: {
            HStack {
                Text(title).font(Theme.body).lineLimit(1)
                Spacer()
                Text("\(count)").font(Theme.readoutSm)
            }
            .foregroundStyle(selected ? Theme.ink : Theme.inkMuted)
            .padding(.horizontal, Theme.space3)
            .padding(.vertical, 5)
            .background(selected ? Theme.accentSoft : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var toolbar: some View {
        HStack(spacing: Theme.space3) {
            LabelText(library.crate ?? "All tracks")
            if library.scanning {
                Text("Scanning…").font(Theme.caption).foregroundStyle(Theme.inkFaint)
            }
            Spacer()
            TextField("Search", text: $library.search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 240)
        }
        .padding(.horizontal, Theme.space3)
        .padding(.vertical, Theme.space2)
        .background(Theme.panelRaised)
    }

    private var trackList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(library.visibleTracks) { track in
                    TrackRow(track: track, model: model)
                    Rectangle().fill(Theme.line).frame(height: 1)
                }
            }
        }
        .background(Theme.panel)
        .overlay {
            if !library.scanning && library.tracks.isEmpty {
                Text("No audio files found in \(library.folder.lastPathComponent). Use Choose folder….")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.inkFaint)
            }
        }
    }
}

private struct TrackRow: View {
    let track: LibraryTrack
    let model: AppModel
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Theme.space2) {
            loadButton(deck: model.decks[0])
            loadButton(deck: model.decks[1])
            Text(track.name)
                .font(Theme.body)
                .foregroundStyle(isLoaded ? Theme.ink : Theme.inkMuted)
                .lineLimit(1)
            Spacer()
            Text(track.crate).font(Theme.caption).foregroundStyle(Theme.inkFaint)
            Text(track.format).font(Theme.readoutSm).foregroundStyle(Theme.inkFaint)
                .frame(width: 40, alignment: .trailing)
        }
        .padding(.horizontal, Theme.space3)
        .padding(.vertical, 4)
        .background(hovering ? Theme.panelRaised : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { load(into: model.decks[0]) }
    }

    private var isLoaded: Bool {
        model.decks.contains { $0.track?.url == track.url }
    }

    private func loadButton(deck: DeckModel) -> some View {
        let loadedHere = deck.track?.url == track.url
        return Button {
            load(into: deck)
        } label: {
            Text(deck.label)
                .font(Theme.label)
                .frame(width: 22, height: 18)
                .foregroundStyle(loadedHere ? Theme.onAccent : deck.color)
                .background(loadedHere ? deck.color : Theme.control)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSm))
        }
        .buttonStyle(.plain)
        .help("Load into deck \(deck.label)")
    }

    private func load(into deck: DeckModel) {
        Task { await model.load(url: track.url, into: deck) }
    }
}

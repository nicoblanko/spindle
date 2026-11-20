//
//  Library.swift
//  Spindle
//
//  The library: every audio file under the music folder, grouped by its
//  first subfolder ("crate"), plus the playlists made in Spindle, which can
//  hold files from anywhere.
//

import AppKit
import Foundation
import Observation

nonisolated struct LibraryTrack: Identifiable, Hashable, Sendable {
    let url: URL
    let crate: String
    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
    var format: String { url.pathExtension.uppercased() }
}

@Observable
final class LibraryModel {
    static let defaultFolder = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/CloudStorage/Dropbox-Home/Rein Blank/1_WORK/3_MUSIC/_DJ_music/slsk_downloads/DJ")
    private static let folderKey = "library.folder"
    static let audioExtensions: Set<String> = ["flac", "mp3", "wav", "aiff", "aif", "m4a", "aac", "opus", "ogg", "alac"]

    private(set) var folder: URL
    private(set) var tracks: [LibraryTrack] = []
    private(set) var scanning = false
    /// Selected folder crate (nil with no playlist selected = all tracks).
    var crate: String? {
        didSet { if crate != nil { playlist = nil; tag = nil; smart = nil } }
    }
    /// Selected playlist (set) or playlist folder.
    var playlist: UUID? {
        didSet { if playlist != nil { crate = nil; tag = nil; smart = nil } }
    }
    /// Selected tag or tempo group.
    var tag: UUID? {
        didSet { if tag != nil { crate = nil; playlist = nil; smart = nil } }
    }
    /// Selected smart list (Not prepped, Untagged, In no set).
    var smart: SmartList? {
        didSet { if smart != nil { crate = nil; playlist = nil; tag = nil } }
    }
    /// Whether a track is mix-ready on the Prep page (set by the app).
    var isPrepped: (URL) -> Bool = { _ in false }

    enum SmartList: String, CaseIterable, Identifiable {
        case notPrepped = "Not marked", untagged = "Untagged", inNoSet = "In no set"
        var id: String { rawValue }
    }

    /// Music-folder tracks in a smart list.
    func tracks(in smart: SmartList) -> [LibraryTrack] {
        switch smart {
        case .notPrepped: return tracks.filter { !isPrepped($0.url) }
        case .untagged: return tracks.filter { tags.ids(for: $0.url.path).isEmpty }
        case .inNoSet:
            let inSets = playlists.allTrackPaths
            return tracks.filter { !inSets.contains($0.url.path) }
        }
    }
    var search = ""
    let playlists = PlaylistStore()
    let tags = TagStore()
    /// Analysis for a track (set by the app), so tempo groups can match.
    var analysisLookup: (URL) -> TrackAnalysis? = { _ in nil }

    func selectAll() {
        crate = nil
        playlist = nil
        tag = nil
        smart = nil
    }

    /// Name of the current selection.
    var selectionName: String {
        if let node = playlists.node(playlist) { return playlists.path(of: node) }
        if let t = tags.tag(tag) { return "Tag: \(t.name)" }
        if let smart { return smart.rawValue }
        return crate ?? "All tracks"
    }

    /// Every track (music folder and playlists) with this tag.
    func tracks(withTag id: UUID) -> [LibraryTrack] {
        guard let t = tags.tag(id) else { return [] }
        return allTracks.filter { tags.has(t, path: $0.url.path, analysis: analysisLookup($0.url)) }
    }

    /// The playlist being shown, if a single playlist (not a folder) is selected.
    var selectedPlaylist: PlaylistNode? {
        playlists.node(playlist).flatMap { $0.isFolder ? nil : $0 }
    }

    /// A track by path: from the music folder, or (for playlist tracks from
    /// elsewhere) with its own folder's name as crate.
    func track(path: String) -> LibraryTrack {
        if let known = byPath[path] { return known }
        let url = URL(fileURLWithPath: path)
        return LibraryTrack(url: url, crate: url.deletingLastPathComponent().lastPathComponent)
    }

    private var byPath: [String: LibraryTrack] = [:]

    /// Tracks of a playlist, or of every playlist inside a folder, in order.
    func tracks(inPlaylist id: UUID) -> [LibraryTrack] {
        guard let node = playlists.node(id) else { return [] }
        if !node.isFolder { return node.tracks.map(track(path:)) }
        var seen = Set<String>()
        var result: [LibraryTrack] = []
        func walk(_ parent: UUID) {
            for child in playlists.children(of: parent) {
                if child.isFolder { walk(child.id) }
                else { for p in child.tracks where seen.insert(p).inserted { result.append(track(path: p)) } }
            }
        }
        walk(id)
        return result
    }

    /// The music folder's tracks plus playlist tracks from elsewhere.
    var allTracks: [LibraryTrack] {
        let outside = playlists.allTrackPaths.filter { byPath[$0] == nil }.sorted().map(track(path:))
        return tracks + outside
    }

    var crates: [String] { Array(Set(tracks.map(\.crate))).sorted() }

    var visibleTracks: [LibraryTrack] {
        let source = playlist.map(tracks(inPlaylist:))
            ?? tag.map(tracks(withTag:))
            ?? smart.map(tracks(in:))
            ?? tracks.filter { crate == nil || $0.crate == crate }
        return search.isEmpty ? source : source.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    init() {
        if let path = UserDefaults.standard.string(forKey: Self.folderKey) {
            folder = URL(fileURLWithPath: path)
        } else {
            folder = Self.defaultFolder
        }
    }

    func rescan() async {
        scanning = true
        defer { scanning = false }
        let root = folder
        tracks = await Task.detached { Self.scan(root) }.value
        byPath = Dictionary(tracks.map { ($0.url.path, $0) }, uniquingKeysWith: { a, _ in a })
        spindleLog.notice("Library: \(tracks.count) tracks in \(root.path)")
    }

    func chooseFolder() async {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = folder
        panel.prompt = "Use folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folder = url
        UserDefaults.standard.set(url.path, forKey: Self.folderKey)
        crate = nil
        await rescan()
    }

    nonisolated private static func scan(_ root: URL) -> [LibraryTrack] {
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        let rootComponents = root.standardizedFileURL.pathComponents.count
        var result: [LibraryTrack] = []
        for case let url as URL in walker where audioExtensions.contains(url.pathExtension.lowercased()) {
            let parts = url.standardizedFileURL.pathComponents
            let crate = parts.count > rootComponents + 1 ? parts[rootComponents] : "—"
            result.append(LibraryTrack(url: url, crate: crate))
        }
        return result.sorted { ($0.crate, $0.name.lowercased()) < ($1.crate, $1.name.lowercased()) }
    }
}

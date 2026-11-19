//
//  Playlists.swift
//  Spindle
//
//  Playlists and folders made in Spindle: tailor-made selections for
//  different sets. A playlist holds tracks from anywhere on disk (the music
//  folder or not), in the order they were added. Folders group playlists
//  and other folders. Kept in ~/Library/Application Support/Spindle/playlists.json.
//

import Foundation
import Observation
import SwiftUI

nonisolated struct PlaylistNode: Codable, Sendable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var isFolder: Bool
    var parent: UUID?
    /// File paths, in playlist order (playlists only).
    var tracks: [String] = []
}

/// A deleted playlist or folder (with what was inside it), kept for 30
/// days so it can be restored.
nonisolated struct DeletedPlaylist: Codable, Sendable, Identifiable, Equatable {
    var id = UUID()
    var deleted: Date
    /// The deleted node first, then everything that was inside it.
    var nodes: [PlaylistNode]
    var name: String { nodes.first?.name ?? "Playlist" }
    var trackCount: Int { nodes.reduce(0) { $0 + $1.tracks.count } }
}

@Observable
final class PlaylistStore {
    private(set) var nodes: [PlaylistNode] = []
    /// Recently deleted, newest first.
    private(set) var trash: [DeletedPlaylist] = []

    nonisolated private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Spindle", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("playlists.json")
    }

    nonisolated private static var trashURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("playlists-deleted.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let decoded = try? JSONDecoder().decode([PlaylistNode].self, from: data) {
            nodes = decoded
        }
        if let data = try? Data(contentsOf: Self.trashURL),
           let decoded = try? JSONDecoder().decode([DeletedPlaylist].self, from: data) {
            let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
            trash = decoded.filter { $0.deleted > cutoff }
        }
        spindleLog.notice("Playlists: loaded \(nodes.count) (\(nodes.filter { !$0.isFolder }.map(\.name).joined(separator: ", "))), \(trash.count) recently deleted")
    }

    func node(_ id: UUID?) -> PlaylistNode? { id.flatMap { id in nodes.first { $0.id == id } } }

    /// Children of a folder (nil = top level): folders first, then by name.
    func children(of parent: UUID?) -> [PlaylistNode] {
        nodes.filter { $0.parent == parent }
            .sorted { ($0.isFolder ? 0 : 1, $0.name.lowercased()) < ($1.isFolder ? 0 : 1, $1.name.lowercased()) }
    }

    /// Every playlist, with its folder path ("Club / Warm-up").
    var playlists: [(node: PlaylistNode, path: String)] {
        nodes.filter { !$0.isFolder }.map { ($0, path(of: $0)) }.sorted { $0.path.lowercased() < $1.path.lowercased() }
    }

    var folders: [(node: PlaylistNode, path: String)] {
        nodes.filter(\.isFolder).map { ($0, path(of: $0)) }.sorted { $0.path.lowercased() < $1.path.lowercased() }
    }

    func path(of node: PlaylistNode) -> String {
        var parts = [node.name]
        var parent = node.parent
        while let p = self.node(parent) {
            parts.insert(p.name, at: 0)
            parent = p.parent
        }
        return parts.joined(separator: " / ")
    }

    /// Number of tracks in a playlist, or in everything inside a folder.
    func count(_ node: PlaylistNode) -> Int {
        node.isFolder ? children(of: node.id).reduce(0) { $0 + count($1) } : node.tracks.count
    }

    // MARK: Editing

    @discardableResult
    func create(name: String, folder: Bool, in parent: UUID?) -> UUID {
        var base = name
        var n = 2
        while nodes.contains(where: { $0.parent == parent && $0.name == base }) { base = "\(name) \(n)"; n += 1 }
        let node = PlaylistNode(name: base, isFolder: folder, parent: parent)
        nodes.append(node)
        save()
        spindleLog.notice("Playlists: created \(folder ? "folder" : "playlist") '\(base)'")
        return node.id
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let i = nodes.firstIndex(where: { $0.id == id }) else { return }
        spindleLog.notice("Playlists: renamed '\(nodes[i].name)' to '\(trimmed)'")
        nodes[i].name = trimmed
        save()
    }

    /// Deletes a playlist, or a folder with everything in it. Only the
    /// playlist entries go; the audio files are never touched.
    func delete(_ id: UUID) {
        var doomed: Set<UUID> = [id]
        var grew = true
        while grew {
            let before = doomed.count
            for n in nodes where n.parent.map(doomed.contains) == true { doomed.insert(n.id) }
            grew = doomed.count != before
        }
        // Into Recently deleted, the deleted node first.
        let removed = nodes.filter { doomed.contains($0.id) }.sorted { a, _ in a.id == id }
        if !removed.isEmpty {
            trash.insert(DeletedPlaylist(deleted: Date(), nodes: removed), at: 0)
            saveTrash()
        }
        nodes.removeAll { doomed.contains($0.id) }
        save()
        spindleLog.notice("Playlists: deleted '\(removed.first?.name ?? "?")' (\(removed.count) item(s), \(removed.reduce(0) { $0 + $1.tracks.count }) tracks) — kept in Recently deleted")
    }

    /// Puts a deleted playlist (and anything that was in it) back.
    func restore(_ entry: DeletedPlaylist) {
        let existing = Set(nodes.map(\.id))
        let ids = Set(entry.nodes.map(\.id))
        for var node in entry.nodes where !existing.contains(node.id) {
            // Its old folder may be gone: then it goes to the top level.
            if let p = node.parent, !existing.contains(p) && !ids.contains(p) { node.parent = nil }
            nodes.append(node)
        }
        trash.removeAll { $0.id == entry.id }
        save()
        saveTrash()
        spindleLog.notice("Playlists: restored '\(entry.name)'")
    }

    /// Removes a deleted playlist for good.
    func purge(_ entry: DeletedPlaylist) {
        trash.removeAll { $0.id == entry.id }
        saveTrash()
        spindleLog.notice("Playlists: removed '\(entry.name)' from Recently deleted")
    }

    private func saveTrash() {
        let snapshot = trash
        Self.writer.async {
            if let data = try? JSONEncoder().encode(snapshot) { SafeWrite.write(data, to: Self.trashURL) }
        }
    }

    func move(_ id: UUID, to parent: UUID?) {
        guard let i = nodes.firstIndex(where: { $0.id == id }), id != parent else { return }
        // A folder can't go inside itself.
        var p = parent
        while let current = p {
            if current == id { return }
            p = node(current)?.parent
        }
        nodes[i].parent = parent
        save()
        spindleLog.notice("Playlists: moved '\(nodes[i].name)' to \(node(parent)?.name ?? "top level")")
    }

    /// Adds tracks (skipping ones already there). Returns how many were added.
    @discardableResult
    func add(_ urls: [URL], to id: UUID) -> Int {
        guard let i = nodes.firstIndex(where: { $0.id == id }), !nodes[i].isFolder else { return 0 }
        let existing = Set(nodes[i].tracks)
        let new = urls.map(\.path).filter { !existing.contains($0) }
        var seen = Set<String>()
        let unique = new.filter { seen.insert($0).inserted }
        nodes[i].tracks.append(contentsOf: unique)
        save()
        if !unique.isEmpty { spindleLog.notice("Playlists: added \(unique.count) track(s) to '\(nodes[i].name)'") }
        return unique.count
    }

    /// Adds tracks at a position (dropping into a set); ones already there move.
    func insert(_ urls: [URL], into id: UUID, at index: Int) {
        guard let i = nodes.firstIndex(where: { $0.id == id }), !nodes[i].isFolder else { return }
        let paths = urls.map(\.path)
        var list = nodes[i].tracks
        let before = list.prefix(index).filter { paths.contains($0) }.count
        list.removeAll { paths.contains($0) }
        let at = min(max(index - before, 0), list.count)
        var seen = Set<String>()
        list.insert(contentsOf: paths.filter { seen.insert($0).inserted }, at: at)
        nodes[i].tracks = list
        save()
        spindleLog.notice("Playlists: put \(paths.count) track(s) into '\(nodes[i].name)' at \(at + 1)")
    }

    func remove(_ urls: Set<URL>, from id: UUID) {
        guard let i = nodes.firstIndex(where: { $0.id == id }) else { return }
        let paths = Set(urls.map(\.path))
        let before = nodes[i].tracks.count
        nodes[i].tracks.removeAll { paths.contains($0) }
        save()
        spindleLog.notice("Playlists: removed \(before - nodes[i].tracks.count) track(s) from '\(nodes[i].name)'")
    }

    /// Moves tracks to a position in the playlist (drag to reorder).
    func reorder(_ id: UUID, from offsets: IndexSet, to destination: Int) {
        guard let i = nodes.firstIndex(where: { $0.id == id }) else { return }
        nodes[i].tracks.move(fromOffsets: offsets, toOffset: destination)
        save()
    }

    /// Every track in any playlist.
    var allTrackPaths: Set<String> { Set(nodes.flatMap(\.tracks)) }

    /// Writes in order on one queue, so a later save never loses to an
    /// earlier one that finished late.
    nonisolated private static let writer = DispatchQueue(label: "spindle.save.playlists", qos: .utility)

    private func save() {
        let snapshot = nodes
        Self.writer.async {
            if let data = try? JSONEncoder().encode(snapshot) {
                SafeWrite.write(data, to: Self.fileURL)
            }
        }
    }

    /// Audio files in the given files and folders (folders are searched).
    nonisolated static func audioFiles(in urls: [URL]) -> [URL] {
        var result: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                var found: [URL] = []
                while let item = walker?.nextObject() as? URL {
                    if LibraryModel.audioExtensions.contains(item.pathExtension.lowercased()) { found.append(item) }
                }
                result += found.sorted { $0.path < $1.path }
            } else if LibraryModel.audioExtensions.contains(url.pathExtension.lowercased()) {
                result.append(url)
            }
        }
        return result
    }
}

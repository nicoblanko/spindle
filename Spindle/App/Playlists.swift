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

@Observable
final class PlaylistStore {
    private(set) var nodes: [PlaylistNode] = []

    nonisolated private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Spindle", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("playlists.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let decoded = try? JSONDecoder().decode([PlaylistNode].self, from: data) {
            nodes = decoded
        }
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
        return node.id
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let i = nodes.firstIndex(where: { $0.id == id }) else { return }
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
        nodes.removeAll { doomed.contains($0.id) }
        save()
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
        return unique.count
    }

    func remove(_ urls: Set<URL>, from id: UUID) {
        guard let i = nodes.firstIndex(where: { $0.id == id }) else { return }
        let paths = Set(urls.map(\.path))
        nodes[i].tracks.removeAll { paths.contains($0) }
        save()
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
                try? data.write(to: Self.fileURL, options: .atomic)
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

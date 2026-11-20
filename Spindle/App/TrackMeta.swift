//
//  TrackMeta.swift
//  Spindle
//
//  Your own notes on tracks: a rating (1–5 stars) and free text, shown and
//  edited in the Organize inspector. Kept in
//  ~/Library/Application Support/Spindle/meta.json (backed up like playlists).
//

import Foundation
import Observation

nonisolated struct TrackMeta: Codable, Sendable, Equatable {
    var rating = 0
    var notes = ""
    /// The row's colour (a soft DeckColor name), picked in the Colour column.
    var color: String?
    var isEmpty: Bool { rating == 0 && notes.isEmpty && color == nil }
}

@Observable
final class TrackMetaStore {
    private(set) var meta: [String: TrackMeta] = [:]

    nonisolated private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Spindle", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("meta.json")
    }
    nonisolated private static let writer = DispatchQueue(label: "spindle.save.meta", qos: .utility)

    init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let decoded = try? JSONDecoder().decode([String: TrackMeta].self, from: data) {
            meta = decoded
        }
    }

    func get(_ path: String) -> TrackMeta { meta[path] ?? TrackMeta() }

    /// The track's row colour, if one is picked.
    func color(_ path: String) -> DeckColor? { meta[path]?.color.flatMap(DeckColor.init(rawValue:)) }

    func update(_ paths: [String], _ change: (inout TrackMeta) -> Void) {
        for p in paths {
            var m = get(p)
            change(&m)
            meta[p] = m.isEmpty ? nil : m
        }
        let snapshot = meta
        Self.writer.async {
            if let data = try? JSONEncoder().encode(snapshot) { SafeWrite.write(data, to: Self.fileURL) }
        }
    }
}

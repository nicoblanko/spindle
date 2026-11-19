//
//  SafeWrite.swift
//  Spindle
//
//  Writes Spindle's own data files (playlists, tags, fields) and keeps the
//  last versions of each in ~/Library/Application Support/Spindle/Backups,
//  so a mistake can always be undone by hand.
//

import Foundation

nonisolated enum SafeWrite {
    static let keep = 20

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss.SSS"
        return f
    }()

    static var backupFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Spindle/Backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Copies the current file to Backups (when it differs from the new
    /// data), writes the new data, and trims old backups. Call on a serial
    /// queue.
    /// `every`: back up at most this often (seconds), for files saved
    /// many times a minute while you edit.
    static func write(_ data: Data, to url: URL, every: TimeInterval = 0) {
        let name = url.deletingPathExtension().lastPathComponent
        let recent = every > 0 && (lastBackup[name].map { Date().timeIntervalSince($0) < every } ?? false)
        if !recent, let old = try? Data(contentsOf: url), old != data, !old.isEmpty {
            lastBackup[name] = Date()
            let stamp = stampFormatter.string(from: Date())
            let backup = backupFolder.appendingPathComponent("\(name) \(stamp).json")
            try? old.write(to: backup, options: .atomic)
            trim(prefix: name + " ")
        }
        try? data.write(to: url, options: .atomic)
    }

    nonisolated(unsafe) private static var lastBackup: [String: Date] = [:]

    private static func trim(prefix: String) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: backupFolder, includingPropertiesForKeys: nil) else { return }
        let mine = files.filter { $0.lastPathComponent.hasPrefix(prefix) }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in mine.dropFirst(keep) { try? fm.removeItem(at: old) }
    }
}


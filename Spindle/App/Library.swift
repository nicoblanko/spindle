//
//  Library.swift
//  Spindle
//
//  A minimal library for the prototype: every audio file under one music
//  folder, grouped by its first subfolder ("crate"). Step 2 (Organize) will
//  replace this with analysis and a proper database.
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
    var crate: String?          // nil = all crates
    var search = ""

    var crates: [String] { Array(Set(tracks.map(\.crate))).sorted() }

    var visibleTracks: [LibraryTrack] {
        tracks.filter { track in
            (crate == nil || track.crate == crate)
                && (search.isEmpty || track.name.localizedCaseInsensitiveContains(search))
        }
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

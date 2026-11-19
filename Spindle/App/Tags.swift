//
//  Tags.swift
//  Spindle
//
//  Tags group tracks across folders and playlists. Two kinds:
//    • your own tags ("vocal", "warm-up"), put on tracks by hand
//    • tempo groups: a rule (BPM range, optionally energy and mood) that
//      tracks match by themselves, so new tracks fall into place
//  "Make tempo groups" splits the library into BPM ranges no wider than
//  6%, so any two tracks in a group mix with a small tempo change.
//  Kept in ~/Library/Application Support/Spindle/tags.json.
//

import Foundation
import Observation
import SwiftUI

nonisolated struct TagRule: Codable, Sendable, Equatable {
    var minBPM: Double = 120
    var maxBPM: Double = 128
    var minEnergy: Int = 1
    var maxEnergy: Int = 10
    /// nil = any mood, true = Dark only, false = Bright only.
    var minor: Bool? = nil

    func matches(_ a: TrackAnalysis) -> Bool {
        a.bpm >= minBPM - 0.05 && a.bpm <= maxBPM + 0.05
            && a.energy >= minEnergy && a.energy <= maxEnergy
            && (minor == nil || minor == a.keyMinor)
    }

    /// How far apart the outer tempos are, e.g. 0.05 = 5%.
    var span: Double { maxBPM > 0 ? (maxBPM - minBPM) / minBPM : 0 }

    var summary: String {
        var parts = [String(format: "%.0f–%.0f BPM", minBPM, maxBPM)]
        if minEnergy > 1 || maxEnergy < 10 { parts.append("energy \(minEnergy)–\(maxEnergy)") }
        if let minor { parts.append(KeyStyle.mood(minor: minor)) }
        return parts.joined(separator: " · ")
    }
}

nonisolated struct TagDef: Codable, Sendable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var colorIndex: Int
    /// Set for tempo groups; nil for tags you put on by hand.
    var rule: TagRule?
    /// Made by "Make tempo groups" (replaced when that runs again).
    var automatic = false
    /// Position in the option list (Airtable-style: you set the order).
    var order: Int?

    var color: Color { TagStore.palette[colorIndex % TagStore.palette.count] }
    /// Dark text on the pastel pill, as in Airtable.
    static let textColor = Color(hex: 0x1d1f25)
}

@Observable
final class TagStore {
    private(set) var tags: [TagDef] = []
    /// Hand-placed tags per file path.
    private(set) var assigned: [String: Set<UUID>] = [:]

    /// Airtable's light option colours: blue, cyan, teal, green, yellow,
    /// orange, red, pink, purple, grey.
    static let palette: [Color] = [
        Color(hex: 0xcfdfff), Color(hex: 0xd0f0fd), Color(hex: 0xc2f5e9), Color(hex: 0xd1f7c4),
        Color(hex: 0xffeab6), Color(hex: 0xfee2d5), Color(hex: 0xffdce5), Color(hex: 0xffdaf6),
        Color(hex: 0xede2fe), Color(hex: 0xe5e9f0),
    ]
    static let paletteNames = ["Blue", "Cyan", "Teal", "Green", "Yellow", "Orange", "Red", "Pink", "Purple", "Grey"]

    private struct Saved: Codable { var tags: [TagDef]; var assigned: [String: Set<UUID>] }

    nonisolated private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Spindle", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("tags.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            tags = saved.tags
            assigned = saved.assigned
        }
    }

    func tag(_ id: UUID?) -> TagDef? { id.flatMap { id in tags.first { $0.id == id } } }

    /// Own tags first (by name), then tempo groups (by tempo).
    var sorted: [TagDef] {
        tags.sorted { a, b in
            switch (a.rule, b.rule) {
            case (nil, nil): a.name.lowercased() < b.name.lowercased()
            case (nil, _): true
            case (_, nil): false
            case let (ra?, rb?): (ra.minBPM, a.name) < (rb.minBPM, b.name)
            }
        }
    }

    /// Your tags, in the order you arranged them.
    var manualTags: [TagDef] {
        tags.enumerated().filter { $0.element.rule == nil }
            .sorted { ($0.element.order ?? $0.offset) < ($1.element.order ?? $1.offset) }
            .map(\.element)
    }

    var tempoGroups: [TagDef] {
        tags.filter { $0.rule != nil }.sorted { ($0.rule!.minBPM, $0.name) < ($1.rule!.minBPM, $1.name) }
    }

    /// Your tags on a track, in option order.
    func manualTags(for path: String) -> [TagDef] {
        guard let ids = assigned[path], !ids.isEmpty else { return [] }
        return manualTags.filter { ids.contains($0.id) }
    }

    func ids(for path: String) -> Set<UUID> { assigned[path] ?? [] }

    func tag(named name: String) -> TagDef? {
        manualTags.first { $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }

    /// Drag-to-reorder in Manage tags.
    func moveOptions(from offsets: IndexSet, to destination: Int) {
        var list = manualTags
        list.move(fromOffsets: offsets, toOffset: destination)
        for (i, t) in list.enumerated() {
            if let k = tags.firstIndex(where: { $0.id == t.id }) { tags[k].order = i }
        }
        save()
    }

    /// Whether a track has a tag (by hand, or by matching its rule).
    func has(_ tag: TagDef, path: String, analysis: TrackAnalysis?) -> Bool {
        if let rule = tag.rule { return analysis.map(rule.matches) ?? false }
        return assigned[path]?.contains(tag.id) ?? false
    }

    func tags(for path: String, analysis: TrackAnalysis?) -> [TagDef] {
        sorted.filter { has($0, path: path, analysis: analysis) }
    }

    // MARK: Editing

    @discardableResult
    func create(name: String, rule: TagRule? = nil) -> UUID {
        // New options take the next colour and go to the end, as in Airtable.
        let mine = tags.filter { ($0.rule == nil) == (rule == nil) }.count
        var tag = TagDef(name: name, colorIndex: mine % Self.palette.count, rule: rule)
        if rule == nil { tag.order = (manualTags.compactMap(\.order).max() ?? manualTags.count - 1) + 1 }
        tags.append(tag)
        save()
        return tag.id
    }

    func update(_ tag: TagDef) {
        guard let i = tags.firstIndex(where: { $0.id == tag.id }) else { return }
        tags[i] = tag
        save()
    }

    func delete(_ id: UUID) {
        tags.removeAll { $0.id == id }
        for key in assigned.keys {
            assigned[key]?.remove(id)
            if assigned[key]?.isEmpty == true { assigned[key] = nil }
        }
        save()
    }

    func set(_ id: UUID, on paths: [String], _ on: Bool) {
        for p in paths {
            var set = assigned[p] ?? []
            if on { set.insert(id) } else { set.remove(id) }
            assigned[p] = set.isEmpty ? nil : set
        }
        save()
    }

    /// Replaces the automatic tempo groups with fresh ones for these
    /// tempos: each group spans at most `span` (6%), so any two of its
    /// tracks mix with a small tempo change. Groups need `minimum` tracks.
    func makeTempoGroups(bpms: [Double], span: Double = 0.06, minimum: Int = 3) {
        tags.removeAll { $0.automatic }
        let sortedBPMs = bpms.filter { $0 > 0 }.sorted()
        var i = 0
        var made = 0
        while i < sortedBPMs.count {
            let low = sortedBPMs[i]
            var j = i
            while j + 1 < sortedBPMs.count && sortedBPMs[j + 1] <= low * (1 + span) { j += 1 }
            let count = j - i + 1
            if count >= minimum {
                let high = sortedBPMs[j]
                // Exact edges (to 0.1 BPM) so neighbouring groups don't share
                // tracks; the name shows whole BPMs.
                let rule = TagRule(minBPM: (low * 10).rounded(.down) / 10, maxBPM: (high * 10).rounded(.up) / 10)
                let lo = Int(rule.minBPM.rounded()), hi = Int(rule.maxBPM.rounded())
                var tag = TagDef(name: lo == hi ? "\(lo) BPM" : "\(lo)–\(hi) BPM",
                                 colorIndex: made, rule: rule)
                tag.automatic = true
                tags.append(tag)
                made += 1
            }
            i = j + 1
        }
        save()
    }

    /// Writes in order on one queue, so a later save never loses to an
    /// earlier one that finished late.
    nonisolated private static let writer = DispatchQueue(label: "spindle.save.tags", qos: .utility)

    private func save() {
        let snapshot = Saved(tags: tags, assigned: assigned)
        Self.writer.async {
            if let data = try? JSONEncoder().encode(snapshot) {
                SafeWrite.write(data, to: Self.fileURL)
            }
        }
    }
}

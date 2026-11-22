//
//  Tags.swift
//  Spindle
//
//  Tags group tracks across folders and playlists. Two kinds:
//    • your own tags ("vocal", "warm-up"), put on tracks by hand
//    • tempo groups: a rule (BPM range, optionally energy and mood) that
//      tracks match by themselves, so new tracks fall into place
//  "Make tempo groups" splits the library into BPM ranges no wider than
//  4%, so any two tracks in a group mix without audible stretching
//  (DJs keep tempo changes to about 3–5%). Those groups count half and
//  double time: 87 BPM hip-hop sits with 174 BPM drum & bass.
//  "Make genre groups" adds the usual ranges for hip-hop, house, techno
//  and drum & bass instead.
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
    /// Also match at half or double the tempo (87 BPM with 174).
    var octaves: Bool? = nil

    func matches(bpm: Double) -> Bool {
        func inside(_ b: Double) -> Bool { b >= minBPM - 0.05 && b <= maxBPM + 0.05 }
        return inside(bpm) || (octaves == true && (inside(bpm * 2) || inside(bpm / 2)))
    }

    func matches(_ a: TrackAnalysis) -> Bool {
        matches(bpm: a.bpm)
            && a.energy >= minEnergy && a.energy <= maxEnergy
            && (minor == nil || minor == a.keyMinor)
    }

    /// How far apart the outer tempos are, e.g. 0.05 = 5%.
    var span: Double { maxBPM > 0 ? (maxBPM - minBPM) / minBPM : 0 }

    var summary: String {
        var parts = [String(format: "%.0f–%.0f BPM", minBPM, maxBPM)]
        if octaves == true { parts.append("half/double time too") }
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
    static var palette: [Color] { [
        Color(hex: 0xcfdfff), Color(hex: 0xd0f0fd), Color(hex: 0xc2f5e9), Color(hex: 0xd1f7c4),
        Color(hex: 0xffeab6), Color(hex: 0xfee2d5), Color(hex: 0xffdce5), Color(hex: 0xffdaf6),
        Color(hex: 0xede2fe), Color(hex: 0xe5e9f0),
        // Stronger versions, which stand out on the dark screen.
        Color(hex: 0x8fb4ff), Color(hex: 0x7fd3f0), Color(hex: 0x6fdcc0), Color(hex: 0x9fe07f),
        Color(hex: 0xffd264), Color(hex: 0xffab78), Color(hex: 0xff8f8f), Color(hex: 0xff9fcf),
        Color(hex: 0xc4a2ff), Color(hex: 0xb4bccb),
    ] }
    static let paletteNames = ["Blue", "Cyan", "Teal", "Green", "Yellow", "Orange", "Red", "Pink", "Purple", "Grey",
                               "Strong blue", "Strong cyan", "Strong teal", "Strong green", "Strong yellow",
                               "Strong orange", "Strong red", "Strong pink", "Strong purple", "Strong grey"]

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
    func makeTempoGroups(bpms: [Double], span: Double = 0.04, minimum: Int = 3) {
        tags.removeAll { $0.automatic }
        // Fold every tempo into one octave (100…200) so half and double time
        // land together, then split that into ranges no wider than `span`.
        // The fold sits at 100/200, where no genre lives, so drum & bass
        // stays whole and hip-hop joins it at double time.
        func fold(_ b: Double) -> Double {
            var b = b
            while b < 100 { b *= 2 }
            while b >= 200 { b /= 2 }
            return b
        }
        let real = bpms.filter { $0 > 0 }
        let folded = real.map(fold).sorted()
        var i = 0
        var made = 0
        while i < folded.count {
            let low = folded[i]
            var j = i
            while j + 1 < folded.count && folded[j + 1] <= low * (1 + span) { j += 1 }
            if j - i + 1 >= minimum {
                // Exact edges (to 0.1 BPM) so neighbouring groups don't share
                // tracks; the name shows whole BPMs, and the other octave when
                // tracks there are in it.
                let rule = TagRule(minBPM: (low * 10).rounded(.down) / 10, maxBPM: (folded[j] * 10).rounded(.up) / 10,
                                   octaves: true)
                func range(_ f: Double) -> String {
                    let lo = Int((rule.minBPM * f).rounded()), hi = Int((rule.maxBPM * f).rounded())
                    return lo == hi ? "\(lo)" : "\(lo)–\(hi)"
                }
                let members = real.filter(rule.matches(bpm:))
                var names: [String] = []
                if members.contains(where: { $0 < rule.minBPM - 0.05 }) { names.append(range(0.5)) }
                if members.contains(where: { $0 >= rule.minBPM - 0.05 && $0 <= rule.maxBPM + 0.05 }) { names.append(range(1)) }
                if members.contains(where: { $0 > rule.maxBPM + 0.05 }) { names.append(range(2)) }
                var tag = TagDef(name: (names.isEmpty ? [range(1)] : names).joined(separator: " · ") + " BPM",
                                 colorIndex: made, rule: rule)
                tag.automatic = true
                tags.append(tag)
                made += 1
            }
            i = j + 1
        }
        save()
    }

    /// The usual tempo ranges per genre (from DJ guides; the edges vary a
    /// few BPM between sources). Added alongside your other groups; ones
    /// with the same name are left alone.
    static let genreGroups: [(name: String, min: Double, max: Double)] = [
        ("Hip-hop", 85, 100),
        ("House / dub techno", 118, 126),
        ("Techno", 126, 134),
        ("Peak techno", 134, 142),
        ("Hard techno", 142, 155),
        ("Drum & bass", 160, 178),
    ]

    func makeGenreGroups() {
        let have = Set(tags.filter { $0.rule != nil }.map(\.name))
        var index = tempoGroups.count
        for g in Self.genreGroups where !have.contains(g.name) {
            tags.append(TagDef(name: g.name, colorIndex: index, rule: TagRule(minBPM: g.min, maxBPM: g.max)))
            index += 1
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

//
//  Fields.swift
//  Spindle
//
//  Airtable-style fields for the Organize grid. Every track is a record:
//    • built-in fields from analysis (BPM, key, energy, …), locked
//    • Tags, a built-in multiple-select field (options in TagStore)
//    • Mix-ready, a checkbox shared with the Prep page
//    • your own fields: multiple select, single select, text, number,
//      checkbox or rating, kept in ~/Library/Application Support/Spindle/fields.json
//  A view (filter conditions, grouping, sort, hidden fields) decides
//  which records show and how; it is remembered between launches.
//

import Foundation
import Observation
import SwiftUI

// MARK: Your own fields

nonisolated enum FieldType: String, Codable, CaseIterable, Identifiable, Sendable {
    case multiSelect = "Multiple select", singleSelect = "Single select", text = "Text"
    case number = "Number", checkbox = "Checkbox", rating = "Rating"
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .multiSelect: "list.bullet.circle"
        case .singleSelect: "chevron.down.circle"
        case .text: "textformat"
        case .number: "number"
        case .checkbox: "checkmark.square"
        case .rating: "star"
        }
    }
}

nonisolated struct FieldOption: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var colorIndex: Int
    var color: Color { TagStore.palette[colorIndex % TagStore.palette.count] }
}

nonisolated struct CustomField: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var type: FieldType
    var options: [FieldOption] = []
}

nonisolated enum FieldValue: Codable, Equatable, Sendable {
    case options([UUID])
    case text(String)
    case number(Double)
    case bool(Bool)
    case rating(Int)
}

@Observable
final class FieldStore {
    private(set) var fields: [CustomField] = []
    /// Values per file path, per field.
    private(set) var values: [String: [UUID: FieldValue]] = [:]

    private struct Saved: Codable { var fields: [CustomField]; var values: [String: [UUID: FieldValue]] }

    nonisolated private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Spindle", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("fields.json")
    }
    nonisolated private static let writer = DispatchQueue(label: "spindle.save.fields", qos: .utility)

    init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            fields = saved.fields
            values = saved.values
        }
    }

    func field(_ id: UUID) -> CustomField? { fields.first { $0.id == id } }
    func value(_ path: String, _ field: UUID) -> FieldValue? { values[path]?[field] }

    @discardableResult
    func addField(name: String, type: FieldType) -> UUID {
        let field = CustomField(name: name, type: type)
        fields.append(field)
        save()
        return field.id
    }

    func update(_ field: CustomField) {
        guard let i = fields.firstIndex(where: { $0.id == field.id }) else { return }
        fields[i] = field
        save()
    }

    func deleteField(_ id: UUID) {
        fields.removeAll { $0.id == id }
        for key in values.keys {
            values[key]?[id] = nil
            if values[key]?.isEmpty == true { values[key] = nil }
        }
        save()
    }

    @discardableResult
    func addOption(_ field: UUID, name: String) -> UUID? {
        guard let i = fields.firstIndex(where: { $0.id == field }) else { return nil }
        let option = FieldOption(name: name, colorIndex: fields[i].options.count % TagStore.palette.count)
        fields[i].options.append(option)
        save()
        return option.id
    }

    func deleteOption(_ field: UUID, _ option: UUID) {
        guard let i = fields.firstIndex(where: { $0.id == field }) else { return }
        fields[i].options.removeAll { $0.id == option }
        for key in values.keys {
            if case .options(let ids) = values[key]?[field] {
                let left = ids.filter { $0 != option }
                values[key]?[field] = left.isEmpty ? nil : .options(left)
            }
        }
        save()
    }

    func set(_ path: String, _ field: UUID, _ value: FieldValue?) {
        var record = values[path] ?? [:]
        record[field] = value
        values[path] = record.isEmpty ? nil : record
        save()
    }

    private func save() {
        let snapshot = Saved(fields: fields, values: values)
        Self.writer.async {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: Self.fileURL, options: .atomic)
            }
        }
    }
}

// MARK: Field references

/// Any column of the grid.
nonisolated enum FieldRef: Hashable, Codable, Sendable {
    case name, folder, bpm, key, mood, energy, intro, outro, length, tempoGroup, tags, mixReady
    case custom(UUID)

    static let builtins: [FieldRef] = [.name, .folder, .bpm, .key, .mood, .energy, .tags, .mixReady, .tempoGroup, .intro, .outro, .length]

    /// Read-only fields (computed by analysis), shown with a lock.
    var locked: Bool {
        switch self {
        case .tags, .mixReady, .custom: false
        default: true
        }
    }
}

/// How a field behaves for filtering, grouping and sorting.
nonisolated enum FieldKind { case text, number, select, multi, checkbox }

// MARK: Views

nonisolated enum FilterOp: String, Codable, CaseIterable, Sendable {
    case contains = "contains", notContains = "does not contain", isText = "is", isNotText = "is not"
    case eq = "=", neq = "≠", lt = "<", lte = "≤", gt = ">", gte = "≥"
    case anyOf = "is any of", noneOf = "is none of"
    case hasAny = "has any of", hasAll = "has all of", hasNone = "has none of"
    case checked = "is checked", unchecked = "is not checked"
    case empty = "is empty", notEmpty = "is not empty"

    static func ops(for kind: FieldKind) -> [FilterOp] {
        switch kind {
        case .text: [.contains, .notContains, .isText, .isNotText, .empty, .notEmpty]
        case .number: [.eq, .neq, .lt, .lte, .gt, .gte, .empty, .notEmpty]
        case .select: [.anyOf, .noneOf, .empty, .notEmpty]
        case .multi: [.hasAny, .hasAll, .hasNone, .empty, .notEmpty]
        case .checkbox: [.checked, .unchecked]
        }
    }

    var needsText: Bool { [.contains, .notContains, .isText, .isNotText].contains(self) }
    var needsNumber: Bool { [.eq, .neq, .lt, .lte, .gt, .gte].contains(self) }
    var needsOptions: Bool { [.anyOf, .noneOf, .hasAny, .hasAll, .hasNone].contains(self) }
}

nonisolated struct FilterCondition: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var field: FieldRef
    var op: FilterOp
    var text = ""
    var number: Double?
    /// Option keys (see RecordContext.optionKeys).
    var options: [String] = []
}

nonisolated struct ViewSettings: Codable, Equatable, Sendable {
    var conditions: [FilterCondition] = []
    /// true = all conditions must match (and), false = any (or).
    var matchAll = true
    var groupBy: FieldRef?
    var sortField: FieldRef?
    var sortAscending = true
    var hidden: Set<FieldRef> = [.intro, .outro, .mood]
    var collapsed: Set<String> = []
    /// Column order (after the track name), as arranged in Hide fields.
    var fieldOrder: [FieldRef]?

    static let key = "organize.view"

    static func load() -> ViewSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let v = try? JSONDecoder().decode(ViewSettings.self, from: data) else { return ViewSettings() }
        return v
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

/// A saved combination of filter, grouping, sort and hidden fields
/// (Airtable's "views"), to switch to with one click.
nonisolated struct SavedView: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var settings: ViewSettings

    static let key = "organize.savedViews"

    static func loadAll() -> [SavedView] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let v = try? JSONDecoder().decode([SavedView].self, from: data) else { return [] }
        return v
    }

    static func saveAll(_ views: [SavedView]) {
        if let data = try? JSONEncoder().encode(views) { UserDefaults.standard.set(data, forKey: key) }
    }
}

extension ViewSettings {
    /// Same filter, grouping, sort and hidden fields (which groups are
    /// folded open doesn't count as a change).
    func sameSetup(as other: ViewSettings) -> Bool {
        var a = self, b = other
        a.collapsed = []
        b.collapsed = []
        for i in a.conditions.indices { a.conditions[i].id = b.conditions.indices.contains(i) ? b.conditions[i].id : a.conditions[i].id }
        return a == b
    }

    /// One line describing the view, e.g. "Filter: Energy, Tags · Group: Key".
    func summary(_ context: RecordContext) -> String {
        var parts: [String] = []
        if !conditions.isEmpty { parts.append("Filter: " + conditions.map { context.name($0.field) }.joined(separator: ", ")) }
        if let g = groupBy { parts.append("Group: " + context.name(g)) }
        if let s = sortField { parts.append("Sort: " + context.name(s)) }
        return parts.isEmpty ? "All tracks, no filter" : parts.joined(separator: " · ")
    }
}

// MARK: Reading records

/// A record in the grid.
struct Record: Identifiable {
    let track: LibraryTrack
    let analysis: TrackAnalysis?
    /// Position in the list (playlist order).
    let index: Int
    var id: URL { track.url }
    var path: String { track.url.path }
}

/// A choice in a select-like field, for pills, filters and group headers.
struct OptionInfo: Identifiable, Equatable {
    let id: String
    let name: String
    let color: Color
}

/// Reads any field of a record, and filters, groups and sorts records.
struct RecordContext {
    let library: LibraryModel
    let fields: FieldStore
    let prep: PrepStore

    var tags: TagStore { library.tags }

    func name(_ ref: FieldRef) -> String {
        switch ref {
        case .name: "Track"
        case .folder: "Folder"
        case .bpm: "BPM"
        case .key: "Key"
        case .mood: "Mood"
        case .energy: "Energy"
        case .intro: "Intro"
        case .outro: "Outro"
        case .length: "Length"
        case .tempoGroup: "Tempo group"
        case .tags: "Tags"
        case .mixReady: "Mix-ready"
        case .custom(let id): fields.field(id)?.name ?? "Field"
        }
    }

    func kind(_ ref: FieldRef) -> FieldKind {
        switch ref {
        case .name, .folder: .text
        case .bpm, .energy, .length: .number
        case .key, .mood, .intro, .outro, .tempoGroup: .select
        case .tags: .multi
        case .mixReady: .checkbox
        case .custom(let id):
            switch fields.field(id)?.type ?? .text {
            case .multiSelect: .multi
            case .singleSelect: .select
            case .text: .text
            case .number, .rating: .number
            case .checkbox: .checkbox
            }
        }
    }

    var allFields: [FieldRef] { FieldRef.builtins + fields.fields.map { .custom($0.id) } }

    /// All fields in the view's column order: the track name first, then
    /// the arranged fields, then any new fields not arranged yet.
    func orderedFields(_ view: ViewSettings) -> [FieldRef] {
        let all = allFields
        let existing = Set(all)
        var result: [FieldRef] = [.name]
        for f in view.fieldOrder ?? [] where f != .name && existing.contains(f) && !result.contains(f) { result.append(f) }
        for f in all where !result.contains(f) { result.append(f) }
        return result
    }

    // Values

    func text(_ r: Record, _ ref: FieldRef) -> String? {
        switch ref {
        case .name: return r.track.name
        case .folder: return r.track.crate
        case .custom(let id):
            if case .text(let t)? = fields.value(r.path, id), !t.isEmpty { return t }
            return nil
        default: return nil
        }
    }

    func number(_ r: Record, _ ref: FieldRef) -> Double? {
        switch ref {
        case .bpm: return r.analysis?.bpm
        case .energy: return r.analysis.map { Double($0.energy) }
        case .length: return r.analysis?.duration
        case .custom(let id):
            switch fields.value(r.path, id) {
            case .number(let n)?: return n
            case .rating(let n)?: return n > 0 ? Double(n) : nil
            default: return nil
            }
        default: return nil
        }
    }

    func checked(_ r: Record, _ ref: FieldRef) -> Bool {
        switch ref {
        case .mixReady: return prep.prep(for: r.id)?.mixReady == true
        case .custom(let id):
            if case .bool(let b)? = fields.value(r.path, id) { return b }
            return false
        default: return false
        }
    }

    /// Every choice a select-like field can have, in display order.
    func options(_ ref: FieldRef, records: [Record] = []) -> [OptionInfo] {
        switch ref {
        case .key:
            return (1...12).flatMap { n in [true, false].map { minor in
                OptionInfo(id: "\(n)\(minor ? "A" : "B")", name: "\(n) \(KeyStyle.mood(minor: minor))",
                           color: KeyStyle.color(number: n, minor: minor))
            } }
        case .mood:
            return [OptionInfo(id: "A", name: "Dark", color: Color(hex: 0xc9c2e8)),
                    OptionInfo(id: "B", name: "Bright", color: Color(hex: 0xffeab6))]
        case .intro, .outro:
            return SectionType.allCases.map { OptionInfo(id: $0.rawValue, name: $0.rawValue, color: Color(hex: 0xe5e9f0)) }
        case .tempoGroup:
            return tags.tempoGroups.map { OptionInfo(id: $0.id.uuidString, name: $0.name, color: $0.color) }
        case .tags:
            return tags.manualTags.map { OptionInfo(id: $0.id.uuidString, name: $0.name, color: $0.color) }
        case .custom(let id):
            return (fields.field(id)?.options ?? []).map { OptionInfo(id: $0.id.uuidString, name: $0.name, color: $0.color) }
        default:
            return []
        }
    }

    /// The record's choices in a select-like field (option ids).
    func optionKeys(_ r: Record, _ ref: FieldRef) -> [String] {
        switch ref {
        case .key: return r.analysis.map { ["\($0.camelotNumber)\($0.keyMinor ? "A" : "B")"] } ?? []
        case .mood: return r.analysis.map { [$0.keyMinor ? "A" : "B"] } ?? []
        case .intro: return r.analysis.map { [$0.intro.rawValue] } ?? []
        case .outro: return r.analysis.map { [$0.outro.rawValue] } ?? []
        case .tempoGroup:
            guard let a = r.analysis else { return [] }
            return tags.tempoGroups.filter { $0.rule?.matches(a) == true }.map(\.id.uuidString)
        case .tags:
            return tags.manualTags(for: r.path).map(\.id.uuidString)
        case .custom(let id):
            guard case .options(let ids)? = fields.value(r.path, id), let field = fields.field(id) else { return [] }
            // Option order, as Airtable shows them.
            return field.options.filter { ids.contains($0.id) }.map(\.id.uuidString)
        default: return []
        }
    }

    func isEmpty(_ r: Record, _ ref: FieldRef) -> Bool {
        switch kind(ref) {
        case .text: text(r, ref) == nil
        case .number: number(r, ref) == nil
        case .select, .multi: optionKeys(r, ref).isEmpty
        case .checkbox: !checked(r, ref)
        }
    }

    // Filtering

    func passes(_ r: Record, _ c: FilterCondition) -> Bool {
        switch c.op {
        case .empty: return isEmpty(r, c.field)
        case .notEmpty: return !isEmpty(r, c.field)
        case .checked: return checked(r, c.field)
        case .unchecked: return !checked(r, c.field)
        case .contains, .notContains, .isText, .isNotText:
            let t = c.text.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { return true }
            let v = text(r, c.field) ?? ""
            switch c.op {
            case .contains: return v.localizedCaseInsensitiveContains(t)
            case .notContains: return !v.localizedCaseInsensitiveContains(t)
            case .isText: return v.compare(t, options: .caseInsensitive) == .orderedSame
            default: return v.compare(t, options: .caseInsensitive) != .orderedSame
            }
        case .eq, .neq, .lt, .lte, .gt, .gte:
            guard let n = c.number else { return true }
            guard let v = number(r, c.field) else { return c.op == .neq }
            switch c.op {
            case .eq: return abs(v - n) < 0.05
            case .neq: return abs(v - n) >= 0.05
            case .lt: return v < n
            case .lte: return v <= n + 0.05
            case .gt: return v > n
            default: return v >= n - 0.05
            }
        case .anyOf, .noneOf, .hasAny, .hasAll, .hasNone:
            guard !c.options.isEmpty else { return true }
            let mine = Set(optionKeys(r, c.field)), wanted = Set(c.options)
            switch c.op {
            case .anyOf, .hasAny: return !mine.isDisjoint(with: wanted)
            case .noneOf, .hasNone: return mine.isDisjoint(with: wanted)
            default: return wanted.isSubset(of: mine)
            }
        }
    }

    func apply(_ view: ViewSettings, to records: [Record]) -> [Record] {
        var result = records
        let conditions = view.conditions
        if !conditions.isEmpty {
            result = result.filter { r in
                view.matchAll ? conditions.allSatisfy { passes(r, $0) } : conditions.contains { passes(r, $0) }
            }
        }
        if let field = view.sortField {
            result.sort { a, b in
                let less = compare(a, b, field)
                return view.sortAscending ? less : compare(b, a, field)
            }
        }
        return result
    }

    private func compare(_ a: Record, _ b: Record, _ ref: FieldRef) -> Bool {
        switch kind(ref) {
        case .text: return (text(a, ref) ?? "").localizedStandardCompare(text(b, ref) ?? "") == .orderedAscending
        case .number: return (number(a, ref) ?? -.infinity) < (number(b, ref) ?? -.infinity)
        case .checkbox: return !checked(a, ref) && checked(b, ref)
        case .select, .multi:
            let order = Dictionary(uniqueKeysWithValues: options(ref).enumerated().map { ($1.id, $0) })
            let ka = optionKeys(a, ref).compactMap { order[$0] }, kb = optionKeys(b, ref).compactMap { order[$0] }
            return (ka.first ?? Int.max, ka.count) < (kb.first ?? Int.max, kb.count)
        }
    }

    // Grouping

    struct Group: Identifiable {
        let id: String
        let title: String
        let options: [OptionInfo]
        var records: [Record]
    }

    /// Groups in Airtable's way: one group per value (or per combination of
    /// values for multiple-select fields), empty values last.
    func group(_ records: [Record], by ref: FieldRef) -> [Group] {
        var groups: [String: Group] = [:]
        var order: [String] = []
        let all = options(ref)
        let lookup = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        func add(_ key: String, _ title: String, _ opts: [OptionInfo], _ r: Record) {
            if groups[key] == nil { groups[key] = Group(id: key, title: title, options: opts, records: []); order.append(key) }
            groups[key]!.records.append(r)
        }
        for r in records {
            switch kind(ref) {
            case .select, .multi:
                let keys = optionKeys(r, ref)
                if keys.isEmpty { add("∅", "Empty", [], r) }
                else { add(keys.joined(separator: "+"), "", keys.compactMap { lookup[$0] }, r) }
            case .text:
                let t = text(r, ref)
                add(t ?? "∅", t ?? "Empty", [], r)
            case .number:
                if let n = number(r, ref) {
                    let label = ref == .length ? String(format: "%d min", Int(n) / 60) : (n == n.rounded() ? "\(Int(n))" : String(format: "%.1f", n))
                    add(label, label, [], r)
                } else { add("∅", "Empty", [], r) }
            case .checkbox:
                let c = checked(r, ref)
                add(c ? "1" : "0", c ? "Checked" : "Unchecked", [], r)
            }
        }
        // Order groups by their value.
        let indexOf = Dictionary(uniqueKeysWithValues: all.enumerated().map { ($1.id, $0) })
        func rank(_ key: String) -> (Int, Double, String) {
            if key == "∅" { return (2, 0, "") }
            switch kind(ref) {
            case .select, .multi:
                let parts = key.split(separator: "+").map(String.init)
                return (0, Double((parts.first.flatMap { indexOf[$0] } ?? 999) * 100 + parts.count), key)
            case .number:
                let n = groups[key]?.records.first.flatMap { number($0, ref) } ?? 0
                return (0, ref == .length ? Double(Int(n) / 60) : n, key)
            case .checkbox: return (0, key == "1" ? 0 : 1, key)
            case .text: return (0, 0, key.lowercased())
            }
        }
        return order.sorted { rank($0) < rank($1) }.compactMap { groups[$0] }
    }
}

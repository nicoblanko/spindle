//
//  TrackPrep.swift
//  Spindle
//
//  What the Prep page stores per track: the beatgrid, the four cue roles
//  (1 IN, 2 DROP, 3 BRK, 4 OUT), saved loops, the clip's FX and the
//  mix-ready flag. Kept in ~/Library/Application Support/Spindle/prep.json,
//  keyed by file path.
//

import Foundation
import Observation
import SwiftUI

nonisolated enum CueRole: Int, Codable, Sendable, CaseIterable, Identifiable {
    case intro = 1, drop = 2, breakdown = 3, outro = 4
    var id: Int { rawValue }

    var name: String {
        switch self {
        case .intro: "IN"
        case .drop: "DROP"
        case .breakdown: "BRK"
        case .outro: "OUT"
        }
    }

    /// Fixed cue colours from the style guide.
    var color: Color {
        switch self {
        case .intro: Color(hex: 0x2fbf71)
        case .drop: Color(hex: 0xe6c229)
        case .breakdown: Color(hex: 0x3fb6d9)
        case .outro: Color(hex: 0xd9534f)
        }
    }
}

/// A cue point. Any number per track; its slot number (1, 2, 3…) is its
/// place in the list, which is what the number keys and pads use. `kind`
/// remembers which suggestion placed it (IN, DROP…), if any.
nonisolated struct Cue: Codable, Sendable, Equatable, Identifiable {
    var id = UUID()
    /// Seconds into the track.
    var time: Double
    var name: String
    /// Index into `Cue.palette`.
    var color: Int
    /// Placed by the auto-suggestion rather than by hand.
    var auto: Bool = false
    var kind: CueRole?

    /// The four style-guide cue colours first, then four more.
    static let paletteHex: [UInt32] = [0x2fbf71, 0xe6c229, 0x3fb6d9, 0xd9534f, 0x9b7bd9, 0xd96fa8, 0x5fd3c4, 0x9a9aa1]
    static var palette: [Color] { paletteHex.map { Color(hex: $0) } }
    var swatch: Color { Color(hex: Self.paletteHex[(color % Self.paletteHex.count + Self.paletteHex.count) % Self.paletteHex.count]) }

    init(time: Double, name: String, color: Int, auto: Bool = false, kind: CueRole? = nil) {
        self.time = time; self.name = name; self.color = color; self.auto = auto; self.kind = kind
    }

    private enum Keys: String, CodingKey { case id, time, name, color, auto, kind, role }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        time = try c.decode(Double.self, forKey: .time)
        auto = try c.decodeIfPresent(Bool.self, forKey: .auto) ?? false
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        // Older files stored a fixed role (1 IN … 4 OUT).
        let role = try c.decodeIfPresent(CueRole.self, forKey: .role)
        kind = try c.decodeIfPresent(CueRole.self, forKey: .kind) ?? role
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? role?.name ?? "CUE"
        color = try c.decodeIfPresent(Int.self, forKey: .color) ?? ((role?.rawValue ?? 1) - 1)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(id, forKey: .id); try c.encode(time, forKey: .time); try c.encode(name, forKey: .name)
        try c.encode(color, forKey: .color); try c.encode(auto, forKey: .auto); try c.encodeIfPresent(kind, forKey: .kind)
    }
}

/// A loop slot: an in-point and a length in bars.
nonisolated struct SavedLoop: Codable, Sendable, Equatable, Identifiable {
    var id = UUID()
    var start: Double
    var beats: Int
    var bars: Double { Double(beats) / 4 }
    static let barChoices: [Double] = [0.25, 0.5, 1, 2, 4, 8, 16, 32]
    static func barLabel(_ bars: Double) -> String {
        bars == 0.25 ? "¼" : bars == 0.5 ? "½" : "\(Int(bars))"
    }
}

/// The FX on a clip or deck.
nonisolated enum FXKind: String, CaseIterable, Identifiable, Sendable {
    case filter, echo, reverb, flanger, crush, gate
    var id: String { rawValue }
    var short: String {
        switch self {
        case .filter: "FILTER"
        case .echo: "ECHO"
        case .reverb: "VERB"
        case .flanger: "FLANGE"
        case .crush: "CRUSH"
        case .gate: "GATE"
        }
    }
    /// Filter runs −1 (low-pass) … 1 (high-pass); the rest 0 … 1.
    var bipolar: Bool { self == .filter }
}

/// FX that travel with a clip: applied to the deck when the clip is loaded.
nonisolated struct ClipFX: Codable, Sendable, Equatable {
    var filter: Double = 0
    var echo: Double = 0
    var reverb: Double = 0
    var flanger: Double = 0
    var crush: Double = 0
    var gate: Double = 0

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        for kind in FXKind.allCases {
            if let key = CodingKeys(stringValue: kind.rawValue), let v = try c.decodeIfPresent(Double.self, forKey: key) { self[kind] = v }
        }
    }

    subscript(kind: FXKind) -> Double {
        get {
            switch kind {
            case .filter: filter
            case .echo: echo
            case .reverb: reverb
            case .flanger: flanger
            case .crush: crush
            case .gate: gate
            }
        }
        set {
            switch kind {
            case .filter: filter = newValue
            case .echo: echo = newValue
            case .reverb: reverb = newValue
            case .flanger: flanger = newValue
            case .crush: crush = newValue
            case .gate: gate = newValue
            }
        }
    }

    var isEmpty: Bool { FXKind.allCases.allSatisfy { abs(self[$0]) < 0.01 } }

    var summary: String {
        FXKind.allCases.compactMap { kind -> String? in
            let v = self[kind]
            guard abs(v) > 0.01 else { return nil }
            if kind == .filter { return (v < 0 ? "LP " : "HP ") + "\(Int(abs(v) * 100))" }
            return "\(kind.short) \(Int(v * 100))"
        }.joined(separator: " · ")
    }
}

nonisolated struct TrackPrep: Codable, Sendable, Equatable {
    var bpm: Double
    /// Time of the first downbeat (bar 1, beat 1) in seconds. The grid runs
    /// from here in both directions.
    var gridOffset: Double
    var cues: [Cue] = []
    var loops: [SavedLoop] = []
    var fx = ClipFX()
    var mixReady = false
    /// The detector wasn't sure the grid is on the kick (not the off-beat).
    var gridUnsure: Bool?

    var beatSeconds: Double { 60 / bpm }

    /// The cue the suggestion placed for this role (IN, DROP…).
    func cue(_ role: CueRole) -> Cue? { cues.first { $0.kind == role } }

    /// Sets the suggested cue for a role, replacing the previous one.
    mutating func setCue(_ role: CueRole, time: Double?, auto: Bool = false) {
        if let i = cues.firstIndex(where: { $0.kind == role }) {
            if let time { cues[i].time = time; cues[i].auto = auto } else { cues.remove(at: i) }
        } else if let time {
            cues.append(Cue(time: time, name: role.name, color: role.rawValue - 1, auto: auto, kind: role))
        }
    }

    /// Cue slot `n` (0-based): moves it here, or adds a new cue.
    mutating func setCue(slot n: Int, time: Double) {
        if cues.indices.contains(n) { cues[n].time = time; cues[n].auto = false }
        else { addCue(at: time) }
    }

    mutating func addCue(at time: Double) {
        let n = cues.count
        cues.append(Cue(time: time, name: "CUE \(n + 1)", color: n % Cue.paletteHex.count))
    }

    /// Nearest beat to `time`.
    func snap(_ time: Double, toBeats beats: Int = 1) -> Double {
        let unit = beatSeconds * Double(beats)
        return gridOffset + ((time - gridOffset) / unit).rounded() * unit
    }

    /// Beat number from the first downbeat (0 = bar 1 beat 1).
    func beatIndex(at time: Double) -> Double { (time - gridOffset) / beatSeconds }
}

@Observable
final class PrepStore {
    private(set) var preps: [String: TrackPrep] = [:]

    nonisolated private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Spindle", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("prep.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let decoded = try? JSONDecoder().decode([String: TrackPrep].self, from: data) {
            preps = decoded
        }
    }

    func prep(for url: URL) -> TrackPrep? { preps[url.path] }

    func update(_ url: URL, _ change: (inout TrackPrep) -> Void) {
        guard var prep = preps[url.path] else { return }
        change(&prep)
        preps[url.path] = prep
        scheduleSave()
    }

    /// Removes every cue and loop slot from every track (grids stay).
    func clearAllCuesAndLoops() -> Int {
        var count = 0
        for (path, p) in preps where !p.cues.isEmpty || !p.loops.isEmpty {
            var q = p
            q.cues = []
            q.loops = []
            preps[path] = q
            count += 1
        }
        if count > 0 { scheduleSave() }
        return count
    }

    func set(_ prep: TrackPrep, for url: URL) {
        preps[url.path] = prep
        scheduleSave()
    }

    private var saveTask: Task<Void, Never>?

    /// Writes at most twice a second, so dragging a value doesn't hammer the disk.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            let snapshot = self.preps
            await Task.detached(priority: .utility) {
                if let data = try? JSONEncoder().encode(snapshot) {
                    // Backed up like the playlists, at most every 10 minutes.
                    SafeWrite.write(data, to: Self.fileURL, every: 600)
                }
            }.value
        }
    }
}

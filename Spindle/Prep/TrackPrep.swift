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

nonisolated struct Cue: Codable, Sendable, Equatable {
    var role: CueRole
    /// Seconds into the track.
    var time: Double
    /// Placed by the auto-suggestion rather than by hand.
    var auto: Bool
}

nonisolated struct SavedLoop: Codable, Sendable, Equatable, Identifiable {
    var id = UUID()
    var start: Double
    var beats: Int
}

/// FX that travel with a clip: applied to the deck when the clip is loaded.
nonisolated struct ClipFX: Codable, Sendable, Equatable {
    /// −1 … 1: negative is a low-pass, positive a high-pass, 0 is off.
    var filter: Double = 0
    /// 0 … 1: echo amount (wet level and feedback).
    var echo: Double = 0

    var isEmpty: Bool { abs(filter) < 0.01 && echo < 0.01 }

    var summary: String {
        var parts: [String] = []
        if filter < -0.01 { parts.append("LP \(Int(-filter * 100))") }
        if filter > 0.01 { parts.append("HP \(Int(filter * 100))") }
        if echo > 0.01 { parts.append("ECHO \(Int(echo * 100))") }
        return parts.joined(separator: " · ")
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

    var beatSeconds: Double { 60 / bpm }

    func cue(_ role: CueRole) -> Cue? { cues.first { $0.role == role } }

    mutating func setCue(_ role: CueRole, time: Double?, auto: Bool = false) {
        cues.removeAll { $0.role == role }
        if let time { cues.append(Cue(role: role, time: time, auto: auto)) }
        cues.sort { $0.role.rawValue < $1.role.rawValue }
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
                    try? data.write(to: Self.fileURL, options: .atomic)
                }
            }.value
        }
    }
}

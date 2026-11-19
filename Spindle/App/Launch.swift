//
//  Launch.swift
//  Spindle
//
//  The Launch page: a clip launcher for DJing. Six channels × eight scenes;
//  each cell holds a clip cut from a prepped track (from a cue, a number of
//  bars, looped; or the whole track once). Clips start and stop on the
//  master clock (next beat, bar or 4 bars). Kept in
//  ~/Library/Application Support/Spindle/launch.json.
//

import Foundation
import Observation

nonisolated enum ClipStart: String, Codable, CaseIterable, Sendable, Identifiable {
    case start = "Start", intro = "IN", drop = "DROP", breakdown = "BRK", outro = "OUT"
    var id: String { rawValue }
    var role: CueRole? {
        switch self {
        case .start: nil
        case .intro: .intro
        case .drop: .drop
        case .breakdown: .breakdown
        case .outro: .outro
        }
    }
}

nonisolated struct LaunchClip: Codable, Sendable, Identifiable, Equatable {
    var id: Int
    var path: String
    var start: ClipStart
    /// Loop length in bars; 0 = play the track once from `start`.
    var bars: Int
    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.deletingPathExtension().lastPathComponent }
    var part: String { bars == 0 ? "\(start.rawValue) · to the end" : "\(start.rawValue) · \(bars) bar\(bars == 1 ? "" : "s")" }
}

nonisolated struct LaunchSet: Codable, Sendable, Equatable {
    static let rows = 8
    static let columns = 6
    /// "row,column" → clip.
    var clips: [String: LaunchClip] = [:]
    var scenes: [String] = (1...rows).map { "Scene \($0)" }
    var channels: [String] = ["Drums", "Bass", "Lead", "Pads", "Vocal", "FX"]
    var nextID = 1

    static func key(_ row: Int, _ column: Int) -> String { "\(row),\(column)" }
    func clip(_ row: Int, _ column: Int) -> LaunchClip? { clips[Self.key(row, column)] }
}

nonisolated enum TempoSource: String, Codable, CaseIterable, Sendable, Identifiable {
    case manual = "Manual", deckA = "Deck A", deckB = "Deck B"
    var id: String { rawValue }
}

@Observable
final class LaunchModel {
    private(set) var set = LaunchSet()
    var tempoSource: TempoSource = .manual
    var manualBPM: Double = 128
    /// Launch quantize in beats: 1, 4 (a bar) or 16 (4 bars).
    var quantize: Int = 4
    var volumes = [Double](repeating: 0.8, count: LaunchSet.columns)
    var filters = [Double](repeating: 0, count: LaunchSet.columns)
    var muted = [Bool](repeating: false, count: LaunchSet.columns)
    /// Clips whose audio is being read from disk.
    var loading = Set<Int>()
    var error: String?

    /// Decoded audio per clip id, owned here; the players only borrow it.
    var cache: [Int: (signature: String, samples: UnsafeMutablePointer<TrackSamples>)] = [:]
    /// Sample memory waiting until no player uses it.
    var retired: [UnsafeMutablePointer<TrackSamples>] = []

    nonisolated private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Spindle", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("launch.json")
    }
    nonisolated private static let writer = DispatchQueue(label: "spindle.save.launch", qos: .utility)

    init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let decoded = try? JSONDecoder().decode(LaunchSet.self, from: data) {
            set = decoded
        }
    }

    func update(_ change: (inout LaunchSet) -> Void) {
        change(&set)
        let snapshot = set
        Self.writer.async {
            if let data = try? JSONEncoder().encode(snapshot) { SafeWrite.write(data, to: Self.fileURL) }
        }
    }
}

extension AppModel {
    // MARK: Clock

    /// The next launch point on the master clock.
    func nextLaunchBeat() -> Double {
        guard let engine else { return 0 }
        let q = Double(max(launch.quantize, 1))
        return ((engine.masterBeat / q).rounded(.down) + 1) * q
    }

    /// Keeps the master tempo in step with its source (called a few times a second).
    func updateMasterTempo() {
        guard let engine else { return }
        switch launch.tempoSource {
        case .manual:
            engine.masterBPM = launch.manualBPM
        case .deckA, .deckB:
            let deck = decks[launch.tempoSource == .deckA ? 0 : 1]
            if deck.playing, let bpm = liveBPM(deck) { engine.masterBPM = bpm }
        }
        // Free clip audio no player uses any more.
        launch.retired.removeAll { samples in
            guard !engine.clipPlayers.contains(where: { $0.uses(samples) }) else { return false }
            samples.pointee.free()
            samples.deallocate()
            return true
        }
    }

    var masterBPM: Double { engine?.masterBPM ?? launch.manualBPM }

    // MARK: Clips

    /// Puts a track in a cell as a clip: from its DROP (else IN, else the
    /// first bar), 8 bars, looped.
    func assignClip(_ url: URL, row: Int, column: Int) {
        let prep = prep.prep(for: url)
        let start: ClipStart = prep?.cue(.drop) != nil ? .drop : (prep?.cue(.intro) != nil ? .intro : .start)
        launch.update { set in
            let clip = LaunchClip(id: set.nextID, path: url.path, start: start, bars: 8)
            set.nextID += 1
            set.clips[LaunchSet.key(row, column)] = clip
        }
        Task { await analysis.analyze([url]); await prepareAll() }
    }

    func editClip(row: Int, column: Int, _ change: (inout LaunchClip) -> Void) {
        guard var clip = launch.set.clip(row, column) else { return }
        change(&clip)
        dropCache(clip.id)
        launch.update { $0.clips[LaunchSet.key(row, column)] = clip }
    }

    func removeClip(row: Int, column: Int) {
        guard let clip = launch.set.clip(row, column) else { return }
        if let p = engine?.clipPlayers[column], p.telemetry.pointee.clipID == clip.id || p.telemetry.pointee.pendingID == clip.id {
            p.stop(atBeat: nextLaunchBeat())
        }
        dropCache(clip.id)
        launch.update { $0.clips[LaunchSet.key(row, column)] = nil }
    }

    private func dropCache(_ id: Int) {
        if let entry = launch.cache.removeValue(forKey: id) { launch.retired.append(entry.samples) }
    }

    /// The clip's tempo, start time and length in seconds of the track.
    func clipTiming(_ clip: LaunchClip) -> (bpm: Double, start: Double, duration: Double) {
        let p = prep.prep(for: clip.url)
        let a = analysis.analysis(for: clip.url)
        let bpm = p?.bpm ?? a?.bpm ?? 128
        let start = clip.start.role.flatMap { p?.cue($0)?.time } ?? p?.gridOffset ?? 0
        let duration = clip.bars > 0 ? Double(clip.bars * 4) * 60 / bpm : max(1, (a?.duration ?? 600) - start)
        return (bpm, start, duration)
    }

    /// Loads (once) and returns the clip's audio at the engine's sample rate.
    func clipSamples(_ clip: LaunchClip) async -> UnsafeMutablePointer<TrackSamples>? {
        guard let engine else { return nil }
        let timing = clipTiming(clip)
        let signature = "\(clip.path)|\(clip.start.rawValue)|\(clip.bars)|\(timing.bpm)|\(timing.start)|\(engine.sampleRate)"
        if let cached = launch.cache[clip.id], cached.signature == signature { return cached.samples }
        dropCache(clip.id)
        launch.loading.insert(clip.id)
        defer { launch.loading.remove(clip.id) }
        let rate = engine.sampleRate
        let url = clip.url
        let result = await Task.detached(priority: .userInitiated) {
            Result { try TrackLoader.loadRegion(url: url, sampleRate: rate, start: timing.start, duration: timing.duration) }
        }.value
        switch result {
        case .success(let samples):
            launch.cache[clip.id] = (signature, samples)
            return samples
        case .failure(let error):
            launch.error = "\(clip.name): \(error.localizedDescription)"
            spindleLog.error("Launch: couldn't load \(clip.name): \(error.localizedDescription)")
            return nil
        }
    }

    /// Clicking a clip: starts it on the next launch point, or stops it if
    /// it is already playing or waiting.
    func toggleClip(row: Int, column: Int) {
        guard let engine, let clip = launch.set.clip(row, column) else { return }
        let t = engine.clipPlayers[column].telemetry.pointee
        if t.clipID == clip.id || t.pendingID == clip.id {
            engine.clipPlayers[column].stop(atBeat: nextLaunchBeat())
        } else {
            start([(column, clip)])
        }
    }

    /// Starts clips together on the next launch point (after loading them).
    func start(_ items: [(column: Int, clip: LaunchClip)]) {
        Task {
            var ready: [(Int, LaunchClip, UnsafeMutablePointer<TrackSamples>)] = []
            for (column, clip) in items {
                if let samples = await clipSamples(clip) { ready.append((column, clip, samples)) }
            }
            guard let engine = self.engine else { return }
            let beat = nextLaunchBeat()
            for (column, clip, samples) in ready {
                let timing = clipTiming(clip)
                let loopFrames = clip.bars > 0 ? timing.duration * engine.sampleRate : 0
                engine.clipPlayers[column].launch(samples, id: clip.id, bpm: timing.bpm, loopFrames: loopFrames, atBeat: beat)
            }
        }
    }

    /// A scene: every clip in the row starts together; channels with no
    /// clip in that row stop.
    func launchScene(_ row: Int) {
        guard let engine else { return }
        var items: [(Int, LaunchClip)] = []
        for column in 0..<LaunchSet.columns {
            if let clip = launch.set.clip(row, column) { items.append((column, clip)) }
            else { engine.clipPlayers[column].stop(atBeat: nextLaunchBeat()) }
        }
        start(items)
    }

    func stopChannel(_ column: Int) {
        engine?.clipPlayers[column].stop(atBeat: nextLaunchBeat())
    }

    func stopAllClips() {
        for column in 0..<LaunchSet.columns { stopChannel(column) }
    }

    // MARK: Channels

    func setChannelVolume(_ v: Double, _ column: Int) {
        launch.volumes[column] = v
        engine?.clipPlayers[column].gain = Float(v * v)
    }

    func setChannelFilter(_ v: Double, _ column: Int) {
        launch.filters[column] = v
        engine?.clipPlayers[column].filter = v
    }

    func setChannelMute(_ on: Bool, _ column: Int) {
        launch.muted[column] = on
        engine?.clipPlayers[column].muted = on
    }

    /// After the engine (re)starts: channel settings onto the new players;
    /// decoded clips were for the old engine's sample rate.
    func applyLaunchSettings() {
        guard let engine else { return }
        for c in 0..<LaunchSet.columns {
            engine.clipPlayers[c].gain = Float(launch.volumes[c] * launch.volumes[c])
            engine.clipPlayers[c].filter = launch.filters[c]
            engine.clipPlayers[c].muted = launch.muted[c]
        }
        for (id, _) in launch.cache { dropCache(id) }
        updateMasterTempo()
    }
}

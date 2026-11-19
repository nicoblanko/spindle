//
//  SessionStore.swift
//  Spindle
//
//  Sessions: records the mix to a WAV file and logs a tracklist with
//  timestamps while recording. Each session is a folder under
//  ~/Music/Spindle Sessions holding mix.wav and session.json.
//
//  A track goes on the tracklist once its deck has played it forward for
//  20 seconds; its timestamp is when that playing started.
//

@preconcurrency import AVFoundation
import AppKit
import Foundation
import Observation
import Synchronization

nonisolated struct TracklistEntry: Codable, Sendable, Identifiable, Equatable {
    var id = UUID()
    /// Seconds from the start of the recording.
    var time: Double
    var title: String
    var artist: String
    var deck: String
    var bpm: Double?
    var key: String?
    var path: String
}

nonisolated struct SessionInfo: Codable, Sendable, Identifiable, Equatable {
    /// Folder name.
    var id: String
    var started: Date
    var duration: Double
    var source: String
    var entries: [TracklistEntry]
    var droppedFrames: Int = 0

    var tracklistText: String {
        entries.map { e in
            let who = e.artist.isEmpty ? e.title : "\(e.artist) – \(e.title)"
            return "\(SessionStore.clock(e.time))  \(who)"
        }.joined(separator: "\n")
    }
}

@Observable
final class SessionStore {
    private(set) var sessions: [SessionInfo] = []
    private(set) var recording = false
    private(set) var elapsed: Double = 0
    private(set) var level: Float = 0
    private(set) var current: SessionInfo?
    var error: String?
    var selected: String?

    private var writer: SessionWriter?
    private var startedAt = Date()
    private var candidate: [Int: (url: URL, seconds: Double)] = [:]
    private var lastLogged: [Int: URL] = [:]

    static var folder: URL {
        let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first!
        return music.appendingPathComponent("Spindle Sessions", isDirectory: true)
    }

    init() { reload() }

    func reload() {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? []
        sessions = dirs.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("session.json")) else { return nil }
            return try? JSONDecoder.session.decode(SessionInfo.self, from: data)
        }.sorted { $0.started > $1.started }
    }

    func audioURL(_ session: SessionInfo) -> URL {
        Self.folder.appendingPathComponent(session.id).appendingPathComponent("mix.wav")
    }

    // MARK: Recording

    func start(model: AppModel) {
        guard !recording, let engine = model.engine else {
            error = model.engine == nil ? "Start the audio engine before recording." : nil
            return
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let id = formatter.string(from: Date())
        let dir = Self.folder.appendingPathComponent(id, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let writer = try SessionWriter(url: dir.appendingPathComponent("mix.wav"),
                                           sampleRate: engine.sampleRate, tap: engine.recordTap)
            self.writer = writer
            writer.start()
        } catch {
            self.error = "Couldn't start recording: \(error.localizedDescription)"
            return
        }
        let source = engine.recordInput >= 0
            ? "Mixer input \(engine.recordInput + 1)–\(engine.recordInput + 2)"
            : "Spindle output (both decks)"
        startedAt = Date()
        elapsed = 0
        candidate = [:]
        lastLogged = [:]
        current = SessionInfo(id: id, started: startedAt, duration: 0, source: source, entries: [])
        recording = true
        error = nil
        spindleLog.notice("Recording started: \(id), \(source)")
        save()
    }

    func stop() {
        guard recording, var session = current else { return }
        let dropped = writer?.stop() ?? 0
        writer = nil
        session.duration = Date().timeIntervalSince(startedAt)
        session.droppedFrames = dropped
        current = session
        save()
        recording = false
        current = nil
        reload()
        selected = session.id
        spindleLog.notice("Recording stopped: \(Int(session.duration)) s, \(session.entries.count) tracks, \(dropped) frames dropped")
    }

    /// Called four times a second by the deck monitor.
    func tick(model: AppModel) {
        level = model.engine?.recordTap.peak ?? 0
        guard recording, var session = current else { return }
        elapsed = Date().timeIntervalSince(startedAt)
        for deck in model.decks {
            guard let track = deck.track else { candidate[deck.id] = nil; continue }
            var c = candidate[deck.id] ?? (track.url, 0)
            if c.url != track.url { c = (track.url, 0) }
            if deck.playing { c.seconds += 0.25 }
            candidate[deck.id] = c
            if c.seconds >= 20 && lastLogged[deck.id] != track.url {
                lastLogged[deck.id] = track.url
                let a = model.analysis.analysis(for: track.url)
                session.entries.append(TracklistEntry(
                    time: max(0, elapsed - c.seconds), title: track.title, artist: track.artist,
                    deck: deck.label, bpm: model.prep.prep(for: track.url)?.bpm ?? a?.bpm,
                    key: a?.camelot, path: track.url.path))
                session.entries.sort { $0.time < $1.time }
                session.duration = elapsed
                current = session
                save()
            }
        }
    }

    private func save() {
        guard let session = current else { return }
        let url = Self.folder.appendingPathComponent(session.id).appendingPathComponent("session.json")
        if let data = try? JSONEncoder.session.encode(session) {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: Export

    enum ExportFormat: String, CaseIterable, Identifiable {
        case wav = "WAV", mp3 = "MP3 (320 kbps)", aac = "AAC (.m4a)"
        var id: String { rawValue }
        var fileExtension: String {
            switch self {
            case .wav: "wav"
            case .mp3: "mp3"
            case .aac: "m4a"
            }
        }
    }

    func export(_ session: SessionInfo, as format: ExportFormat) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Spindle \(session.id).\(format.fileExtension)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let target = panel.url else { return }
        let source = audioURL(session)
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try? FileManager.default.removeItem(at: target)
                    switch format {
                    case .wav: try FileManager.default.copyItem(at: source, to: target)
                    case .mp3: try MP3Encoder.encode(from: source, to: target)
                    case .aac: try Self.encodeAAC(from: source, to: target)
                    }
                }.value
                NSWorkspace.shared.activateFileViewerSelecting([target])
            } catch {
                self.error = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    nonisolated static func encodeAAC(from source: URL, to target: URL) throws {
        let input = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: input.processingFormat.sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 256_000,
        ]
        let output = try AVAudioFile(forWriting: target, settings: settings,
                                     commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 65_536) else { return }
        while input.framePosition < input.length {
            try input.read(into: buffer, frameCount: 65_536)
            if buffer.frameLength == 0 { break }
            try output.write(from: buffer)
        }
    }

    func saveTracklist(_ session: SessionInfo) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Spindle \(session.id) tracklist.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? session.tracklistText.write(to: url, atomically: true, encoding: .utf8)
    }

    func copyTracklist(_ session: SessionInfo) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(session.tracklistText, forType: .string)
    }

    func reveal(_ session: SessionInfo) {
        NSWorkspace.shared.activateFileViewerSelecting([audioURL(session)])
    }

    nonisolated static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.down))
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
    }
}

extension JSONEncoder {
    nonisolated static var session: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}

extension JSONDecoder {
    nonisolated static var session: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

/// Drains the record tap into a 24-bit WAV file on its own queue.
nonisolated final class SessionWriter: @unchecked Sendable {
    private let file: AVAudioFile
    private let tap: RecordTap
    private let queue = DispatchQueue(label: "spindle.session-writer", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var left: [Float] = []
    private var right: [Float] = []
    private let format: AVAudioFormat

    init(url: URL, sampleRate: Double, tap: RecordTap) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        format = file.processingFormat
        self.tap = tap
    }

    func start() {
        tap.reset()
        tap.armed.store(true, ordering: .releasing)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
        timer.setEventHandler { [weak self] in self?.flush() }
        timer.resume()
        self.timer = timer
    }

    /// Stops, writes what's left and returns the number of dropped frames.
    func stop() -> Int {
        tap.armed.store(false, ordering: .releasing)
        timer?.cancel()
        timer = nil
        queue.sync {
            flush()
            file.close()          // writes the final WAV header
        }
        return tap.dropped.load(ordering: .relaxed)
    }

    private func flush() {
        tap.drain(left: &left, right: &right)
        guard !left.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(left.count)),
              let channels = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(left.count)
        left.withUnsafeBufferPointer { channels[0].update(from: $0.baseAddress!, count: left.count) }
        right.withUnsafeBufferPointer { channels[1].update(from: $0.baseAddress!, count: right.count) }
        do { try file.write(from: buffer) } catch { spindleLog.error("Recording write failed: \(error.localizedDescription)") }
    }
}

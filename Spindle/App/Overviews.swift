//
//  Overviews.swift
//  Spindle
//
//  Tiny whole-track waveforms for the Organize list: per track, 120
//  columns of peak and loudness. Each is worked out in the background the
//  first time its row shows (newest request first, two at a time) and kept
//  in ~/Library/Application Support/Spindle/overviews.json.
//

import Foundation
import Observation

nonisolated struct TrackOverviewData: Codable, Sendable {
    /// Peak per column, 0…255.
    var peak: Data
    /// Loudness per column, 0…255 (never above the peak).
    var loud: Data
}

@Observable
final class OverviewStore {
    nonisolated static let columns = 120

    private(set) var items: [String: TrackOverviewData] = [:]
    @ObservationIgnored private var wanted: [URL] = []
    @ObservationIgnored private var asked: Set<String> = []
    @ObservationIgnored private var working = 0
    @ObservationIgnored private var saveScheduled = false

    nonisolated private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Spindle", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("overviews.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let decoded = try? JSONDecoder().decode([String: TrackOverviewData].self, from: data) {
            items = decoded
        }
    }

    func overview(for url: URL) -> TrackOverviewData? { items[url.path] }

    /// Asks for a track's overview; rows call this when they appear.
    func request(_ url: URL) {
        guard items[url.path] == nil, !asked.contains(url.path) else { return }
        asked.insert(url.path)
        wanted.append(url)
        pump()
    }

    private func pump() {
        while working < 2, let url = wanted.popLast() {
            working += 1
            Task {
                let result = await Task.detached(priority: .utility) { try? Self.compute(url) }.value
                working -= 1
                if let result {
                    items[url.path] = result
                    scheduleSave()
                }
                pump()
            }
        }
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        Task {
            try? await Task.sleep(for: .seconds(3))
            saveScheduled = false
            let snapshot = items
            await Task.detached(priority: .utility) {
                if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: Self.fileURL, options: .atomic) }
            }.value
        }
    }

    nonisolated static func compute(_ url: URL) throws -> TrackOverviewData {
        let mono = try TrackAnalyzer.decodeMono(url: url)
        guard !mono.isEmpty else { throw AnalysisError.unreadable("empty") }
        let n = columns
        var peaks = [Float](repeating: 0, count: n), louds = [Float](repeating: 0, count: n)
        for c in 0..<n {
            let a = mono.count * c / n, b = max(a + 1, mono.count * (c + 1) / n)
            var peak: Float = 0, sum: Float = 0
            for i in a..<min(b, mono.count) { let v = abs(mono[i]); peak = max(peak, v); sum += v * v }
            peaks[c] = peak
            louds[c] = min(peak, (sum / Float(b - a)).squareRoot() * 1.6)
        }
        let top = max(peaks.max() ?? 1, 0.0001)
        func bytes(_ v: [Float]) -> Data { Data(v.map { UInt8(min(255, max(0, $0 / top * 255))) }) }
        return TrackOverviewData(peak: bytes(peaks), loud: bytes(louds))
    }
}

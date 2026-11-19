//
//  AnalysisStore.swift
//  Spindle
//
//  Runs TrackAnalyzer over the library in the background (four at a time)
//  and keeps the results in ~/Library/Application Support/Spindle/analysis.json,
//  keyed by file path. A result is reused while the file's size and
//  modification date are unchanged.
//

import Foundation
import Observation

nonisolated struct StoredAnalysis: Codable, Sendable {
    var analysis: TrackAnalysis
    var fileSize: Int
    var modified: Date
    /// Bumped when the analyser changes, so old results are redone.
    var version: Int
}

@Observable
final class AnalysisStore {
    nonisolated static let version = 1

    private(set) var results: [String: TrackAnalysis] = [:]
    private(set) var pending = 0
    private(set) var failed: [String: String] = [:]
    private var stored: [String: StoredAnalysis] = [:]
    private var running = false
    private var queued: [URL] = []

    nonisolated private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Spindle", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("analysis.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let decoded = try? JSONDecoder().decode([String: StoredAnalysis].self, from: data) {
            stored = decoded.filter { $0.value.version == Self.version }
            results = stored.mapValues(\.analysis)
        }
    }

    func analysis(for url: URL) -> TrackAnalysis? { results[url.path] }

    /// Analyses every track that has no up-to-date result.
    func analyze(_ urls: [URL]) async {
        // Already busy: these get done when the current run finishes.
        guard !running else { queued += urls; return }
        running = true
        defer {
            running = false
            if !queued.isEmpty {
                let next = queued
                queued = []
                Task { await analyze(next) }
            }
        }
        let todo = urls.filter { url in
            guard let s = stored[url.path], let sig = Self.signature(url) else { return true }
            return s.fileSize != sig.size || s.modified != sig.modified
        }
        guard !todo.isEmpty else { return }
        pending = todo.count
        spindleLog.notice("Analysis: \(todo.count) tracks to analyse")
        let started = Date()

        await withTaskGroup(of: (URL, Result<TrackAnalysis, Error>).self) { group in
            var iterator = todo.makeIterator()
            func addNext() {
                guard let url = iterator.next() else { return }
                group.addTask(priority: .utility) {
                    (url, Result { try TrackAnalyzer.analyze(url: url) })
                }
            }
            for _ in 0..<4 { addNext() }
            while let (url, result) = await group.next() {
                switch result {
                case .success(let analysis):
                    results[url.path] = analysis
                    if let sig = Self.signature(url) {
                        stored[url.path] = StoredAnalysis(analysis: analysis, fileSize: sig.size, modified: sig.modified, version: Self.version)
                    }
                case .failure(let error):
                    failed[url.path] = error.localizedDescription
                    spindleLog.error("Analysis failed for \(url.lastPathComponent): \(error.localizedDescription)")
                }
                pending -= 1
                addNext()
            }
        }
        save()
        spindleLog.notice("Analysis done in \(Int(Date().timeIntervalSince(started))) s")
    }

    private func save() {
        let snapshot = stored
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: Self.fileURL, options: .atomic)
            }
        }
    }

    nonisolated private static func signature(_ url: URL) -> (size: Int, modified: Date)? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize, let modified = values.contentModificationDate else { return nil }
        return (size, modified)
    }
}

//
//  GridCheck.swift
//  Spindle
//
//  Self-test for beatgrids: does the kick stay on the grid from start to
//  end? For every 8-bar window it finds how far the kicks sit from the
//  grid lines (ms). A steady offset is a phase error, a growing one a tempo
//  error. It also checks whether a different tempo multiple (½, ⅔, 1½, 2×)
//  puts kicks on more grid lines.
//

import Foundation

nonisolated enum GridCheck {
    struct Report: Sendable {
        var offsetsMs: [Double]
        var hitRate: Double
        var better: (ratio: Double, hitRate: Double)?
    }

    /// The loop test: 4 bars at the grid's tempo against the next 4 bars.
    /// Returns, per spot in the track, how far (ms) the second 4 bars are
    /// shifted against the first: the stumble a 4-bar loop has at its wrap.
    /// Only spots with a clear pulse count.
    static func loopErrors(onset: [Float], frameRate fr: Double, bpm: Double, bars: Double = 4) -> [Double] {
        let n = onset.count
        let sorted = onset.sorted()
        let norm = max(sorted[Int(Double(n) * 0.99)], 1e-9)
        let s = onset.map { min($0 / norm, 1) }
        let length = Int((bars * 4 * 60 / bpm * fr).rounded())
        let maxLag = Int(60 / bpm / 2 * fr)
        var errors: [Double] = []
        var start = Int(10 * fr)
        while start + 2 * length + maxLag < n {
            var best = 0, bestScore: Float = -1, sum: Float = 0, count: Float = 0
            for lag in -maxLag...maxLag {
                var c: Float = 0
                for i in stride(from: 0, to: length, by: 1) { c += s[start + i] * s[start + length + i + lag] }
                sum += c; count += 1
                if c > bestScore { bestScore = c; best = lag }
            }
            // A clear peak: a real pulse, not a breakdown.
            if bestScore > 2.5 * sum / count {
                errors.append(Double(best) / fr * 1000)
            }
            start += length
        }
        return errors
    }

    /// Kick strength on the grid's beats divided by kick strength halfway
    /// between them, and the best shift (ms) of the grid within a beat.
    /// Well above 1: on the beat. Below 1: the grid sits on the off-beat.
    static func phaseProfile(onset: TrackAnalyzer.OnsetFeatures, prep: TrackPrep) -> [Double] {
        let fr = onset.frameRate
        let latency = 512.0 / TrackAnalyzer.sampleRate
        let beat = prep.beatSeconds
        let bins = 16
        var profile = [Double](repeating: 0, count: bins)
        let s = onset.low
        var k = 0.0
        while true {
            let t = prep.gridOffset + k * beat
            if (t + beat + latency) * fr >= Double(s.count) { break }
            if t >= 0 {
                for b in 0..<bins {
                    let i = Int(((t + Double(b) / Double(bins) * beat + latency) * fr).rounded())
                    if i >= 0 && i < s.count { profile[b] += Double(s[i]) }
                }
            }
            k += 1
        }
        return profile
    }

    static func phase(onset: TrackAnalyzer.OnsetFeatures, prep: TrackPrep) -> Double {
        let p = phaseProfile(onset: onset, prep: prep)
        let on = max(p[0], p[1], p[15]), off = max(p[7], p[8], p[9])
        return on / max(off, 1e-9)
    }

    /// Where in the beat (0…15 sixteenths of a beat) the kick peaks.
    static func peakBin(onset: TrackAnalyzer.OnsetFeatures, prep: TrackPrep) -> Int {
        let p = phaseProfile(onset: onset, prep: prep)
        return p.indices.max { p[$0] < p[$1] } ?? 0
    }

    static func check(url: URL, prep: TrackPrep) throws -> Report {
        let rate = TrackAnalyzer.sampleRate
        let mono = try TrackAnalyzer.decodeMono(url: url)
        let onset = TrackAnalyzer.OnsetFeatures(samples: mono, sampleRate: rate)
        let combined = zip(onset.low, onset.full).map { $0 + 0.3 * $1 }
        let e = loopErrors(onset: combined, frameRate: onset.frameRate, bpm: prep.bpm)
        // The current detector on the same audio, for comparison.
        var freshBin = -1.0, freshBPM = 0.0
        if let fresh = try? PrepAnalyzer.suggest(url: url, bpm: nil) {
            freshBin = Double(peakBin(onset: onset, prep: fresh.prep)); freshBPM = fresh.prep.bpm
        }
        return Report(offsetsMs: e, hitRate: phase(onset: onset, prep: prep), better: (Double(peakBin(onset: onset, prep: prep)), freshBin * 1000 + freshBPM / 1000))
    }

    static func run(_ items: [(URL, TrackPrep)]) async -> String {
        var lines: [String] = []
        await withTaskGroup(of: String.self) { group in
            var it = items.makeIterator()
            func add() {
                guard let (url, prep) = it.next() else { return }
                group.addTask(priority: .utility) {
                    guard let r = try? check(url: url, prep: prep) else { return "?? \(url.lastPathComponent)" }
                    let o = r.offsetsMs.sorted()
                    guard !o.isEmpty else { return "  no clear pulse  \(url.lastPathComponent)" }
                    let median = o[o.count / 2]
                    let bad = o.filter { abs($0) > 8 }.count
                    let fb = Int((r.better?.hitRate ?? 0) / 1000), fbpm = ((r.better?.hitRate ?? 0).truncatingRemainder(dividingBy: 1000)) * 1000
                    return String(format: "fresh %2d/16 %7.2f  peak %2d/16  on/off-beat kick %5.2f  %7.2f bpm  loop %+6.1f ms  %2d/%2d bad  %@",
                                  fb, fbpm, Int(r.better?.ratio ?? 0), r.hitRate, prep.bpm, median, bad, o.count, url.lastPathComponent)
                }
            }
            for _ in 0..<6 { add() }
            for await line in group { lines.append(line); add() }
        }
        return lines.sorted().joined(separator: "\n")
    }
}

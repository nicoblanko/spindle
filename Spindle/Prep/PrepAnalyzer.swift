//
//  PrepAnalyzer.swift
//  Spindle
//
//  Suggests a beatgrid, cues and loops for a track.
//
//  • Grid: the tempo from Organize is refined (±0.3 BPM) together with the
//    beat phase, by lining beats up with onsets across the whole track.
//  • Downbeat: dance music changes on bar lines, so the beat (of four) where
//    the sound changes most often is beat 1.
//  • Cues work on 8-bar phrases from the downbeat, using per-bar kick
//    strength and level:
//      1 IN    first bar with sound
//      3 BRK   first phrase where the kick drops out after playing
//      2 DROP  first phrase after that where the kick comes back
//      4 OUT   the phrase 32 bars before the end (after the drop)
//  • Loops: 16 beats at IN and at OUT, to stretch an intro or outro.
//

import Foundation

nonisolated struct PrepSuggestion: Sendable {
    var prep: TrackPrep
    /// Peak level per column at `peaksPerSecond`, 0…1, for the Prep waveform.
    var peaks: [Float]
    /// Low-band (kick) share per column, 0…1, to tint the waveform.
    var lows: [Float]
    static let peaksPerSecond = 100.0
}

nonisolated enum PrepAnalyzer {
    static func suggest(url: URL, bpm: Double?) throws -> PrepSuggestion {
        let rate = TrackAnalyzer.sampleRate
        let mono = try TrackAnalyzer.decodeMono(url: url)
        guard mono.count > Int(rate * 10) else { throw AnalysisError.unreadable("shorter than 10 s") }
        let onset = TrackAnalyzer.OnsetFeatures(samples: mono, sampleRate: rate)
        let startBPM = bpm ?? TrackAnalyzer.estimateTempo(onset.full, frameRate: onset.frameRate)
        let duration = Double(mono.count) / rate

        let (refinedBPM, phase, sure) = fitGrid(onset: onset, bpm: startBPM)
        let beat = 60 / refinedBPM
        let downbeatShift = findDownbeat(onset: onset, phase: phase, beat: beat)
        var first = phase + Double(downbeatShift) * beat
        let bar = 4 * beat
        while first - bar >= -0.02 { first -= bar }

        var prep = TrackPrep(bpm: refinedBPM, gridOffset: first)
        prep.gridUnsure = sure ? nil : true
        suggestCues(&prep, onset: onset, duration: duration)
        let (peaks, lows) = overview(mono, onset: onset, rate: rate)
        return PrepSuggestion(prep: prep, peaks: peaks, lows: lows)
    }

    // MARK: Grid

    /// Finds the tempo and phase that put the most onset strength on beats.
    static func fitGrid(onset: TrackAnalyzer.OnsetFeatures, bpm: Double) -> (bpm: Double, phase: Double, sure: Bool) {
        let fr = onset.frameRate
        // The grid sits on the kick: low band, with a little full band to
        // break ties. More full band pulls it onto off-beat hi-hats.
        let lowTop = max(onset.low.max() ?? 1, 1e-9), fullTop = max(onset.full.max() ?? 1, 1e-9)
        let strength = zip(onset.full, onset.low).map { $1 / lowTop + 0.15 * $0 / fullTop }
        let n = strength.count
        func score(_ bpm: Double, _ phase: Double) -> Float {
            let step = fr * 60 / bpm
            var s: Float = 0
            var t = phase
            while t < Double(n - 2) {
                let i = Int(t.rounded())
                s += max(strength[i], strength[max(0, i - 1)] * 0.5, strength[i + 1] * 0.5)
                t += step
            }
            return s
        }
        var best = (bpm: bpm, phase: 0.0, score: -Float.infinity)
        var candidate = bpm - 0.3
        while candidate <= bpm + 0.3 {
            let step = fr * 60 / candidate
            var p = 0.0
            while p < step {
                let s = score(candidate, p)
                if s > best.score { best = (candidate, p, s) }
                p += 1
            }
            candidate += 0.02
        }
        // Keep whole-BPM tempos whole (most electronic music is).
        var finalBPM = best.bpm
        let rounded = finalBPM.rounded()
        if abs(finalBPM - rounded) < 0.06 { finalBPM = rounded }
        // Phase: where the kick sits in the beat. Fold the low band (kick)
        // over every beat of the track at the final tempo and take the peak.
        // Full band is left out: hi-hats and percussion between the kicks
        // pulled the grid off the beat on about one track in five.
        let (phase, sure) = kickPhase(onset: onset, bpm: finalBPM)
        return (finalBPM, phase, sure)
    }

    /// Time (s) of the first kick-aligned grid line, within one beat.
    /// `sure` is false when the low band hits as hard between the beats
    /// (an off-beat bassline) as on them: then it may have picked the wrong one.
    static func kickPhase(onset: TrackAnalyzer.OnsetFeatures, bpm: Double) -> (Double, Bool) {
        let fr = onset.frameRate
        let beatFrames = fr * 60 / bpm
        let bins = 96
        var profile = [Double](repeating: 0, count: bins)
        // Low band only: mixing in the full band (even as a tie-breaker)
        // let hi-hats just before the kick drag clear grids off it.
        let low = onset.low
        // Per frame, which part of the beat it falls in (linear split between two bins).
        for (i, v) in low.enumerated() where v > 0 {
            let pos = Double(i).truncatingRemainder(dividingBy: beatFrames) / beatFrames * Double(bins)
            let b0 = Int(pos) % bins, b1 = (b0 + 1) % bins
            let f = pos - Double(Int(pos))
            profile[b0] += Double(v) * (1 - f)
            profile[b1] += Double(v) * f
        }
        // Light smoothing, circular.
        var smooth = profile
        for b in 0..<bins {
            smooth[b] = 0.25 * profile[(b + bins - 1) % bins] + 0.5 * profile[b] + 0.25 * profile[(b + 1) % bins]
        }
        let peak = smooth.indices.max { smooth[$0] < smooth[$1] } ?? 0
        // Parabolic refinement around the peak.
        let y0 = smooth[(peak + bins - 1) % bins], y1 = smooth[peak], y2 = smooth[(peak + 1) % bins]
        let denom = y0 - 2 * y1 + y2
        let shift = abs(denom) > 1e-12 ? 0.5 * (y0 - y2) / denom : 0
        let phaseFrames = (Double(peak) + shift) / Double(bins) * beatFrames
        // Onset frames sit a little after the attack (half an FFT window).
        let latency = 512.0 / TrackAnalyzer.sampleRate
        var t = phaseFrames / fr - latency
        let beat = 60 / bpm
        while t < 0 { t += beat }
        let opposite = smooth[(peak + bins / 2) % bins]
        return (t, y1 > 1.25 * opposite)
    }

    /// Which of four beats starts the bar: the one where the sound changes most.
    static func findDownbeat(onset: TrackAnalyzer.OnsetFeatures, phase: Double, beat: Double) -> Int {
        let fr = onset.frameRate
        var level: [Double] = []
        var kick: [Double] = []
        var t = phase
        while Int((t + beat) * fr) < onset.rms.count {
            let a = Int(t * fr), b = Int((t + beat) * fr)
            level.append(Double(onset.rms[a..<b].reduce(0, +)) / Double(max(b - a, 1)))
            kick.append(Double(onset.low[a..<b].reduce(0, +)) / Double(max(b - a, 1)))
            t += beat
        }
        guard level.count > 32 else { return 0 }
        let levelScale = max(level.max() ?? 1, 1e-6), kickScale = max(kick.max() ?? 1, 1e-6)
        var votes = [Double](repeating: 0, count: 4)
        for i in 8..<(level.count - 8) {
            func mean(_ x: [Double], _ r: Range<Int>) -> Double { x[r].reduce(0, +) / Double(r.count) }
            let change = abs(mean(level, i..<(i + 8)) - mean(level, (i - 8)..<i)) / levelScale
                + abs(mean(kick, i..<(i + 8)) - mean(kick, (i - 8)..<i)) / kickScale
            votes[i % 4] += change * change
        }
        return votes.indices.max { votes[$0] < votes[$1] } ?? 0
    }

    // MARK: Cues

    static func suggestCues(_ prep: inout TrackPrep, onset: TrackAnalyzer.OnsetFeatures, duration: Double) {
        let fr = onset.frameRate
        let beat = prep.beatSeconds
        let bar = 4 * beat
        let latency = 512.0 / TrackAnalyzer.sampleRate
        // Per bar: level (RMS) and kick pulse (low-band attack on the beat
        // minus between beats). A breakdown loses one or both.
        var kick: [Double] = []
        var level: [Double] = []
        var t = prep.gridOffset
        func low(_ time: Double) -> Double {
            let i = Int(((time + latency) * fr).rounded())
            guard i >= 1, i + 1 < onset.low.count else { return 0 }
            return Double(max(onset.low[i - 1], onset.low[i], onset.low[i + 1]))
        }
        while t + bar <= duration {
            // The grid can start a hair before 0:00 (a kick right at the start).
            let a = max(0, Int(t * fr)), b = min(onset.rms.count, Int((t + bar) * fr))
            guard b > a else { break }
            var pulse = 0.0
            for k in 0..<4 {
                let beatTime = t + Double(k) * beat
                pulse += low(beatTime) - low(beatTime + beat / 2)
            }
            kick.append(max(0, pulse / 4))
            level.append(Double(onset.rms[a..<b].reduce(0, +)) / Double(b - a))
            t += bar
        }
        guard kick.count >= 16 else {
            prep.setCue(.intro, time: prep.gridOffset, auto: true)
            return
        }
        // Normalise: kick against the busy bars, level against the loud ones.
        let kickRef = max(kick.sorted()[kick.count * 3 / 4], 1e-9)
        let levelRef = max(level.sorted()[level.count * 3 / 4], 1e-9)
        kick = kick.map { $0 / kickRef }
        level = level.map { $0 / levelRef }
        func barTime(_ i: Int) -> Double { prep.gridOffset + Double(i) * bar }
        func mean(_ x: [Double], _ from: Int, _ count: Int) -> Double {
            let lo = max(0, from), hi = min(x.count, from + count)
            return hi > lo ? x[lo..<hi].reduce(0, +) / Double(hi - lo) : 0
        }
        let bars = kick.count
        let phrases = stride(from: 8, to: bars - 4, by: 8).map { $0 }

        // IN: first bar with sound.
        let inBar = level.firstIndex { $0 > 0.08 } ?? 0
        prep.setCue(.intro, time: barTime(inBar), auto: true)

        // How "full" each bar is. Level is the reliable part; a missing kick
        // takes up to 40% off (the pulse measure is noisy on its own).
        let full = zip(kick, level).map { $1 * (0.6 + 0.4 * min($0, 1)) }

        // BRK: the track empties out after at least 16 bars.
        let earliest = max(16, bars / 8)
        let brk = phrases.first { p in
            p >= earliest && p < bars * 85 / 100
                && mean(full, p - 8, 8) > 0.7 && mean(full, p, 8) < 0.5
        }
        if let brk { prep.setCue(.breakdown, time: barTime(brk), auto: true) }

        // DROP: the first phrase after the breakdown where it is full again
        // (or, without a breakdown, the biggest lift).
        var drop = phrases.first { p in
            p > (brk ?? Int.max) && mean(full, p - 4, 4) < 0.6 && mean(full, p, 8) > 0.75
        }
        if drop == nil {
            drop = phrases.filter { $0 >= earliest && $0 < bars * 3 / 4 }.max { a, b in
                (mean(full, a, 8) - mean(full, a - 8, 8)) < (mean(full, b, 8) - mean(full, b - 8, 8))
            }
        }
        if let drop { prep.setCue(.drop, time: barTime(drop), auto: true) }

        // OUT: 32 bars before the end, on a phrase, after the drop.
        let target = bars - 32
        let after = drop ?? inBar
        if let out = phrases.filter({ $0 > after }).min(by: { abs($0 - target) < abs($1 - target) }) {
            prep.setCue(.outro, time: barTime(out), auto: true)
        }

        prep.loops = [CueRole.intro, .outro].compactMap { role in
            prep.cue(role).map { SavedLoop(start: $0.time, beats: 16) }
        }
    }

    // MARK: Waveform

    static func overview(_ mono: [Float], onset: TrackAnalyzer.OnsetFeatures, rate: Double) -> ([Float], [Float]) {
        let block = Int(rate / PrepSuggestion.peaksPerSecond)
        let columns = mono.count / block
        var peaks = [Float](repeating: 0, count: columns)
        var top: Float = 1e-6
        for c in 0..<columns {
            var p: Float = 0
            for i in (c * block)..<((c + 1) * block) { p = max(p, abs(mono[i])) }
            peaks[c] = p
            top = max(top, p)
        }
        peaks = peaks.map { $0 / top }
        // Kick share: low-band onset relative to full-band, smoothed.
        var lows = [Float](repeating: 0, count: columns)
        let perColumn = onset.frameRate / PrepSuggestion.peaksPerSecond
        let lowTop = max(onset.low.max() ?? 1, 1e-6)
        for c in 0..<columns {
            let f = min(onset.low.count - 1, Int(Double(c) * perColumn))
            if f >= 0 { lows[c] = min(1, onset.low[f] / lowTop * 3) }
        }
        return (peaks, lows)
    }
}

//
//  JitterProbe.swift
//  Spindle
//
//  Self-test for smooth waveforms (SPINDLE_JITTER): records, for every frame
//  a deck lane draws, the frame time and the playhead it used, then reports
//  how evenly the waveform moved.
//

import Foundation

enum JitterProbe {
    static var on = false
    private static var samples: [(frame: Double, wall: Double, playhead: Double)] = []
    private static var draws: [(wall: Double, playhead: Double, pps: Double, scale: Double)] = []

    /// Called from inside the Canvas: when it really draws.
    static func drew(playhead: Double, pointsPerSecond: Double, scale: Double) {
        guard on else { return }
        draws.append((DeckTelemetry.now, playhead, pointsPerSecond, scale))
    }

    static func drawReport() -> String {
        let d = draws
        guard d.count > 10 else { return "Draws: only \(d.count)" }
        var gaps: [Double] = [], pxSteps: [Int: Int] = [:]
        var lastSnap = 0.0
        for i in 1..<d.count {
            gaps.append((d[i].wall - d[i - 1].wall) * 1000)
            // The renderer snaps the waveform to whole device pixels: how many
            // pixels it jumped this frame.
            let px = d[i].playhead * d[i].pps * d[i].scale
            if i > 1 {
                // Movement per 16.7 ms of real time, in pixels (tenths).
                let gap = d[i].wall - d[i - 1].wall
                if gap > 0.008 { pxSteps[Int(((px - lastSnap) / gap * (1.0 / 60) * 10).rounded()), default: 0] += 1 }
            }
            lastSnap = px
        }
        let sorted = gaps.sorted()
        let over = gaps.filter { $0 > 20 }.count
        let total = Double(pxSteps.values.reduce(0, +))
        let mean = pxSteps.reduce(0.0) { $0 + Double($1.key) * Double($1.value) } / max(total, 1)
        let sd = (pxSteps.reduce(0.0) { $0 + pow(Double($1.key) - mean, 2) * Double($1.value) } / max(total, 1)).squareRoot()
        let steps = String(format: "speed per frame %.2f px ±%.2f px", mean / 10, sd / 10)
        return String(format: "Draws: %d in %.1f s · gap median %.1f ms, p95 %.1f, max %.1f · %d gaps over 20 ms · pixel steps %@",
                      d.count, d.last!.wall - d.first!.wall, sorted[sorted.count / 2], sorted[Int(Double(sorted.count) * 0.95)], sorted.last!, over, steps)
    }

    static func record(frame: Date, playhead: Double) {
        guard on else { return }
        samples.append((frame.timeIntervalSinceReferenceDate, Date().timeIntervalSinceReferenceDate, playhead))
    }

    static func reset() { samples = []; draws = [] }

    /// `pointsPerSecond`: how far the waveform moves for a second of track.
    static func report(pointsPerSecond: Double, rate: Double) -> String {
        let s = samples
        guard s.count > 10 else { return "Jitter: only \(s.count) frames" }
        var intervals: [Double] = [], errors: [Double] = []
        for i in 1..<s.count {
            let dt = s[i].frame - s[i - 1].frame
            let moved = s[i].playhead - s[i - 1].playhead
            intervals.append(dt)
            // How far the picture moved versus how far it should have (points).
            errors.append((moved - dt * rate) * pointsPerSecond)
        }
        func stats(_ v: [Double]) -> (mean: Double, sd: Double, max: Double) {
            let m = v.reduce(0, +) / Double(v.count)
            let sd = (v.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(v.count)).squareRoot()
            return (m, sd, v.map { abs($0) }.max() ?? 0)
        }
        let iv = stats(intervals), er = stats(errors)
        let still = zip(intervals, s.dropFirst()).filter { $0.0 > 0 }.count - errors.filter { abs($0) < 1e-9 }.count
        return String(format: "Jitter: %d frames, interval %.2f ms ±%.2f (max %.1f) · step error ±%.2f pt (max %.2f pt) · frames with no movement %d",
                      s.count, iv.mean * 1000, iv.sd * 1000, iv.max * 1000, er.sd, er.max, s.count - 1 - still)
    }
}

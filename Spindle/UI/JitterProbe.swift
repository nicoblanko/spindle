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

    static func record(frame: Date, playhead: Double) {
        guard on else { return }
        samples.append((frame.timeIntervalSinceReferenceDate, Date().timeIntervalSinceReferenceDate, playhead))
    }

    static func reset() { samples = [] }

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

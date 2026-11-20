//
//  WaveformRenderer.swift
//  Spindle
//
//  Draws a track's waveform for every waveform in the app (Prep overview
//  and lane, Mix overview and lanes): one solid colour, the deck's colour
//  on Mix and white on Prep, with the part already played dimmer.
//
//  Columns are one screen pixel wide and fixed to the track's timeline, so
//  the shape stays put as it scrolls.
//

import SwiftUI

enum WaveformRenderer {
    /// Draws seconds `start` … `start + span` of `track` into `rect`.
    /// Everything before `playhead` is drawn dimmer.
    static func draw(_ context: GraphicsContext, track: LoadedTrack, start: Double, span: Double,
                     rect: CGRect, playhead: Double, color: Color = Theme.ink, dimPlayed: Bool = true) {
        let peaks = track.peaks
        guard !peaks.isEmpty, span > 0, rect.width > 1 else { return }
        let scale = max(context.environment.displayScale, 1)
        let rate = LoadedTrack.peaksPerSecond
        let secondsPerPixel = span / Double(rect.width * scale)
        // Columns about 3 device pixels wide (wider when zoomed past the
        // data), fixed to the track's timeline.
        let bins = max(1, Int((3 * secondsPerPixel * rate).rounded()))
        let columnSeconds = Double(bins) / rate
        let first = max(0, Int((start / columnSeconds).rounded(.down)) - 2)
        let last = Int(((start + span) / columnSeconds).rounded(.up)) + 2
        let mid = rect.midY
        let half = rect.height / 2
        func x(_ t: Double) -> CGFloat { rect.minX + CGFloat((t - start) / span) * rect.width }

        // The loudness per column, then lightly smoothed so the outline has
        // no one-pixel spikes: thin spikes shimmer as the shape glides by
        // fractions of a pixel, which reads as jitter.
        var levels: [Float] = []
        levels.reserveCapacity(max(0, last - first + 1))
        for column in first...max(first, last) {
            let b0 = column * bins
            if b0 >= peaks.count { break }
            let b1 = min(peaks.count, b0 + bins)
            var peak: Float = 0
            for b in b0..<b1 { peak = max(peak, peaks[b]) }
            levels.append(peak)
        }
        guard !levels.isEmpty else { return }
        var smooth = levels
        for i in levels.indices {
            let a = levels[max(0, i - 1)], c = levels[min(levels.count - 1, i + 1)]
            smooth[i] = max(levels[i] * 0.6 + (a + c) * 0.2, 0)
        }

        // One outline through the column centres, top then bottom, split
        // where the playhead is so the played part can be dimmer.
        let points: [(x: CGFloat, h: CGFloat, t: Double)] = smooth.indices.map { i in
            let t = (Double(first + i) + 0.5) * columnSeconds
            return (x(t), max(0.5 / scale, CGFloat(smooth[i]) * half), t)
        }
        func fill(_ part: ArraySlice<(x: CGFloat, h: CGFloat, t: Double)>, _ c: Color) {
            guard part.count > 1 else { return }
            var path = Path()
            path.move(to: CGPoint(x: part.first!.x, y: mid))
            for p in part { path.addLine(to: CGPoint(x: p.x, y: mid - p.h)) }
            path.addLine(to: CGPoint(x: part.last!.x, y: mid))
            for p in part.reversed() { path.addLine(to: CGPoint(x: p.x, y: mid + p.h)) }
            path.closeSubpath()
            context.fill(path, with: .color(c))
        }
        let split = dimPlayed ? (points.firstIndex { $0.t >= playhead } ?? points.count) : 0
        // Share the point at the split so the two parts meet without a gap.
        fill(points[0..<min(points.count, split + 1)], color.opacity(0.4))
        fill(points[split..<points.count], color)
    }
}

/// Turns the audio engine's position reports, which arrive in uneven bursts,
/// into an even motion for the screen: each frame moves on by exactly the
/// frame time × the playing speed, and drifts gently towards the engine's
/// position. A real jump (seek, cue, loop wrap) is followed at once.
final class SmoothClock {
    private var lastFrame = 0.0
    private var value = 0.0
    private var running = false

    func position(frame: Date, measured: Double, rate: Double) -> Double {
        let t = frame.timeIntervalSinceReferenceDate
        if running, t == lastFrame { return value }               // same frame again
        guard running, t > lastFrame, t - lastFrame < 0.25 else {
            running = true; lastFrame = t; value = measured
            return measured
        }
        let predicted = value + rate * (t - lastFrame)
        lastFrame = t
        let error = measured - predicted
        if abs(error) > 0.08 {
            value = measured                                      // a jump
        } else {
            // Slow pull for the burst noise (a few ms); faster when scrubbing.
            value = predicted + error * (abs(error) > 0.015 ? 0.3 : 0.06)
        }
        return value
    }
}

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
    /// Colour strength for a section level (0 = emptiest, 1 = fullest), in
    /// six steps: same colour, breaks and intros further back.
    private static func strength(_ bucket: Int) -> Double { 0.3 + 0.7 * Double(bucket) / 5 }
    private static func bucket(_ section: Float) -> Int { Int((min(max(section, 0), 1) * 5).rounded()) }

    /// Draws seconds `start` … `start + span` of `track` into `rect`.
    /// Everything before `playhead` is drawn dimmer, and the colour's
    /// strength follows how full each section is.
    ///
    /// `detailed` (the whole-track overviews, which don't scroll): a body of
    /// loudness with the peaks as fine spikes on top, one pixel per column.
    /// Otherwise (scrolling lanes): a smoothed outline, which glides without
    /// shimmering.
    static func draw(_ context: GraphicsContext, track: LoadedTrack, start: Double, span: Double,
                     rect: CGRect, playhead: Double, color: Color = Theme.ink, dimPlayed: Bool = true,
                     detailed: Bool = false) {
        let peaks = track.peaks
        guard !peaks.isEmpty, span > 0, rect.width > 1 else { return }
        let scale = max(context.environment.displayScale, 1)
        let rate = LoadedTrack.peaksPerSecond
        let secondsPerPixel = span / Double(rect.width * scale)
        let hasSections = track.sections.count == peaks.count
        let mid = rect.midY
        let half = rect.height / 2
        func x(_ t: Double) -> CGFloat { rect.minX + CGFloat((t - start) / span) * rect.width }

        if detailed {
            drawDetailed(context, track: track, start: start, span: span, rect: rect, playhead: playhead,
                         color: color, dimPlayed: dimPlayed, scale: scale, secondsPerPixel: secondsPerPixel)
            return
        }

        // Columns about 2 device pixels wide (wider when zoomed past the
        // data), fixed to the track's timeline.
        let bins = max(1, Int((2 * secondsPerPixel * rate).rounded()))
        let columnSeconds = Double(bins) / rate
        let first = max(0, Int((start / columnSeconds).rounded(.down)) - 2)
        let last = Int(((start + span) / columnSeconds).rounded(.up)) + 2

        // Peak and loudness per column, lightly smoothed: drawn as outlines
        // (not one-pixel bars) so the detail glides without shimmering.
        var peakOf: [Float] = [], loudOf: [Float] = [], sectionOf: [Int] = []
        let rms = track.rms
        for column in first...max(first, last) {
            let b0 = column * bins
            if b0 >= peaks.count { break }
            let b1 = min(peaks.count, b0 + bins)
            var peak: Float = 0, loud: Float = 0
            for b in b0..<b1 { peak = max(peak, peaks[b]); loud = max(loud, rms[b]) }
            peakOf.append(peak); loudOf.append(min(peak, loud * 0.85))
            sectionOf.append(hasSections ? bucket(track.sections[b0]) : 5)
        }
        guard !peakOf.isEmpty else { return }
        func smoothed(_ v: [Float], _ k: Float) -> [Float] {
            v.indices.map { i in v[i] * (1 - 2 * k) + (v[max(0, i - 1)] + v[min(v.count - 1, i + 1)]) * k }
        }
        let peakS = smoothed(peakOf, 0.12), loudS = smoothed(loudOf, 0.2)

        let xs: [CGFloat] = peakS.indices.map { x((Double(first + $0) + 0.5) * columnSeconds) }
        let ts: [Double] = peakS.indices.map { (Double(first + $0) + 0.5) * columnSeconds }
        func fill(_ range: Range<Int>, _ h: [Float], _ c: Color) {
            guard range.count > 1 else { return }
            var path = Path()
            path.move(to: CGPoint(x: xs[range.lowerBound], y: mid))
            for i in range { path.addLine(to: CGPoint(x: xs[i], y: mid - max(0.5 / scale, CGFloat(h[i]) * half))) }
            path.addLine(to: CGPoint(x: xs[range.upperBound - 1], y: mid))
            for i in range.reversed() { path.addLine(to: CGPoint(x: xs[i], y: mid + max(0.5 / scale, CGFloat(h[i]) * half))) }
            path.closeSubpath()
            context.fill(path, with: .color(c))
        }
        // In runs of the same strength (and played / ahead); neighbouring runs
        // share their edge point so the shape stays whole. Peaks first, the
        // loudness body on top.
        func key(_ i: Int) -> Int { sectionOf[i] * 2 + (dimPlayed && ts[i] < playhead ? 1 : 0) }
        for (layer, heights, factor) in [(0, peakS, 0.45), (1, loudS, 1.0)] {
            _ = layer
            var runStart = 0
            for i in 1...xs.count {
                if i == xs.count || key(i) != key(runStart) {
                    let k = key(runStart)
                    let o = strength(k / 2) * (k % 2 == 1 ? 0.4 : 1) * factor
                    fill(runStart..<min(xs.count, i + 1), heights, color.opacity(o))
                    runStart = i
                }
            }
        }
    }

    /// The overview: per pixel column, loudness as the body and the peak as a
    /// fine spike above it, both in the section's strength.
    private static func drawDetailed(_ context: GraphicsContext, track: LoadedTrack, start: Double, span: Double,
                                     rect: CGRect, playhead: Double, color: Color, dimPlayed: Bool,
                                     scale: CGFloat, secondsPerPixel: Double) {
        let peaks = track.peaks, rms = track.rms
        let rate = LoadedTrack.peaksPerSecond
        let hasSections = track.sections.count == peaks.count
        let pixels = Int(rect.width * scale)
        let mid = rect.midY, half = rect.height / 2
        // Bodies by strength step (and played), spikes likewise.
        var body = [Path](repeating: Path(), count: 12), spike = [Path](repeating: Path(), count: 12)
        for px in 0..<pixels {
            let t0 = start + Double(px) * secondsPerPixel, t1 = t0 + secondsPerPixel
            let b0 = max(0, Int(t0 * rate)), b1 = min(peaks.count, max(b0 + 1, Int(t1 * rate)))
            guard b0 < peaks.count else { break }
            var peak: Float = 0, loud: Float = 0
            for b in b0..<b1 { peak = max(peak, peaks[b]); loud = max(loud, rms[b]) }
            let k = (hasSections ? bucket(track.sections[b0]) : 5) * 2 + (dimPlayed && t1 <= playhead ? 1 : 0)
            let x = rect.minX + CGFloat(px) / scale, w = 1 / scale
            let hp = max(0.5 / scale, CGFloat(peak) * half)
            let hb = min(hp, max(0.5 / scale, CGFloat(loud) * 0.85 * half))
            body[k].addRect(CGRect(x: x, y: mid - hb, width: w, height: hb * 2))
            spike[k].addRect(CGRect(x: x, y: mid - hp, width: w, height: hp * 2))
        }
        for k in 0..<12 {
            let o = strength(k / 2) * (k % 2 == 1 ? 0.4 : 1)
            context.fill(spike[k], with: .color(color.opacity(o * 0.45)))
            context.fill(body[k], with: .color(color.opacity(o)))
        }
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

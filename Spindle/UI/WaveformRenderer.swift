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
        // One device pixel per column, or wider when zoomed past the data.
        let bins = max(1, Int((secondsPerPixel * rate).rounded()))
        let columnSeconds = Double(bins) / rate
        let first = max(0, Int((start / columnSeconds).rounded(.down)))
        let last = Int(((start + span) / columnSeconds).rounded(.up))
        let mid = rect.midY
        let half = rect.height / 2

        func pixel(_ t: Double) -> CGFloat {
            ((rect.minX + CGFloat((t - start) / span) * rect.width) * scale).rounded()
        }

        var played = Path(), ahead = Path()
        var column = first
        while column <= last {
            let b0 = column * bins
            if b0 >= peaks.count { break }
            let b1 = min(peaks.count, b0 + bins)
            let t = Double(column) * columnSeconds
            let px = pixel(t), pxEnd = max(pixel(t + columnSeconds), px + 1)
            var peak: Float = 0
            for b in b0..<b1 { peak = max(peak, peaks[b]) }
            let h = max(0.5 / scale, CGFloat(peak) * half)
            let r = CGRect(x: px / scale, y: mid - h, width: (pxEnd - px) / scale, height: h * 2)
            if dimPlayed && t + columnSeconds <= playhead { played.addRect(r) } else { ahead.addRect(r) }
            column += 1
        }
        context.fill(played, with: .color(color.opacity(0.4)))
        context.fill(ahead, with: .color(color))
    }
}

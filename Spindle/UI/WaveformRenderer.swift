//
//  WaveformRenderer.swift
//  Spindle
//
//  Draws a track's waveform for every waveform in the app (Prep overview
//  and lane, Mix overview and lanes), in the style chosen in the look menu:
//
//    3-Band  bass, mids and highs as three layers on top of each other
//            (colours from the chosen palette), so a kick, a bassline and
//            hi-hats each read at a glance
//    RGB     one shape, coloured by what it sounds like: red where the bass
//            dominates, green for mids, blue for highs
//    Mono    one solid colour: the deck's colour (Prep: the text colour)
//
//  Columns are one screen pixel wide and fixed to the track's timeline, so
//  the shape stays put as it scrolls.
//

import SwiftUI

enum WaveformRenderer {
    static var lowColor: Color { Color(hex: LookSettings.shared.bandPalette.hex.low, exact: true) }
    static var midColor: Color { Color(hex: LookSettings.shared.bandPalette.hex.mid, exact: true) }
    static var highColor: Color { Color(hex: LookSettings.shared.bandPalette.hex.high, exact: true) }

    /// Draws seconds `start` … `start + span` of `track` into `rect`.
    /// Everything before `playhead` is drawn dimmer.
    static func draw(_ context: GraphicsContext, track: LoadedTrack, start: Double, span: Double,
                     rect: CGRect, playhead: Double, style: WaveStyle, monoColor: Color = Theme.ink,
                     dimPlayed: Bool = true) {
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
        let hasBands = track.low.count == peaks.count
        let style = hasBands ? style : .mono

        func pixel(_ t: Double) -> CGFloat {
            ((rect.minX + CGFloat((t - start) / span) * rect.width) * scale).rounded()
        }

        // Paths per colour (and played / ahead), filled at the end.
        var lowP = [Path(), Path()], midP = [Path(), Path()], highP = [Path(), Path()]
        var outerP = [Path(), Path()], innerP = [Path(), Path()]
        var rgb: [Int: Path] = [:], rgbPlayed: [Int: Path] = [:]

        var column = first
        while column <= last {
            let b0 = column * bins
            if b0 >= peaks.count { break }
            let b1 = min(peaks.count, b0 + bins)
            let t = Double(column) * columnSeconds
            let px = pixel(t), pxEnd = max(pixel(t + columnSeconds), px + 1)
            let x = px / scale, w = (pxEnd - px) / scale
            let played = dimPlayed && t + columnSeconds <= playhead ? 1 : 0
            func bar(_ v: Float, _ k: CGFloat = 1) -> CGRect {
                let h = max(0.5 / scale, CGFloat(v) * half * k)
                return CGRect(x: x, y: mid - h, width: w, height: h * 2)
            }
            var peak: Float = 0, loud: Float = 0, l: Float = 0, m: Float = 0, h: Float = 0
            for b in b0..<b1 {
                peak = max(peak, peaks[b]); loud = max(loud, track.rms[b])
                if hasBands { l = max(l, track.low[b]); m = max(m, track.mid[b]); h = max(h, track.high[b]) }
            }
            switch style {
            case .threeBand:
                // Bass makes the outer shape, mids sit inside, highs at the core.
                lowP[played].addRect(bar(l))
                midP[played].addRect(bar(m, 0.6))
                highP[played].addRect(bar(h, 0.36))
            case .rgb:
                // Colour from the mix of bands, brightest band at full.
                let top = max(l, m, h, 0.001)
                let key = Int((l / top * 5).rounded()) * 36 + Int((m / top * 5).rounded()) * 6 + Int((h / top * 5).rounded())
                let r = bar(peak)
                if played == 1 { rgbPlayed[key, default: Path()].addRect(r) } else { rgb[key, default: Path()].addRect(r) }
            default:
                outerP[played].addRect(bar(peak))
                innerP[played].addRect(bar(min(loud, peak)))
            }
            column += 1
        }

        let dim = 0.38
        switch style {
        case .threeBand:
            for p in [1, 0] {
                let o = p == 1 ? dim : 1
                context.fill(lowP[p], with: .color(lowColor.opacity(o)))
                context.fill(midP[p], with: .color(midColor.opacity(o)))
                context.fill(highP[p], with: .color(highColor.opacity(o * 0.95)))
            }
        case .rgb:
            func color(_ key: Int) -> Color {
                let r = Double(key / 36) / 5, g = Double(key / 6 % 6) / 5, b = Double(key % 6) / 5
                // Serato-like: bass red, mids green, highs blue, never too dark.
                let red = 0.15 + 0.85 * r, green = 0.12 + 0.8 * g, blue = 0.2 + 0.8 * b
                // Toned towards grey like everything else (Dusk halfway, Ink fully);
                // in grey, bass reads darker and highs lighter.
                let k = LookFlags.saturation
                let y = 0.25 + 0.2 * r + 0.3 * g + 0.45 * b
                return Color(.sRGB, red: y + (red - y) * k, green: y + (green - y) * k, blue: y + (blue - y) * k)
            }
            for (key, path) in rgbPlayed { context.fill(path, with: .color(color(key).opacity(dim))) }
            for (key, path) in rgb { context.fill(path, with: .color(color(key))) }
        default:
            // One solid colour: the peaks only, nothing layered inside.
            context.fill(outerP[1], with: .color(monoColor.opacity(0.4)))
            context.fill(outerP[0], with: .color(monoColor))
        }
    }
}

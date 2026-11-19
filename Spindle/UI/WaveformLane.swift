//
//  WaveformLane.swift
//  Spindle
//
//  A scrolling waveform with the playhead fixed in the centre. Drawn with
//  Canvas for the prototype; Metal comes later.
//

import SwiftUI

struct WaveformLane: View {
    let deck: DeckModel
    let telemetry: UnsafeMutablePointer<DeckTelemetry>?
    /// Beatgrid and cues from Prep, if the track has been prepped.
    var prep: TrackPrep? = nil
    /// Seconds visible across the lane.
    var window: Double = 6

    var body: some View {
        TimelineView(.animation) { _ in
            let playhead = telemetry?.pointee.playhead ?? 0
            Canvas { context, size in
                draw(context: context, size: size, playhead: playhead)
            }
        }
        .background(Theme.panel)
        .overlay {
            if deck.track == nil {
                Text(deck.loading ? "Loading…" : "Drop a track here or use Load…")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.inkFaint)
            } else {
                // In absolute mode the needle can sit outside the track: say so
                // instead of looking broken.
                TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                    if let track = deck.track, let t = telemetry?.pointee {
                        if t.playhead > track.duration {
                            notice("Needle is past the end of this track (\(DeckPanel.clock(t.playhead))). Move it towards the start of the record.")
                        } else if t.playhead < 0 {
                            notice("Needle is before the start of this track.")
                        }
                    }
                }
            }
        }
    }

    private func notice(_ text: String) -> some View {
        Text(text)
            .font(Theme.caption)
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, Theme.space2)
            .padding(.vertical, Theme.space1)
            .background(Theme.panelRaised)
            .overlay(Rectangle().stroke(Theme.warn, lineWidth: 1))
    }

    private func draw(context: GraphicsContext, size: CGSize, playhead: Double) {
        let mid = size.height / 2
        let centreX = size.width / 2
        let secondsPerPoint = window / Double(size.width)

        // Beatgrid from Prep: bar lines, with 8-bar phrases stronger.
        if let prep {
            var n = ((playhead - window / 2 - prep.gridOffset) / prep.beatSeconds).rounded(.down)
            var grid = Path(), bars = Path()
            while prep.gridOffset + n * prep.beatSeconds <= playhead + window / 2 {
                let t = prep.gridOffset + n * prep.beatSeconds
                let x = centreX + CGFloat((t - playhead) / secondsPerPoint)
                if Int(n) % 4 == 0 { bars.addRect(CGRect(x: x, y: 0, width: Int(n) % 32 == 0 ? 2 : 1, height: size.height)) }
                else { grid.addRect(CGRect(x: x, y: size.height - 10, width: 1, height: 10)) }
                n += 1
            }
            context.fill(grid, with: .color(Theme.line))
            context.fill(bars, with: .color(Theme.line.opacity(0.9)))
        }
        // Second ticks so movement is readable before a grid exists.
        var ticks = Path()
        let firstSecond = (playhead - window / 2).rounded(.down)
        var s = firstSecond
        while s <= playhead + window / 2 {
            let x = centreX + CGFloat((s - playhead) / secondsPerPoint)
            ticks.addRect(CGRect(x: x, y: size.height - 6, width: 1, height: 6))
            s += 1
        }
        context.fill(ticks, with: .color(Theme.line))

        if let track = deck.track, !track.peaks.isEmpty {
            // Columns are fixed to the track's timeline (not to the screen),
            // so each one keeps its shape and glides past the playhead.
            let peaks = track.peaks, rms = track.rms
            let rate = LoadedTrack.peaksPerSecond
            let targetPoints: CGFloat = 2
            let binsPerColumn = max(1, Int((Double(targetPoints) * secondsPerPoint * rate).rounded()))
            let columnSeconds = Double(binsPerColumn) / rate
            let columnWidth = CGFloat(columnSeconds / secondsPerPoint)
            let firstColumn = Int(((playhead - window / 2) / columnSeconds).rounded(.down)) - 1
            let lastColumn = Int(((playhead + window / 2) / columnSeconds).rounded(.up)) + 1
            var outerPlayed = Path(), outerAhead = Path(), innerPlayed = Path(), innerAhead = Path()
            let height = mid - 4
            for column in firstColumn...lastColumn {
                let b0 = column * binsPerColumn
                guard b0 >= 0, b0 < peaks.count else { continue }
                let b1 = min(peaks.count, b0 + binsPerColumn)
                var peak: Float = 0, loud: Float = 0
                for b in b0..<b1 {
                    peak = max(peak, peaks[b])
                    loud = max(loud, rms[b])
                }
                let x = centreX + CGFloat((Double(column) * columnSeconds - playhead) / secondsPerPoint)
                let w = max(columnWidth - 0.6, 0.8)
                let hp = max(1, CGFloat(peak) * height)
                let hr = max(0.5, CGFloat(min(loud, peak)) * height)
                let outer = CGRect(x: x, y: mid - hp, width: w, height: hp * 2)
                let inner = CGRect(x: x, y: mid - hr, width: w, height: hr * 2)
                if x + w <= centreX {
                    outerPlayed.addRect(outer); innerPlayed.addRect(inner)
                } else {
                    outerAhead.addRect(outer); innerAhead.addRect(inner)
                }
            }
            context.fill(outerPlayed, with: .color(deck.color.opacity(0.22)))
            context.fill(innerPlayed, with: .color(deck.color.opacity(0.5)))
            context.fill(outerAhead, with: .color(deck.color.opacity(0.45)))
            context.fill(innerAhead, with: .color(deck.color))
        } else {
            var centre = Path()
            centre.addRect(CGRect(x: 0, y: mid, width: size.width, height: 1))
            context.fill(centre, with: .color(Theme.line))
        }

        if let prep {
            for (n, cue) in prep.cues.enumerated() {
                let x = centreX + CGFloat((cue.time - playhead) / secondsPerPoint)
                guard x > -40 && x < size.width else { continue }
                context.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: size.height)), with: .color(cue.swatch))
                context.fill(Path(CGRect(x: x, y: 0, width: 14, height: 12)), with: .color(cue.swatch))
                context.draw(Text("\(n + 1)").font(Theme.label).foregroundStyle(Theme.onAccent), at: CGPoint(x: x + 7, y: 6))
            }
        }

        var head = Path()
        head.addRect(CGRect(x: centreX - 1, y: 0, width: 2, height: size.height))
        context.fill(head, with: .color(Theme.accent))
    }
}

/// The whole track in one strip: played part dimmed, playhead in accent.
struct TrackOverview: View {
    let deck: DeckModel
    let telemetry: UnsafeMutablePointer<DeckTelemetry>?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { _ in
            let playhead = telemetry?.pointee.playhead ?? 0
            Canvas { context, size in
                guard let track = deck.track, !track.peaks.isEmpty, track.duration > 0 else { return }
                let peaks = track.peaks
                let mid = size.height / 2
                let columns = max(1, Int(size.width / 2))
                let perColumn = Double(peaks.count) / Double(columns)
                let playedX = CGFloat(playhead / track.duration) * size.width
                var played = Path()
                var ahead = Path()
                for column in 0..<columns {
                    let start = Int(Double(column) * perColumn)
                    let end = min(peaks.count, max(start + 1, Int(Double(column + 1) * perColumn)))
                    var peak: Float = 0
                    for i in start..<end { peak = max(peak, peaks[i]) }
                    let x = CGFloat(column) * 2
                    let h = max(1, CGFloat(peak) * (mid - 2))
                    let rect = CGRect(x: x, y: mid - h, width: 1.5, height: h * 2)
                    if x < playedX { played.addRect(rect) } else { ahead.addRect(rect) }
                }
                context.fill(played, with: .color(deck.color.opacity(0.4)))
                context.fill(ahead, with: .color(deck.color.opacity(0.85)))
                var head = Path()
                head.addRect(CGRect(x: min(max(playedX, 0), size.width) - 1, y: 0, width: 2, height: size.height))
                context.fill(head, with: .color(Theme.accent))
            }
        }
        .background(Theme.panel)
    }
}

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
        TimelineView(.animation) { timeline in
            let playhead = telemetry?.pointee.playhead(at: timeline.date) ?? 0
            let _ = deck.id == 0 ? JitterProbe.record(frame: timeline.date, playhead: playhead) : ()
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
        // Loop slots exactly as on Prep (shaded, a bar along the top, in the
        // colour you gave them); the loop that is playing outlined in its
        // slot's colour, or the deck colour for a free loop.
        func lx(_ t: Double) -> CGFloat { centreX + CGFloat((t - playhead) / secondsPerPoint) }
        if let prep {
            for (n, loop) in prep.loops.enumerated() {
                let a = lx(loop.start), b = lx(loop.start + Double(loop.beats) * prep.beatSeconds)
                guard b > 0, a < size.width else { continue }
                context.fill(Path(CGRect(x: a, y: 0, width: max(1, b - a), height: size.height)), with: .color(loop.swatch.opacity(0.12)))
                context.fill(Path(CGRect(x: a, y: 0, width: max(1, b - a), height: 3)), with: .color(loop.swatch))
                context.draw(Text("L\(n + 1)").font(.system(size: 9, weight: .semibold)).foregroundStyle(loop.swatch),
                             at: CGPoint(x: a + 3, y: size.height - 3), anchor: .bottomLeading)
            }
        }
        if deck.loopActive, deck.loopLength > 0 {
            let loopColor = prep?.loops.first { $0.id == deck.activeSlot }?.swatch ?? deck.color
            let a = lx(deck.loopStart), b = lx(deck.loopStart + deck.loopLength)
            context.fill(Path(CGRect(x: a, y: 0, width: max(1, b - a), height: size.height)), with: .color(loopColor.opacity(0.14)))
            context.fill(Path(CGRect(x: a, y: 0, width: 2, height: size.height)), with: .color(loopColor))
            context.fill(Path(CGRect(x: b - 2, y: 0, width: 2, height: size.height)), with: .color(loopColor))
            context.fill(Path(CGRect(x: a, y: 0, width: max(1, b - a), height: 3)), with: .color(loopColor))
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
            WaveformRenderer.draw(context, track: track, start: playhead - window / 2, span: window,
                                  rect: CGRect(x: 0, y: 4, width: size.width, height: size.height - 8),
                                  playhead: playhead, color: deck.color)
        } else {
            var centre = Path()
            centre.addRect(CGRect(x: 0, y: mid, width: size.width, height: 1))
            context.fill(centre, with: .color(Theme.line))
        }

        if let prep {
            for (n, cue) in prep.cues.enumerated() {
                let x = centreX + CGFloat((cue.time - playhead) / secondsPerPoint)
                guard x > -80 && x < size.width else { continue }
                // The same flag as on Prep: number and name in the cue's colour.
                context.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: size.height)), with: .color(cue.swatch))
                let label = context.resolve(Text("\(n + 1) \(cue.name)").font(Theme.label).foregroundStyle(Theme.onAccent))
                let m = label.measure(in: size)
                context.fill(Path(CGRect(x: x - 1, y: 0, width: m.width + 9, height: m.height + 4)), with: .color(cue.swatch))
                context.draw(label, at: CGPoint(x: x + 4, y: 2), anchor: .topLeading)
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
    /// Cues and loop slots from Mark, shown as on the Mark page.
    var prep: TrackPrep? = nil

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { _ in
            let playhead = telemetry?.pointee.smoothPlayhead ?? 0
            Canvas { context, size in
                guard let track = deck.track, !track.peaks.isEmpty, track.duration > 0 else { return }
                let playedX = CGFloat(playhead / track.duration) * size.width
                WaveformRenderer.draw(context, track: track, start: 0, span: track.duration,
                                      rect: CGRect(x: 0, y: 2, width: size.width, height: size.height - 4),
                                      playhead: playhead, color: deck.color)
                func x(_ t: Double) -> CGFloat { CGFloat(t / track.duration) * size.width }
                if let prep {
                    // Loop slots: shaded with a bar along the top, in their colour.
                    for loop in prep.loops {
                        let a = x(loop.start), w = max(2, x(loop.start + Double(loop.beats) * prep.beatSeconds) - a)
                        context.fill(Path(CGRect(x: a, y: 0, width: w, height: size.height)), with: .color(loop.swatch.opacity(0.22)))
                        context.fill(Path(CGRect(x: a, y: 0, width: w, height: 2)), with: .color(loop.swatch))
                    }
                    // Cues: a line and a numbered tab, in the cue's colour.
                    for (n, cue) in prep.cues.enumerated() {
                        let cx = x(cue.time)
                        context.fill(Path(CGRect(x: cx - 0.75, y: 0, width: 1.5, height: size.height)), with: .color(cue.swatch))
                        let label = context.resolve(Text("\(n + 1)").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.onAccent))
                        let m = label.measure(in: size)
                        context.fill(Path(CGRect(x: cx - 0.75, y: 0, width: m.width + 5, height: m.height + 1)), with: .color(cue.swatch))
                        context.draw(label, at: CGPoint(x: cx + 1.75, y: 0.5), anchor: .topLeading)
                    }
                }
                if deck.loopActive, deck.loopLength > 0 {
                    let a = CGFloat(deck.loopStart / track.duration) * size.width
                    let w = max(2, CGFloat(deck.loopLength / track.duration) * size.width)
                    context.fill(Path(CGRect(x: a, y: 0, width: w, height: size.height)), with: .color(deck.color.opacity(0.35)))
                }
                var head = Path()
                head.addRect(CGRect(x: min(max(playedX, 0), size.width) - 1, y: 0, width: 2, height: size.height))
                context.fill(head, with: .color(Theme.accent))
            }
        }
        .background(Theme.panel)
    }
}

//
//  AppModel+Prep.swift
//  Spindle
//
//  Prep's pre-listen player: the selected track plays on its own engine
//  deck (never recorded), with a metronome on the beatgrid to check it by
//  ear. Everything on the Prep page acts at the playhead.
//

import Foundation

extension AppModel {
    /// Where the Prep tools act: the live playhead while playing, else the cursor.
    var prepPosition: Double {
        if prepPage.playing, let e = engine?.preview {
            let t = e.jumpRequest.isNaN ? e.telemetry.pointee.playhead : e.jumpRequest
            return max(0, t)
        }
        return prepPage.cursor
    }

    var prepDuration: Double {
        if let p = prepPage.preview { return p.duration }
        if let w = prepPage.waveform { return Double(w.peaks.count) / PrepSuggestion.peaksPerSecond }
        return prepPage.selected.flatMap { analysis.analysis(for: $0)?.duration } ?? 300
    }

    /// Decodes the selected track for the player. If the player was running
    /// it carries on in the new track.
    func loadPreview(_ url: URL) {
        let rate = engine?.sampleRate ?? selectedDevice?.sampleRate ?? 48000
        Task {
            // Moving through the list: only decode the track you stop on.
            try? await Task.sleep(for: .milliseconds(200))
            guard prepPage.selected == url else { return }
            guard let track = try? await TrackLoader.load(url: url, sampleRate: rate) else { return }
            guard prepPage.selected == url else { retire(track.samples); return }
            let old = prepPage.preview
            prepPage.preview = track
            if let e = engine?.preview {
                _ = e.exchangeTrack(track.samples)
                e.jumpRequest = prepPage.cursor
            }
            if let old { retire(old.samples) }
            syncPreviewGrid()
        }
    }

    /// Hands the track to a newly started engine.
    func attachPreview() {
        guard let engine else { return }
        engine.preview.gain = Float(prepPage.volume * prepPage.volume)
        if let saved = UserDefaults.standard.object(forKey: "previewOutput.\(engine.device.name)") as? Int,
           saved + 1 < engine.device.outputChannels {
            engine.previewOutput = saved
        }
        engine.preview.metronome = prepPage.metronome
        engine.preview.transportPlaying = false
        prepPage.playing = false
        if let p = prepPage.preview {
            if p.samples.pointee.sampleRate == engine.sampleRate {
                _ = engine.preview.exchangeTrack(p.samples)
                engine.preview.jumpRequest = prepPage.cursor
            } else if let url = prepPage.selected {
                loadPreview(url)
            }
        }
        syncPreviewGrid()
    }

    /// The metronome follows the grid as you edit it.
    func syncPreviewGrid() {
        guard let e = engine?.preview, let url = prepPage.selected, let p = prep.prep(for: url) else { return }
        e.gridOffset = p.gridOffset
        e.gridBeat = p.beatSeconds
    }

    func prepTogglePlay() { prepSetPlaying(!prepPage.playing) }

    func prepSetPlaying(_ on: Bool) {
        guard let e = engine?.preview, prepPage.preview != nil else { prepPage.playing = false; return }
        if on {
            if prepPage.cursor >= prepDuration - 0.05 { prepPage.cursor = 0 }
            e.jumpRequest = prepPage.cursor
            e.tempo = 1
            e.transportPlaying = true
        } else {
            prepPage.cursor = prepPosition
            e.transportPlaying = false
            e.jumpRequest = prepPage.cursor
        }
        prepPage.playing = on
    }

    func prepSeek(to time: Double) {
        let t = min(max(0, time), prepDuration)
        prepPage.cursor = t
        engine?.preview.jumpRequest = t
    }

    func prepSeek(by delta: Double) { prepSeek(to: prepPosition + delta) }

    /// Moves by whole beats on the grid (or seconds when there's none).
    func prepStep(beats: Int) {
        guard let url = prepPage.selected, let p = prep.prep(for: url) else { prepSeek(by: Double(beats)); return }
        let index = p.beatIndex(at: prepPosition)
        let snapped = index.rounded()
        // Already on a beat: step from it; otherwise land on the next one that way.
        let base = abs(index - snapped) < 0.05 ? snapped : (beats > 0 ? index.rounded(.down) : index.rounded(.up))
        prepSeek(to: p.gridOffset + (base + Double(beats)) * p.beatSeconds)
    }

    func prepJump(_ role: CueRole) {
        guard let url = prepPage.selected, let cue = prep.prep(for: url)?.cue(role) else { return }
        prepSeek(to: cue.time)
    }

    /// Sets the cue on the beat nearest the playhead.
    func prepSetCue(_ role: CueRole) {
        guard let url = prepPage.selected, let p = prep.prep(for: url) else { return }
        let t = p.snap(prepPosition)
        prep.update(url) { $0.setCue(role, time: t) }
    }

    /// Puts bar 1 of the grid on the beat at the playhead.
    func prepDownbeatHere() {
        guard let url = prepPage.selected else { return }
        let here = prepPosition
        prep.update(url) { p in
            let bar = 4 * p.beatSeconds
            p.gridOffset = here - (here / bar).rounded(.down) * bar
        }
        syncPreviewGrid()
    }

    func prepEdit(_ change: (inout TrackPrep) -> Void) {
        guard let url = prepPage.selected else { return }
        prep.update(url, change)
        syncPreviewGrid()
    }

    func prepSetMetronome(_ on: Bool) {
        prepPage.metronome = on
        engine?.preview.metronome = on
    }

    func prepSetVolume(_ v: Double) {
        prepPage.volume = min(max(v, 0), 1)
        engine?.preview.gain = Float(prepPage.volume * prepPage.volume)
    }

    func prepSetOutput(_ first: Int) {
        engine?.previewOutput = first
        UserDefaults.standard.set(first, forKey: "previewOutput.\(engine?.device.name ?? "")")
    }

    /// The previous or next track in the Prep list.
    func prepStepTrack(_ offset: Int, in order: [URL]) {
        guard !order.isEmpty else { return }
        let i = prepPage.selected.flatMap { order.firstIndex(of: $0) } ?? -1
        let next = min(max(0, i + offset), order.count - 1)
        if i < 0 { selectForPrep(order[0]) } else if next != i { selectForPrep(order[next]) }
    }
}

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
            syncPreviewFX()
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
        syncPreviewFX()
    }

    /// The metronome follows the grid as you edit it.
    func syncPreviewGrid() {
        guard let e = engine?.preview, let url = prepPage.selected, let p = prep.prep(for: url) else { return }
        e.gridOffset = p.gridOffset
        e.gridBeat = p.beatSeconds
        e.beatSeconds = p.beatSeconds
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

    private var prepGrid: TrackPrep? { prepPage.selected.flatMap { prep.prep(for: $0) } }

    /// Jumps to cue slot `n` (0-based).
    func prepJump(cue n: Int) {
        guard let cues = prepGrid?.cues, cues.indices.contains(n) else { return }
        prepSeek(to: cues[n].time)
    }

    /// Moves cue slot `n` to the beat nearest the playhead, or adds a cue.
    func prepSetCue(slot n: Int) {
        guard let p = prepGrid else { return }
        let t = p.snap(prepPosition)
        prepEdit { $0.setCue(slot: n, time: t) }
    }

    func prepAddCue() {
        guard let p = prepGrid else { return }
        let t = p.snap(prepPosition)
        prepEdit { $0.addCue(at: t) }
    }

    /// A new loop slot starting on the beat at the playhead.
    func prepAddLoop(bars: Double = 4) {
        guard let p = prepGrid else { return }
        let start = p.snap(prepPosition)
        prepEdit { $0.loops.append(SavedLoop(start: start, beats: Int(bars * 4))) }
    }

    /// Moves a loop slot's in-point to the beat at the playhead.
    func prepSetLoopIn(_ id: UUID) {
        guard let p = prepGrid else { return }
        let start = p.snap(prepPosition)
        prepEdit { if let i = $0.loops.firstIndex(where: { $0.id == id }) { $0.loops[i].start = start } }
        if prepPage.activeLoop == id { prepPage.activeLoop = nil; prepAudition(id) }
    }

    func prepSetLoopBars(_ id: UUID, _ bars: Double) {
        prepEdit { if let i = $0.loops.firstIndex(where: { $0.id == id }) { $0.loops[i].beats = max(1, Int(bars * 4)) } }
        if prepPage.activeLoop == id { prepPage.activeLoop = nil; prepAudition(id) }
    }

    func prepRemoveLoop(_ id: UUID) {
        if prepPage.activeLoop == id { prepAudition(id) }
        prepEdit { $0.loops.removeAll { $0.id == id } }
    }

    /// Loops a slot in the player (and starts it); again to let it run on.
    func prepAudition(_ id: UUID) {
        guard let e = engine?.preview, let p = prepGrid else { return }
        if prepPage.activeLoop == id {
            e.loopActive = false
            prepPage.activeLoop = nil
            return
        }
        guard let loop = p.loops.first(where: { $0.id == id }) else { return }
        e.loopActive = false
        e.loopStart = loop.start
        e.loopLength = Double(loop.beats) * p.beatSeconds
        prepSeek(to: loop.start)
        e.loopActive = true
        prepPage.activeLoop = id
        if !prepPage.playing { prepSetPlaying(true) }
    }

    /// The player plays dry, with no loop running.
    func syncPreviewFX() {
        guard let e = engine?.preview else { return }
        for kind in FXKind.allCases { e.setFX(kind, 0) }
        e.beatSeconds = prepGrid?.beatSeconds ?? 0.5
        e.loopActive = false
        prepPage.activeLoop = nil
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

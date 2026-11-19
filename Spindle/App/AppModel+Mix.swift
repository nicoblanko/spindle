//
//  AppModel+Mix.swift
//  Spindle
//
//  Prep and Mix actions: background cue suggestion, cues, loops, clip FX,
//  and the deck monitor the clip grid and session log use.
//

import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

@Observable
final class PrepPageModel {
    var selected: URL?
    /// Waveform of the selected track.
    var waveform: PrepSuggestion?
    var loading = false
    /// Position the Prep tools act on, in seconds.
    var cursor: Double = 0
    /// Seconds shown in the zoomed lane.
    var zoom: Double = 16
    var error: String?

    // Pre-listen player
    /// The selected track decoded for playback (and its detailed waveform).
    var preview: LoadedTrack?
    var playing = false
    var metronome = false
    var volume: Double = 0.8
    /// The loop slot looping in the player, if any.
    var activeLoop: UUID?
}

extension AppModel {
    /// The set open in Organize's right panel, if it still exists.
    var openSetNode: PlaylistNode? {
        library.playlists.node(openSet).flatMap { $0.isFolder ? nil : $0 }
    }

    // MARK: Saved views

    var currentView: SavedView? { savedViews.first { $0.id == currentViewID } }

    /// The grid differs from the saved view it came from.
    var viewModified: Bool {
        currentView.map { !organizeView.sameSetup(as: $0.settings) } ?? false
    }

    func applyView(_ id: UUID?) {
        currentViewID = id
        if let v = currentView {
            var settings = v.settings
            settings.collapsed = organizeView.collapsed
            organizeView = settings
        }
    }

    @discardableResult
    func saveViewAs(_ name: String) -> UUID {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let view = SavedView(name: trimmed.isEmpty ? "View \(savedViews.count + 1)" : trimmed, settings: organizeView)
        savedViews.append(view)
        currentViewID = view.id
        return view.id
    }

    func updateCurrentView() {
        guard let i = savedViews.firstIndex(where: { $0.id == currentViewID }) else { return }
        savedViews[i].settings = organizeView
    }

    func revertCurrentView() { applyView(currentViewID) }

    func renameView(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let i = savedViews.firstIndex(where: { $0.id == id }) else { return }
        savedViews[i].name = trimmed
    }

    func deleteView(_ id: UUID) {
        savedViews.removeAll { $0.id == id }
        if currentViewID == id { currentViewID = nil }
    }

    func duplicateView(_ id: UUID) {
        guard let v = savedViews.first(where: { $0.id == id }) else { return }
        let copy = SavedView(name: v.name + " copy", settings: v.settings)
        savedViews.append(copy)
        applyView(copy.id)
    }

    // MARK: Playlists

    /// Adds files or folders (from anywhere) to a playlist, then analyses
    /// and preps whatever is new.
    func addToPlaylist(_ urls: [URL], playlist: UUID) {
        let files = PlaylistStore.audioFiles(in: urls)
        let added = library.playlists.add(files, to: playlist)
        spindleLog.notice("Playlist: added \(added) of \(files.count) files")
        guard added > 0 else { return }
        Task {
            await analysis.analyze(files)
            await prepareAll()
        }
    }

    /// Lets you pick files or folders anywhere and adds them to a playlist.
    func chooseFilesForPlaylist(_ playlist: UUID) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio, .folder]
        panel.prompt = "Add to playlist"
        guard panel.runModal() == .OK else { return }
        addToPlaylist(panel.urls, playlist: playlist)
    }

    // MARK: Prep

    /// Suggests grid and cues for every track that has none yet.
    func prepareAll() async {
        let todo = library.allTracks.map(\.url).filter { prep.prep(for: $0) == nil }
        guard !todo.isEmpty else { return }
        preparing = todo.count
        spindleLog.notice("Prep: suggesting cues for \(todo.count) tracks")
        let bpms = Dictionary(uniqueKeysWithValues: todo.map { ($0, analysis.analysis(for: $0)?.bpm) })
        await withTaskGroup(of: (URL, TrackPrep?).self) { group in
            var iterator = todo.makeIterator()
            func addNext() {
                guard let url = iterator.next() else { return }
                let bpm = bpms[url] ?? nil
                group.addTask(priority: .utility) {
                    (url, try? PrepAnalyzer.suggest(url: url, bpm: bpm).prep)
                }
            }
            for _ in 0..<4 { addNext() }
            while let (url, result) = await group.next() {
                if let result, prep.prep(for: url) == nil { prep.set(result, for: url) }
                preparing -= 1
                addNext()
            }
        }
        preparing = 0
    }

    /// Selects a track on the Prep page and loads its waveform.
    func selectForPrep(_ url: URL) {
        guard prepPage.selected != url else { return }
        prepPage.selected = url
        prepPage.waveform = nil
        prepPage.error = nil
        prepPage.cursor = prep.prep(for: url)?.cue(.intro)?.time ?? 0
        prepPage.loading = true
        loadPreview(url)
        let bpm = analysis.analysis(for: url)?.bpm
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard prepPage.selected == url else { return }
            let result = await Task.detached(priority: .userInitiated) {
                Result { try PrepAnalyzer.suggest(url: url, bpm: bpm) }
            }.value
            guard prepPage.selected == url else { return }
            prepPage.loading = false
            switch result {
            case .success(let suggestion):
                prepPage.waveform = suggestion
                if prep.prep(for: url) == nil {
                    prep.set(suggestion.prep, for: url)
                    if !prepPage.playing { prepSeek(to: suggestion.prep.cue(.intro)?.time ?? 0) }
                }
                syncPreviewGrid()
            case .failure(let error):
                prepPage.error = error.localizedDescription
            }
        }
    }

    /// Replaces grid and cues with a fresh suggestion (keeps FX and mix-ready).
    func resuggest(_ url: URL) {
        guard let suggestion = prepPage.waveform, prepPage.selected == url else { return }
        let bpm = analysis.analysis(for: url)?.bpm
        Task {
            guard let fresh = await Task.detached(priority: .userInitiated, operation: {
                try? PrepAnalyzer.suggest(url: url, bpm: bpm)
            }).value else { return }
            prep.update(url) { p in
                p.bpm = fresh.prep.bpm
                p.gridOffset = fresh.prep.gridOffset
                p.cues = fresh.prep.cues
                p.loops = fresh.prep.loops
            }
            syncPreviewGrid()
            _ = suggestion
        }
    }

    // MARK: Decks

    /// Applies a clip's FX and tempo to the deck it was loaded on.
    func applyClip(_ url: URL, to deck: DeckModel) {
        let p = prep.prep(for: url)
        // A new track starts dry; the deck's FX knobs are on the Mix page.
        for kind in FXKind.allCases { setFX(kind, 0, deck: deck) }
        setLoop(false, deck: deck)
        let beat = p?.beatSeconds ?? analysis.analysis(for: url).map { 60 / $0.bpm } ?? 0.5
        engine?.decks[deck.id].beatSeconds = beat
        engine?.decks[deck.id].gridBeat = beat
        engine?.decks[deck.id].gridOffset = p?.gridOffset ?? 0
    }

    /// Jumps the deck to cue slot `n` (0-based). The record keeps control from there.
    func jump(deck: DeckModel, toCue n: Int) {
        guard let url = deck.track?.url, let cues = prep.prep(for: url)?.cues, cues.indices.contains(n) else { return }
        engine?.decks[deck.id].jumpRequest = cues[n].time
    }

    /// Plays a loop slot on a deck: jumps to its in-point and loops it.
    /// Pressing the playing slot again lets the track run on.
    func playLoopSlot(_ loop: SavedLoop, deck: DeckModel) {
        guard let url = deck.track?.url, let p = prep.prep(for: url), let e = engine?.decks[deck.id] else { return }
        if deck.loopActive && deck.activeSlot == loop.id {
            setLoop(false, deck: deck)
            deck.activeSlot = nil
            return
        }
        e.loopActive = false
        e.jumpRequest = loop.start
        e.loopStart = loop.start
        e.loopLength = Double(loop.beats) * p.beatSeconds
        e.loopActive = true
        deck.loopActive = true
        deck.activeSlot = loop.id
        deck.loopStart = e.loopStart
        deck.loopLength = e.loopLength
    }

    func setFX(_ kind: FXKind, _ value: Double, deck: DeckModel, fromMIDI: Bool = false) {
        deck.fx[kind] = value
        engine?.decks[deck.id].setFX(kind, value)
        if !fromMIDI, kind == .filter || kind == .echo {
            midi.release(MIDITarget(deck: deck.id, action: kind == .filter ? .filter : .echo))
        }
    }

    /// Starts a loop of `deck.loopBeats` beats on the nearest beat, or ends it.
    func setLoop(_ on: Bool, deck: DeckModel) {
        deck.loopActive = on
        deck.activeSlot = nil
        guard let engine else { return }
        let e = engine.decks[deck.id]
        if on {
            let now = e.telemetry.pointee.playhead
            let p = deck.track.flatMap { prep.prep(for: $0.url) }
            let beat = p?.beatSeconds ?? e.beatSeconds
            let start = p.map { grid -> Double in
                // Start on the beat just played, so the loop catches this moment.
                grid.gridOffset + ((now - grid.gridOffset) / beat).rounded(.down) * beat
            } ?? now
            e.loopStart = start
            e.loopLength = beat * Double(deck.loopBeats)
            deck.loopStart = start
            deck.loopLength = e.loopLength
        }
        e.loopActive = on
    }

    func setFilter(_ value: Double, deck: DeckModel, fromMIDI: Bool = false) {
        deck.filter = value
        engine?.decks[deck.id].filter = value
        if !fromMIDI { midi.release(MIDITarget(deck: deck.id, action: .filter)) }
    }

    func setEcho(_ value: Double, deck: DeckModel, fromMIDI: Bool = false) {
        deck.echo = value
        engine?.decks[deck.id].echo = value
        if !fromMIDI { midi.release(MIDITarget(deck: deck.id, action: .echo)) }
    }

    func setLoopBeats(_ beats: Int, deck: DeckModel) {
        deck.loopBeats = min(64, max(1, beats))
        if deck.loopActive, deck.activeSlot == nil, let e = engine?.decks[deck.id] {
            e.loopLength = e.beatSeconds * Double(deck.loopBeats)
            deck.loopLength = e.loopLength
        }
    }

    func toggleRecording() {
        if sessions.recording { sessions.stop() } else { sessions.start(model: self) }
    }

    func setupMIDI() {
        midi.currentValue = { [weak self] target in
            guard let self else { return 0 }
            guard let id = target.deck else { return self.crossfader }
            let deck = self.decks[id]
            switch target.action {
            case .filter: return deck.filter
            case .echo: return deck.echo
            case .tempo: return deck.tempo / deck.tempoRange
            case .volume: return deck.volume
            default: return 0
            }
        }
        midi.handler = { [weak self] target, value in
            guard let self else { return }
            guard let id = target.deck else {
                if target.action == .record { self.toggleRecording() }
                if target.action == .crossfader { self.setCrossfader(abs(value) < 0.03 ? 0 : value) }
                return
            }
            let deck = self.decks[id]
            switch target.action {
            case .cue1: self.jump(deck: deck, toCue: 0)
            case .cue2: self.jump(deck: deck, toCue: 1)
            case .cue3: self.jump(deck: deck, toCue: 2)
            case .cue4: self.jump(deck: deck, toCue: 3)
            case .loop: self.setLoop(!deck.loopActive, deck: deck)
            case .loopHalve: self.setLoopBeats(deck.loopBeats / 2, deck: deck)
            case .loopDouble: self.setLoopBeats(deck.loopBeats * 2, deck: deck)
            case .filter: self.setFilter(abs(value) < 0.03 ? 0 : value, deck: deck, fromMIDI: true)
            case .echo: self.setEcho(value, deck: deck, fromMIDI: true)
            case .loadSelected:
                if let url = self.highlightedClip { Task { await self.load(url: url, into: deck) } }
            case .play: self.setPlaying(!deck.transportPlaying, deck: deck)
            case .cueButton: self.cue(deck: deck)
            case .sync: self.sync(deck: deck)
            case .tempo: self.setTempo((abs(value) < 0.02 ? 0 : value) * deck.tempoRange, deck: deck)
            case .volume: self.setVolume(value, deck: deck)
            case .record, .crossfader: break
            }
        }
        midi.start()
    }

    // MARK: Laptop mode

    func setPlaying(_ on: Bool, deck: DeckModel) {
        deck.transportPlaying = on && deck.track != nil
        engine?.decks[deck.id].transportPlaying = deck.transportPlaying
    }

    /// Back to the IN cue (or the start) and stop, like a CDJ's cue button.
    func cue(deck: DeckModel) {
        setPlaying(false, deck: deck)
        let start = deck.track.flatMap { t in prep.prep(for: t.url).flatMap { $0.cue(.intro) ?? $0.cues.first }?.time } ?? 0
        engine?.decks[deck.id].jumpRequest = start
    }

    func setTempo(_ value: Double, deck: DeckModel) {
        deck.tempo = min(max(value, -0.5), 0.5)
        if abs(deck.tempo) > deck.tempoRange { deck.tempoRange = abs(deck.tempo) > 0.16 ? 0.5 : 0.16 }
        engine?.decks[deck.id].tempo = 1 + deck.tempo
    }

    /// Matches this deck's tempo to the other deck and lines up the beats.
    func sync(deck: DeckModel) {
        let other = decks[1 - deck.id]
        guard let mine = deck.track?.url, let theirs = other.track?.url,
              let myBPM = bpm(of: mine), let theirBPM = bpm(of: theirs), let engine else { return }
        let target = theirBPM * (1 + other.tempo)
        // Half or double time if that is closer.
        let base = [myBPM, myBPM * 2, myBPM / 2].min { abs(target / $0 - 1) < abs(target / $1 - 1) } ?? myBPM
        setTempo(target / base - 1, deck: deck)

        if let myGrid = prep.prep(for: mine), let theirGrid = prep.prep(for: theirs) {
            let theirPhase = theirGrid.beatIndex(at: engine.decks[other.id].telemetry.pointee.playhead)
            let now = engine.decks[deck.id].telemetry.pointee.playhead
            let mineIndex = myGrid.beatIndex(at: now)
            var wanted = mineIndex.rounded(.down) + (theirPhase - theirPhase.rounded(.down))
            if wanted - mineIndex > 0.5 { wanted -= 1 }
            if wanted - mineIndex < -0.5 { wanted += 1 }
            // Before the first beat (e.g. a track still at 0:00): move on by
            // whole bars rather than clamp, so the phase stays right.
            while myGrid.gridOffset + wanted * myGrid.beatSeconds < 0 { wanted += 4 }
            seek(deck: deck, to: myGrid.gridOffset + wanted * myGrid.beatSeconds)
        }
    }

    func bpm(of url: URL) -> Double? { prep.prep(for: url)?.bpm ?? analysis.analysis(for: url)?.bpm }

    func setVolume(_ value: Double, deck: DeckModel) {
        deck.volume = min(max(value, 0), 1)
        updateGains()
    }

    func setCrossfader(_ value: Double) {
        crossfader = min(max(value, -1), 1)
        updateGains()
    }

    /// Laptop mode mixes in Spindle (volume × crossfader); with turntables the
    /// hardware mixer does it and the decks play at full level.
    func updateGains() {
        guard let engine else { return }
        for deck in decks {
            var gain = 1.0
            if engine.laptop {
                let fade = deck.id == 0 ? (crossfader <= 0 ? 1 : 1 - crossfader) : (crossfader >= 0 ? 1 : 1 + crossfader)
                gain = deck.volume * deck.volume * fade        // squared: a fader-like curve
            }
            engine.decks[deck.id].gain = Float(gain)
        }
    }

    // MARK: Seeking

    /// Moves the track to `time` (with turntables the record keeps control
    /// from there).
    func seek(deck: DeckModel, to time: Double) {
        guard let track = deck.track, let e = engine?.decks[deck.id] else { return }
        e.jumpRequest = min(max(time, 0), track.duration)
    }

    /// Moves the track by `delta` seconds; repeated calls between audio
    /// buffers add up.
    func seek(deck: DeckModel, by delta: Double) {
        guard let e = engine?.decks[deck.id] else { return }
        let base = e.jumpRequest.isNaN ? e.telemetry.pointee.playhead : e.jumpRequest
        seek(deck: deck, to: base + delta)
    }

    /// Scrolling or dragging the waveform: while the deck plays, the track
    /// is pushed along smoothly (no audible jumps); when it's stopped, it
    /// simply moves.
    func scrub(deck: DeckModel, by delta: Double) {
        guard let e = engine?.decks[deck.id] else { return }
        if abs(e.telemetry.pointee.pitch) > 0.05 && e.jumpRequest.isNaN {
            e.nudgeTotal += delta
        } else {
            seek(deck: deck, by: delta)
        }
    }

    func setLaneWindow(_ seconds: Double, deck: DeckModel) {
        deck.laneWindow = min(max(seconds, 1.5), 48)
    }

    /// Effective tempo of a deck: the track's BPM times the record's speed.
    func liveBPM(_ deck: DeckModel) -> Double? {
        guard let url = deck.track?.url else { return nil }
        let bpm = prep.prep(for: url)?.bpm ?? analysis.analysis(for: url)?.bpm
        return bpm.map { $0 * max(abs(deck.pitch), 0.0001) }
    }

    /// Mirrors the engine's deck state for the UI (clip matching) and the
    /// session log, a few times a second.
    func monitorDecks() {
        Task { [weak self] in
            while let self, let core = self.engine, self.running {
                for deck in self.decks {
                    let t = core.decks[deck.id].telemetry.pointee
                    let playing = deck.track != nil && t.pitch > 0.5
                    if deck.playing != playing { deck.playing = playing }
                    let rounded = (t.pitch * 1000).rounded() / 1000
                    if abs(deck.pitch - rounded) > 0.002 { deck.pitch = rounded }
                }
                self.sessions.tick(model: self)
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    /// Records the mixer's master send when the hardware has one (the Xone's
    /// inputs 1–2), otherwise Spindle's own output.
    func recordInputDefault(for core: AudioEngineCore) -> Int {
        guard !core.simulate, core.hasInputs else { return -1 }
        let used = Set([routing.inputA, routing.inputB])
        return used.contains(0) ? -1 : 0
    }

    /// The deck the next clip should go to: the one that isn't playing.
    var freeDeck: DeckModel {
        if decks[0].playing && !decks[1].playing { return decks[1] }
        if decks[1].playing && !decks[0].playing { return decks[0] }
        if decks[0].track == nil { return decks[0] }
        if decks[1].track == nil { return decks[1] }
        return decks[0]
    }
}

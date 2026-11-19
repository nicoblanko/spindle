//
//  AppModel+Mix.swift
//  Spindle
//
//  Prep and Mix actions: background cue suggestion, cues, loops, clip FX,
//  and the deck monitor the clip grid and session log use.
//

import Foundation
import Observation

@Observable
final class PrepPageModel {
    var selected: URL?
    /// Waveform of the selected track.
    var waveform: PrepSuggestion?
    var loading = false
    /// Position the Prep tools act on, in seconds.
    var cursor: Double = 0
    /// Seconds shown in the zoomed lane.
    var zoom: Double = 32
    var error: String?
}

extension AppModel {
    // MARK: Prep

    /// Suggests grid and cues for every track that has none yet.
    func prepareAll() async {
        let todo = library.tracks.map(\.url).filter { prep.prep(for: $0) == nil }
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
        let bpm = analysis.analysis(for: url)?.bpm
        Task {
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
                    prepPage.cursor = suggestion.prep.cue(.intro)?.time ?? 0
                }
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
            _ = suggestion
        }
    }

    // MARK: Decks

    /// Applies a clip's FX and tempo to the deck it was loaded on.
    func applyClip(_ url: URL, to deck: DeckModel) {
        let p = prep.prep(for: url)
        setFilter(p?.fx.filter ?? 0, deck: deck)
        setEcho(p?.fx.echo ?? 0, deck: deck)
        setLoop(false, deck: deck)
        let beat = p?.beatSeconds ?? analysis.analysis(for: url).map { 60 / $0.bpm } ?? 0.5
        engine?.decks[deck.id].beatSeconds = beat
    }

    /// Jumps the deck to a cue. The record keeps control from there.
    func jump(deck: DeckModel, to role: CueRole) {
        guard let url = deck.track?.url, let cue = prep.prep(for: url)?.cue(role) else { return }
        engine?.decks[deck.id].jumpRequest = cue.time
    }

    /// Starts a loop of `deck.loopBeats` beats on the nearest beat, or ends it.
    func setLoop(_ on: Bool, deck: DeckModel) {
        deck.loopActive = on
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
        if deck.loopActive, let e = engine?.decks[deck.id] {
            e.loopLength = e.beatSeconds * Double(deck.loopBeats)
        }
    }

    func toggleRecording() {
        if sessions.recording { sessions.stop() } else { sessions.start(model: self) }
    }

    func setupMIDI() {
        midi.currentValue = { [weak self] target in
            guard let self, let id = target.deck else { return 0 }
            return target.action == .filter ? self.decks[id].filter : self.decks[id].echo
        }
        midi.handler = { [weak self] target, value in
            guard let self else { return }
            guard let id = target.deck else {
                if target.action == .record { self.toggleRecording() }
                return
            }
            let deck = self.decks[id]
            switch target.action {
            case .cue1: self.jump(deck: deck, to: .intro)
            case .cue2: self.jump(deck: deck, to: .drop)
            case .cue3: self.jump(deck: deck, to: .breakdown)
            case .cue4: self.jump(deck: deck, to: .outro)
            case .loop: self.setLoop(!deck.loopActive, deck: deck)
            case .loopHalve: self.setLoopBeats(deck.loopBeats / 2, deck: deck)
            case .loopDouble: self.setLoopBeats(deck.loopBeats * 2, deck: deck)
            case .filter: self.setFilter(abs(value) < 0.03 ? 0 : value, deck: deck, fromMIDI: true)
            case .echo: self.setEcho(value, deck: deck, fromMIDI: true)
            case .loadSelected:
                if let url = self.highlightedClip { Task { await self.load(url: url, into: deck) } }
            case .record: self.toggleRecording()
            }
        }
        midi.start()
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

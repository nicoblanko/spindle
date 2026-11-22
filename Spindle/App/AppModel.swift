//
//  AppModel.swift
//  Spindle
//
//  UI-side state: device choice, engine lifecycle, loaded tracks.
//

import AVFoundation
import Observation
import OSLog
import SwiftUI

@Observable
final class DeckModel: Identifiable {
    let id: Int
    var track: LoadedTrack?
    var loading = false
    var error: String?
    /// Speed of the virtual turntable in simulation mode.
    var simulatedPitch: Double = 0
    var simulatorLifted = false
    /// Absolute: the needle's place on the record is the place in the track
    /// (needle drops jump). Relative: only the record's speed and direction
    /// count, so needle drops don't move the track. Remembered per deck.
    /// The timecode vinyl on this deck's turntable. Remembered per deck.
    var vinyl: TimecodeDefinition = .traktorMK2 {
        didSet { UserDefaults.standard.set(vinyl.id, forKey: "deck.vinyl.\(label)") }
    }
    var absoluteMode = true {
        didSet { UserDefaults.standard.set(absoluteMode, forKey: "deck.absolute.\(label)") }
    }
    var testTone = false
    var loopActive = false
    var loopBeats = 8
    /// The loop slot playing on this deck, if any.
    var activeSlot: UUID?
    /// The loop that's playing (seconds), for the waveforms.
    var loopStart: Double = 0
    var loopLength: Double = 0
    /// The deck's FX amounts (filter −1 … 1, the rest 0 … 1).
    var fx = ClipFX()
    var filter: Double { get { fx.filter } set { fx.filter = newValue } }
    var echo: Double { get { fx.echo } set { fx.echo = newValue } }
    // Laptop mode transport.
    var transportPlaying = false
    /// Tempo change in laptop mode: 0.05 = +5%.
    var tempo: Double = 0
    /// ± range of the tempo slider.
    var tempoRange: Double = 0.08
    /// Channel volume in laptop mode, 0…1.
    var volume: Double = 1
    /// Seconds shown across the zoomed waveform.
    var laneWindow: Double = 6

    /// Updated a few times a second from the engine: playing forward at speed.
    var playing = false
    /// Current speed (1 = the track's own tempo).
    var pitch: Double = 0

    init(id: Int) {
        self.id = id
        absoluteMode = UserDefaults.standard.object(forKey: "deck.absolute.\(id == 0 ? "A" : "B")") as? Bool ?? true
        vinyl = TimecodeDefinition.named(UserDefaults.standard.string(forKey: "deck.vinyl.\(id == 0 ? "A" : "B")")) ?? .traktorMK2
    }

    // Remembered per deck and vinyl format.
    private func key(_ name: String, _ def: TimecodeDefinition) -> String { "deck\(id).\(def.id).\(name)" }

    /// The decoder variant (channel order, phase) that last locked on this deck.
    func preferredConfig(for def: TimecodeDefinition) -> Int? {
        UserDefaults.standard.object(forKey: key("config", def)) as? Int
    }
    func setPreferredConfig(_ index: Int, for def: TimecodeDefinition) {
        UserDefaults.standard.set(index, forKey: key("config", def))
    }

    /// Where the record's first groove sits in the timecode sequence.
    func startIndex(for def: TimecodeDefinition) -> Int? {
        UserDefaults.standard.object(forKey: key("start", def)) as? Int
    }
    func setStartIndex(_ index: Int, for def: TimecodeDefinition) {
        UserDefaults.standard.set(index, forKey: key("start", def))
    }

    var label: String { id == 0 ? "A" : "B" }
    var color: Color { id == 0 ? Theme.deckA : Theme.deckB }
}

/// Diagnostics: unified log plus a plain file in the app's container
/// (~/Library/Logs/spindle.log).
nonisolated struct DiagnosticLog: Sendable {
    private let logger = Logger(subsystem: "Spindle", category: "decks")
    private let url: URL? = {
        guard let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs") else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("spindle.log")
    }()

    func notice(_ message: String) { logger.notice("\(message, privacy: .public)"); write(message) }
    func error(_ message: String) { logger.error("\(message, privacy: .public)"); write("ERROR " + message) }

    private func write(_ message: String) {
        guard let url else { return }
        let line = "\(Date().formatted(date: .omitted, time: .standard)) \(message)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}

nonisolated let spindleLog = DiagnosticLog()

@Observable
final class AppModel {
    var devices: [AudioDevice] = []
    var selectedDeviceID: AudioDeviceID?
    /// Deck A's vinyl (the simulator and a few labels use one name).
    var definition: TimecodeDefinition { decks.first?.vinyl ?? .traktorMK2 }

    /// Changes one deck's vinyl and restarts the audio to read it.
    func setVinyl(_ def: TimecodeDefinition, deck: DeckModel) {
        guard deck.vinyl != def else { return }
        deck.vinyl = def
        Task { await start() }
    }
    /// How the decks are played: turntables, the laptop alone, or simulated
    /// turntables (for testing). Remembered between launches.
    var controlMode: ControlMode = ControlMode(rawValue: UserDefaults.standard.string(forKey: "control") ?? "") ?? .laptop {
        didSet { UserDefaults.standard.set(controlMode.rawValue, forKey: "control") }
    }
    var simulate: Bool { controlMode == .simulated }
    var laptop: Bool { engine?.laptop ?? (controlMode == .laptop) }
    /// Laptop mode's crossfader: −1 = deck A only, 0 = both, 1 = deck B only.
    var crossfader: Double = 0

    enum ControlMode: String, CaseIterable, Identifiable {
        case vinyl = "Vinyl", laptop = "Laptop", simulated = "Simulated vinyl"
        var id: String { rawValue }
    }
    private(set) var engine: AudioEngineCore?
    private(set) var running = false
    /// Lock losses already logged, per deck.
    @ObservationIgnored private var lossSeen: [Int: Int32] = [:]
    @ObservationIgnored private var readingSeen: [Int: Bool] = [:]
    @ObservationIgnored private var lastPlayhead: [Int: Double] = [:]
    /// Stereo pair per deck (first channel, 0-based). Nil until a device is chosen.
    var routing = EngineRouting()
    private var routingDeviceID: AudioDeviceID?
    var error: String?
    let decks = [DeckModel(id: 0), DeckModel(id: 1)]
    let library = LibraryModel()
    let analysis = AnalysisStore()
    let prep = PrepStore()
    /// Tiny whole-track waveforms for the Organize list.
    let overviews = OverviewStore()
    /// Ratings and notes.
    let meta = TrackMetaStore()
    /// Your own fields on the Organize grid.
    let fields = FieldStore()
    /// The Organize grid's filter, grouping, sort and hidden fields.
    var organizeView = ViewSettings.load() {
        didSet { organizeView.save() }
    }
    var records: RecordContext { RecordContext(library: library, fields: fields, prep: prep, meta: meta) }
    /// The Mix page's queue ("Up next"), remembered between launches.
    var stack: [StackItem] = StackItem.load() {
        didSet { StackItem.save(stack) }
    }
    /// The stack card on each deck (A, B).
    var deckCards: [StackItem?] = [nil, nil]
    /// Cards already played this session, newest first.
    var played: [StackItem] = []
    /// Tracks a deck has played forward for 20 s or more since Spindle
    /// opened (or since Reset): ticked off in the Mix list.
    var playedURLs: Set<URL> = []
    /// Seconds each track has played, until it counts as played.
    var playSeconds: [URL: Double] = [:]
    /// Mix page: selected tab (playlist id, or "all") and each tab's view.
    var mixTab: String = UserDefaults.standard.string(forKey: "mix.tab") ?? "all" {
        didSet { UserDefaults.standard.set(mixTab, forKey: "mix.tab") }
    }
    var mixTabViews: [String: ViewSettings] = {
        guard let data = UserDefaults.standard.data(forKey: "mix.tabViews"),
              let v = try? JSONDecoder().decode([String: ViewSettings].self, from: data) else { return [:] }
        return v
    }() {
        didSet { if let data = try? JSONEncoder().encode(mixTabViews) { UserDefaults.standard.set(data, forKey: "mix.tabViews") } }
    }
    var mixSelection = Set<URL>()

    /// Saved views (templates of filter, group, sort and hidden fields).
    var savedViews: [SavedView] = SavedView.loadAll() {
        didSet { SavedView.saveAll(savedViews) }
    }
    /// The saved view in use, if any.
    var currentViewID: UUID? = UserDefaults.standard.string(forKey: "organize.currentView").flatMap(UUID.init) {
        didSet { UserDefaults.standard.set(currentViewID?.uuidString, forKey: "organize.currentView") }
    }
    let prepPage = PrepPageModel()
    let sessions = SessionStore()
    let midi = MIDIController()
    /// Background cue suggestion for the library.
    var preparing = 0
    /// The clip selected in the Mix grid (MIDI "load highlighted clip").
    var highlightedClip: URL?
    /// The set open in Organize's right panel (its tracks are greyed in the list).
    var openSet: UUID? = UserDefaults.standard.string(forKey: "organize.openSet").flatMap(UUID.init) {
        didSet { UserDefaults.standard.set(openSet?.uuidString, forKey: "organize.openSet") }
    }
    /// Tracks selected on the Organize page.
    var organizeSelection = Set<URL>()
    /// Remembered between launches.
    var page: Page = Page(rawValue: UserDefaults.standard.string(forKey: "page") ?? "") ?? .mix {
        didSet {
            UserDefaults.standard.set(page.rawValue, forKey: "page")
            if page == .prep, let url = prepPage.selected, prepPage.waveform == nil, !prepPage.loading { analyzeForPrep(url) }
        }
    }

    enum Page: String, CaseIterable, Identifiable {
        case organize = "Organize", prep = "Mark", mix = "Mix", sessions = "Sessions"
        var id: String { rawValue }
        var available: Bool { true }
    }

    /// Scans the music folder, then analyses anything new.
    func refreshLibrary() async {
        await library.rescan()
        await analysis.analyze(library.allTracks.map(\.url))
        await prepareAll()
        await regridIfNeeded()
        await fixBreakTemposOnce()
        clearSuggestedCuesOnce()
        makeTempoGroupsOnce()
    }

    /// Once: the genre groups plus fresh automatic groups (4%, half/double
    /// time), from the analysed BPMs.
    func makeTempoGroupsOnce() {
        let key = "tempoGroups4pctB"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let bpms = library.allTracks.compactMap { analysis.analysis(for: $0.url)?.bpm }
        guard !bpms.isEmpty else { return }
        library.tags.makeGenreGroups()
        library.tags.makeTempoGroups(bpms: bpms)
        UserDefaults.standard.set(true, forKey: key)
        spindleLog.notice("Tempo groups: \(self.library.tags.tempoGroups.map { "\($0.name) (\(self.library.tracks(withTag: $0.id).count))" }.joined(separator: ", "))")
    }

    /// You place cues and loop slots yourself: once, clear the ones Spindle
    /// suggested (and any others), keeping a copy of the prep file first.
    private func clearSuggestedCuesOnce() {
        guard !UserDefaults.standard.bool(forKey: "cuesCleared") else { return }
        let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Spindle/prep.json")
        let copy = SafeWrite.backupFolder.appendingPathComponent("prep before clearing cues.json")
        try? FileManager.default.copyItem(at: file, to: copy)
        let n = prep.clearAllCuesAndLoops()
        UserDefaults.standard.set(true, forKey: "cuesCleared")
        spindleLog.notice("Cleared cues and loop slots on \(n) tracks (copy: \(copy.lastPathComponent))")
    }
    /// The deck whose Load… button opened the file picker. There is one picker
    /// for the window: SwiftUI only runs one `.fileImporter` among sibling views.
    var importTarget: DeckModel?
    var showingImporter = false
    var showingMIDI = false

    func chooseFile(for deck: DeckModel) {
        spindleLog.notice("Load… clicked on deck \(deck.label)")
        importTarget = deck
        showingImporter = true
    }

    var selectedDevice: AudioDevice? { devices.first { $0.id == selectedDeviceID } }

    init() {
        refreshDevices()
        // Turntables when the Xone is there; otherwise play from the laptop.
        if UserDefaults.standard.string(forKey: "control") == nil || controlMode == .vinyl {
            controlMode = (selectedDevice?.isXone ?? false) ? .vinyl : .laptop
        }
        setupMIDI()
        let analysis = analysis
        library.analysisLookup = { analysis.analysis(for: $0) }
        let prep = prep
        library.isPrepped = { prep.prep(for: $0)?.mixReady == true }
        library.isColored = { [meta] in meta.color($0) != nil }
    }

    func refreshDevices() {
        devices = AudioDevices.all()
        if selectedDeviceID == nil || selectedDevice == nil {
            selectedDeviceID = devices.first(where: \.isXone)?.id
                ?? AudioDevices.defaultOutput()
                ?? devices.first?.id
        }
    }

    func start() async {
        stop()
        error = nil
        // A device that was unplugged and plugged back in gets a new number
        // from macOS: find it again by name (else the Xone if it's there).
        let wanted = selectedDevice?.name
        devices = AudioDevices.all()
        if selectedDevice == nil {
            selectedDeviceID = devices.first(where: { $0.name == wanted })?.id
                ?? devices.first(where: \.isXone)?.id
                ?? AudioDevices.defaultOutput()
        }
        spindleLog.notice("Start: device \(selectedDevice?.name ?? "none"), control \(controlMode.rawValue), vinyl A \(decks[0].vinyl.id), B \(decks[1].vinyl.id)")
        guard let device = selectedDevice.flatMap({ AudioDevices.device($0.id) }) else {
            error = "No audio device selected."
            return
        }
        if controlMode == .vinyl && device.inputChannels >= 2 {
            let status = AVCaptureDevice.authorizationStatus(for: .audio)
            spindleLog.notice("Audio input permission: \(status.rawValue) (0 not asked, 1 restricted, 2 denied, 3 allowed)")
            if status != .authorized {
                error = "Waiting for permission to read the turntables: click Allow in the macOS dialog (it may be behind this window)."
            }
            let granted = status == .authorized ? true : await AVCaptureDevice.requestAccess(for: .audio)
            if granted { error = nil }
            spindleLog.notice("Audio input granted: \(granted)")
            if !granted {
                spindleLog.error("Audio input access denied")
                error = "Spindle needs audio input access to read the turntables. Allow it in System Settings › Privacy & Security › Microphone."
                return
            }
        }
        if routingDeviceID != device.id {
            routing = savedRouting(for: device) ?? EngineRouting.defaults(for: device)
            routingDeviceID = device.id
        }
        let definitions = decks.map(\.vinyl)
        let simulate = simulate
        let laptop = controlMode == .laptop
        let routing = routing
        // Building the 32 MB position table takes a moment; keep it off the main thread.
        spindleLog.notice("Building engine")
        let core = await Task.detached {
            for d in definitions { _ = TimecodeLookup.shared(for: d) }
            return AudioEngineCore(device: device, definitions: definitions, simulate: simulate, laptop: laptop, routing: routing)
        }.value
        do {
            try core.start()
            spindleLog.notice("Engine running: \(core.sampleRate) Hz, buffer \(core.bufferFrames), simulate \(core.simulate), laptop \(core.laptop)")
        } catch {
            spindleLog.error("Engine failed: \(error.localizedDescription)")
            self.error = error.localizedDescription
            return
        }
        engine = core
        running = true
        updateGains()
        rememberLocks()
        monitorDecks()
        core.recordInput = recordInputDefault(for: core)
        for deck in decks {
            core.decks[deck.id].absoluteMode = deck.absoluteMode
            if let config = deck.preferredConfig(for: deck.vinyl) { core.decks[deck.id].prefer(config: config) }
            core.decks[deck.id].startIndex = deck.startIndex(for: deck.vinyl) ?? 0
            core.decks[deck.id].startKnown = deck.startIndex(for: deck.vinyl) != nil
            core.decks[deck.id].toneFrequency = deck.id == 0 ? 440 : 660
            core.decks[deck.id].testTone = deck.testTone
            for kind in FXKind.allCases { core.decks[deck.id].setFX(kind, deck.fx[kind]) }
            if let url = deck.track?.url, let p = prep.prep(for: url) {
                core.decks[deck.id].beatSeconds = p.beatSeconds
                core.decks[deck.id].gridOffset = p.gridOffset
                core.decks[deck.id].gridBeat = p.beatSeconds
            }
            core.simulators[deck.id].targetPitch = deck.simulatedPitch
            deck.transportPlaying = false
            core.decks[deck.id].transportPlaying = false
            core.decks[deck.id].tempo = 1 + deck.tempo
            if let track = deck.track {
                if track.samples.pointee.sampleRate == core.sampleRate {
                    _ = core.decks[deck.id].exchangeTrack(track.samples)
                } else {
                    deck.track = nil
                    Task { await load(url: track.url, into: deck) }
                }
            }
        }
        attachPreview()
    }

    func stop() {
        guard let engine else { return }
        engine.stop()
        for deck in engine.decks { _ = deck.exchangeTrack(nil) }
        _ = engine.preview.exchangeTrack(nil)
        prepPage.playing = false
        self.engine = nil
        running = false
    }

    func load(url: URL, into deck: DeckModel, fromStack: Bool = false) async {
        spindleLog.notice("Loading \(url.lastPathComponent) into deck \(deck.label)")
        deck.loading = true
        deck.error = nil
        defer { deck.loading = false }
        let rate = engine?.sampleRate ?? selectedDevice?.sampleRate ?? 48000
        do {
            let track = try await TrackLoader.load(url: url, sampleRate: rate)
            let old = deck.track
            deck.track = track
            _ = engine?.decks[deck.id].exchangeTrack(track.samples)
            if let old { retire(old.samples) }
            applyClip(track.url, to: deck)
            setPlaying(false, deck: deck)
            if !fromStack { noteLoaded(url, deck: deck) }
            spindleLog.notice("Deck \(deck.label) loaded \(track.title), \(track.duration) s, engine \(self.engine == nil ? "off" : "on")")
        } catch {
            spindleLog.error("Deck \(deck.label) failed: \(error.localizedDescription)")
            deck.error = error.localizedDescription
        }
    }

    func setSimulatedPitch(_ pitch: Double, deck: DeckModel) {
        deck.simulatedPitch = pitch
        engine?.simulators[deck.id].targetPitch = pitch
    }

    func setAbsolute(_ absolute: Bool, deck: DeckModel) {
        deck.absoluteMode = absolute
        engine?.decks[deck.id].absoluteMode = absolute
    }

    /// Restarts the track from wherever the needle is now.
    func cueToNeedle(deck: DeckModel) {
        engine?.decks[deck.id].cueRequest = true
    }

    /// Once a deck locks, remember which decoder variant did it, so the next
    /// start has the right direction straight away.
    /// Seconds from the record's learned start to the needle (folded as the
    /// decoder does).
    nonisolated static func recordSeconds(_ t: DeckTelemetry, _ def: TimecodeDefinition) -> Double {
        let period = def.positionModulus
        var bits = t.positionIndex - max(t.recordStart, 0)
        if period > 0 {
            bits %= period
            if bits > period / 2 { bits -= period }
            if bits < -period / 2 { bits += period }
        }
        return Double(bits) / def.bitRate
    }

    private func rememberLocks() {
        Task { [weak self] in
            while let self, let core = self.engine, self.running {
                for deck in self.decks {
                    let t = core.decks[deck.id].telemetry.pointee
                    let def = core.decks[deck.id].definition
                    if t.hasPosition, deck.preferredConfig(for: def) != Int(t.activeConfig) {
                        deck.setPreferredConfig(Int(t.activeConfig), for: def)
                    }
                    // Where the track is against the record: log jumps (and the
                    // first second after a load), to see needle drops at work.
                    let last = self.lastPlayhead[deck.id]
                    if let last, abs(t.playhead - last) > 3, let length = deck.track?.duration {
                        spindleLog.notice(String(format: "Deck %@: track jumped %.1f s → %.1f s of %.1f s (record %.1f s from its start, start %@)",
                                                 deck.label, last, t.playhead, length,
                                                 Self.recordSeconds(t, core.decks[deck.id].definition),
                                                 t.recordStart >= 0 ? "learned" : "not learned"))
                    }
                    self.lastPlayhead[deck.id] = t.playhead
                    // Reading the record or not: log each change, with the level.
                    let reading = t.lockHeld
                    if self.readingSeen[deck.id] != reading {
                        self.readingSeen[deck.id] = reading
                        spindleLog.notice(String(format: "Deck %@: %@ (signal %.3f, speed %.2f, %@)", deck.label,
                                                 reading ? "reading the record" : "not reading the record",
                                                 t.signal, t.pitch, core.decks[deck.id].definition.id))
                    }
                    // Lock lost while playing (a lift, a skip): log it, to tune
                    // the lift detection on real records.
                    if t.lostLockEvents != (self.lossSeen[deck.id] ?? 0) {
                        self.lossSeen[deck.id] = t.lostLockEvents
                        spindleLog.notice(String(format: "Deck %@: lock lost while playing, level %.0f%% of before, %@",
                                                 deck.label, t.lastLossRatio * 100, t.lastLossCoasting ? "carried on" : "followed the signal"))
                    }
                    // The record's start, once the deck has learned it.
                    if t.recordStart >= 0, deck.startIndex(for: def) != t.recordStart {
                        deck.setStartIndex(t.recordStart, for: def)
                        spindleLog.notice("Deck \(deck.label): record start learned")
                    }
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func setTestTone(_ on: Bool, deck: DeckModel) {
        deck.testTone = on
        engine?.decks[deck.id].testTone = on
    }

    /// Routing is remembered per device name, so it survives relaunches.
    private func savedRouting(for device: AudioDevice) -> EngineRouting? {
        guard let v = UserDefaults.standard.array(forKey: "routing.\(device.name)") as? [Int], v.count == 4 else { return nil }
        return EngineRouting(inputA: v[0], inputB: v[1], outputA: v[2], outputB: v[3])
    }

    private func saveRouting() {
        guard let name = engine?.device.name else { return }
        UserDefaults.standard.set([routing.inputA, routing.inputB, routing.outputA, routing.outputB], forKey: "routing.\(name)")
    }

    func setInput(_ first: Int, deck: DeckModel) {
        if deck.id == 0 { routing.inputA = first } else { routing.inputB = first }
        engine?.routing = routing
        saveRouting()
    }

    func setOutput(_ first: Int, deck: DeckModel) {
        if deck.id == 0 { routing.outputA = first } else { routing.outputB = first }
        engine?.routing = routing
        saveRouting()
    }

    func seekSimulator(seconds: Double, deck: DeckModel) {
        engine?.simulators[deck.id].seekRequest = seconds
    }

    func setSimulatorLifted(_ lifted: Bool, deck: DeckModel) {
        deck.simulatorLifted = lifted
        engine?.simulators[deck.id].lifted = lifted
    }

    /// Stops a deck that is playing on with the needle up.
    func stopCoasting(deck: DeckModel) {
        engine?.decks[deck.id].stopCoastRequest = true
    }

    /// Frees sample memory once the audio thread has certainly moved on.
    func retire(_ samples: UnsafeMutablePointer<TrackSamples>) {
        let address = Int(bitPattern: samples)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard let pointer = UnsafeMutablePointer<TrackSamples>(bitPattern: address) else { return }
            pointer.pointee.free()
            pointer.deallocate()
        }
    }
}

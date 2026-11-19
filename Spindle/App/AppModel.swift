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
    var absoluteMode = true
    var testTone = false

    init(id: Int) { self.id = id }

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

let spindleLog = DiagnosticLog()

@Observable
final class AppModel {
    var devices: [AudioDevice] = []
    var selectedDeviceID: AudioDeviceID?
    var definition: TimecodeDefinition = .traktorMK2
    var simulate = false
    private(set) var engine: AudioEngineCore?
    private(set) var running = false
    /// Stereo pair per deck (first channel, 0-based). Nil until a device is chosen.
    var routing = EngineRouting()
    private var routingDeviceID: AudioDeviceID?
    var error: String?
    let decks = [DeckModel(id: 0), DeckModel(id: 1)]
    let library = LibraryModel()
    let analysis = AnalysisStore()
    /// Remembered between launches.
    var page: Page = Page(rawValue: UserDefaults.standard.string(forKey: "page") ?? "") ?? .mix {
        didSet { UserDefaults.standard.set(page.rawValue, forKey: "page") }
    }

    enum Page: String, CaseIterable, Identifiable {
        case organize = "Organize", prep = "Prep", mix = "Mix", sessions = "Sessions"
        var id: String { rawValue }
        /// Pages built so far (build order in CLAUDE.md).
        var available: Bool { self == .organize || self == .mix }
    }

    /// Scans the music folder, then analyses anything new.
    func refreshLibrary() async {
        await library.rescan()
        await analysis.analyze(library.tracks.map(\.url))
    }
    /// The deck whose Load… button opened the file picker. There is one picker
    /// for the window: SwiftUI only runs one `.fileImporter` among sibling views.
    var importTarget: DeckModel?
    var showingImporter = false

    func chooseFile(for deck: DeckModel) {
        spindleLog.notice("Load… clicked on deck \(deck.label)")
        importTarget = deck
        showingImporter = true
    }

    var selectedDevice: AudioDevice? { devices.first { $0.id == selectedDeviceID } }

    init() {
        refreshDevices()
        simulate = !(selectedDevice?.isXone ?? false)
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
        spindleLog.notice("Start: device \(selectedDevice?.name ?? "none"), simulate \(simulate), vinyl \(definition.id)")
        guard let device = selectedDevice.flatMap({ AudioDevices.device($0.id) }) else {
            error = "No audio device selected."
            return
        }
        if !simulate && device.inputChannels >= 2 {
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
        let definition = definition
        let simulate = simulate
        let routing = routing
        // Building the 32 MB position table takes a moment; keep it off the main thread.
        spindleLog.notice("Building engine")
        let core = await Task.detached {
            _ = TimecodeLookup.shared(for: definition)
            return AudioEngineCore(device: device, definition: definition, simulate: simulate, routing: routing)
        }.value
        do {
            try core.start()
            spindleLog.notice("Engine running: \(core.sampleRate) Hz, buffer \(core.bufferFrames), simulate \(core.simulate)")
        } catch {
            spindleLog.error("Engine failed: \(error.localizedDescription)")
            self.error = error.localizedDescription
            return
        }
        engine = core
        running = true
        rememberLocks()
        for deck in decks {
            core.decks[deck.id].absoluteMode = deck.absoluteMode
            if let config = deck.preferredConfig(for: definition) { core.decks[deck.id].prefer(config: config) }
            core.decks[deck.id].startIndex = deck.startIndex(for: definition) ?? 0
            core.decks[deck.id].toneFrequency = deck.id == 0 ? 440 : 660
            core.decks[deck.id].testTone = deck.testTone
            core.simulators[deck.id].targetPitch = deck.simulatedPitch
            if let track = deck.track {
                if track.samples.pointee.sampleRate == core.sampleRate {
                    _ = core.decks[deck.id].exchangeTrack(track.samples)
                } else {
                    deck.track = nil
                    Task { await load(url: track.url, into: deck) }
                }
            }
        }
    }

    func stop() {
        guard let engine else { return }
        engine.stop()
        for deck in engine.decks { _ = deck.exchangeTrack(nil) }
        self.engine = nil
        running = false
    }

    func load(url: URL, into deck: DeckModel) async {
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
    private func rememberLocks() {
        Task { [weak self] in
            while let self, let core = self.engine, self.running {
                for deck in self.decks {
                    let t = core.decks[deck.id].telemetry.pointee
                    if t.hasPosition, deck.preferredConfig(for: core.definition) != Int(t.activeConfig) {
                        deck.setPreferredConfig(Int(t.activeConfig), for: core.definition)
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

    /// Frees sample memory once the audio thread has certainly moved on.
    private func retire(_ samples: UnsafeMutablePointer<TrackSamples>) {
        let address = Int(bitPattern: samples)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard let pointer = UnsafeMutablePointer<TrackSamples>(bitPattern: address) else { return }
            pointer.pointee.free()
            pointer.deallocate()
        }
    }
}

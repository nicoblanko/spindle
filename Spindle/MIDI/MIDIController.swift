//
//  MIDIController.swift
//  Spindle
//
//  MIDI learn for controllers such as the Akai MPK mini or a DJ controller
//  (AlphaTheta Omnis-Duo): pick an action, press a pad or turn a knob, and
//  it is mapped. Pads (notes or CC presses) trigger; knobs set a value.
//  Absolute knobs only take over a value once they reach it (soft
//  takeover); until then the mapping shows how far off it is. Jog wheels
//  and the browse knob are relative (they send steps, not a position), and
//  jog touch and CUE also act on release.
//
//  "Log MIDI" in MIDI mapping (or SPINDLE_MIDILOG=1) writes every incoming
//  message to ~/Library/Logs/spindle.log, to map a controller from what it
//  really sends.
//

import CoreMIDI
import Foundation
import Observation

nonisolated enum MIDIAction: String, Codable, Sendable, CaseIterable {
    case play, cueButton, sync, tempo, volume
    case cue1, cue2, cue3, cue4, loop, loopHalve, loopDouble, filter, echo, loadSelected
    case record, crossfader
    case jogTouch, jogTurn, jogRing, browse

    var isContinuous: Bool { [.filter, .echo, .tempo, .volume, .crossfader].contains(self) }
    /// Knobs whose range is −1…1 (centre = off).
    var bipolar: Bool { [.filter, .tempo, .crossfader].contains(self) }
    /// Send steps (relative encoders): the handler gets the step count.
    var isRelative: Bool { [.jogTurn, .jogRing, .browse].contains(self) }
    /// Act on press (1) and on release (0).
    var isMomentary: Bool { [.jogTouch, .cueButton].contains(self) }
    var perDeck: Bool { ![.record, .crossfader, .browse].contains(self) }

    var name: String {
        switch self {
        case .play: "Play/pause (laptop)"
        case .cueButton: "CUE (laptop; hold at the cue to preview)"
        case .sync: "Sync (laptop)"
        case .tempo: "Tempo (laptop)"
        case .volume: "Volume (laptop)"
        case .crossfader: "Crossfader (laptop)"
        case .cue1: "Cue 1 · IN"
        case .cue2: "Cue 2 · DROP"
        case .cue3: "Cue 3 · BRK"
        case .cue4: "Cue 4 · OUT"
        case .loop: "Loop on/off"
        case .loopHalve: "Loop ÷2"
        case .loopDouble: "Loop ×2"
        case .filter: "Filter"
        case .echo: "Echo"
        case .loadSelected: "Load highlighted clip"
        case .record: "Record on/off"
        case .jogTouch: "Jog touch (hold to scratch)"
        case .jogTurn: "Jog turn (scratch when touched)"
        case .jogRing: "Jog outer ring (bend / search)"
        case .browse: "Browse knob (Mix list)"
        }
    }
}

nonisolated struct MIDITarget: Codable, Sendable, Hashable, Identifiable {
    var deck: Int?
    var action: MIDIAction
    var id: String { "\(deck.map(String.init) ?? "-").\(action.rawValue)" }
    var label: String { (deck.map { $0 == 0 ? "Deck A · " : "Deck B · " } ?? "") + action.name }

    static var all: [MIDITarget] {
        var list: [MIDITarget] = []
        for deck in [0, 1] {
            for action in MIDIAction.allCases where action.perDeck { list.append(MIDITarget(deck: deck, action: action)) }
        }
        list.append(MIDITarget(deck: nil, action: .crossfader))
        list.append(MIDITarget(deck: nil, action: .browse))
        list.append(MIDITarget(deck: nil, action: .record))
        return list
    }
}

/// A MIDI control: note or CC number on a channel.
nonisolated struct MIDIControl: Codable, Sendable, Hashable {
    var isNote: Bool
    var channel: Int
    var number: Int
    var label: String { "\(isNote ? "Note" : "CC") \(number) · ch \(channel + 1)" }
}

@Observable
final class MIDIController {
    private(set) var bindings: [MIDITarget: MIDIControl] = [:]
    /// Waiting for a control to map to this target.
    var learning: MIDITarget?
    private(set) var sources: [String] = []
    private(set) var lastMessage: String = ""
    /// For continuous targets: the knob's position while it hasn't caught up.
    private(set) var pickup: [MIDITarget: Double] = [:]
    /// Called on the main actor for mapped controls: target and value 0…1.
    var handler: ((MIDITarget, Double) -> Void)?
    /// Jog calibration: while on, jog steps are counted instead of moving
    /// the track (turn the wheel exactly once, then finish).
    private(set) var calibratingJog = false
    private(set) var calibrationSteps = 0
    /// Steps per turn of the jog wheels (shared with AppModel.jogStepsPerTurn).
    var jogStepsPerTurn: Double {
        get { UserDefaults.standard.object(forKey: "jog.stepsPerTurn") as? Double ?? 720 }
        set { UserDefaults.standard.set(min(max(newValue, 32), 8192), forKey: "jog.stepsPerTurn") }
    }

    func startJogCalibration() { calibrationSteps = 0; calibratingJog = true }

    func finishJogCalibration() {
        calibratingJog = false
        if abs(calibrationSteps) >= 32 { jogStepsPerTurn = Double(abs(calibrationSteps)) }
    }

    /// Current value of a continuous target (0…1), for soft takeover.
    var currentValue: ((MIDITarget) -> Double)?

    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private var engaged: Set<MIDITarget> = []
    private static let storeKey = "midi.bindings"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.storeKey),
           let list = try? JSONDecoder().decode([Pair].self, from: data) {
            bindings = Dictionary(uniqueKeysWithValues: list.map { ($0.target, $0.control) })
        }
    }

    private struct Pair: Codable { var target: MIDITarget; var control: MIDIControl }

    func start() {
        guard client == 0 else { return }
        let status = MIDIClientCreateWithBlock("Spindle" as CFString, &client) { [weak self] _ in
            DispatchQueue.main.async { self?.connectSources() }
        }
        guard status == noErr else { spindleLog.error("MIDI client failed: \(status)"); return }
        MIDIInputPortCreateWithProtocol(client, "Spindle in" as CFString, ._1_0, &port) { [weak self] list, _ in
            var messages: [(UInt8, UInt8, UInt8)] = []
            for packet in list.unsafeSequence() {
                let words = MIDIEventPacket.WordCollection(packet)
                for word in words where word >> 28 == 0x2 {          // MIDI 1.0 channel voice
                    messages.append((UInt8((word >> 16) & 0xff), UInt8((word >> 8) & 0x7f), UInt8(word & 0x7f)))
                }
            }
            guard !messages.isEmpty else { return }
            DispatchQueue.main.async {
                for m in messages { self?.receive(status: m.0, data1: m.1, data2: m.2) }
            }
        }
        connectSources()
    }

    private func connectSources() {
        var names: [String] = []
        for i in 0..<MIDIGetNumberOfSources() {
            let source = MIDIGetSource(i)
            MIDIPortConnectSource(port, source, nil)
            var name: Unmanaged<CFString>?
            if MIDIObjectGetStringProperty(source, kMIDIPropertyDisplayName, &name) == noErr, let name {
                names.append(name.takeRetainedValue() as String)
            }
        }
        sources = names
        spindleLog.notice("MIDI sources: \(names.joined(separator: ", "))")
    }

    func clear(_ target: MIDITarget) {
        bindings[target] = nil
        save()
    }

    private func save() {
        let list = bindings.map { Pair(target: $0.key, control: $0.value) }
        if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: Self.storeKey) }
    }

    /// Every incoming message goes to the log (MIDI mapping's "Log MIDI").
    var logAll = ProcessInfo.processInfo.environment["SPINDLE_MIDILOG"] != nil
        || UserDefaults.standard.bool(forKey: "midi.log") {
        didSet {
            UserDefaults.standard.set(logAll, forKey: "midi.log")
            if logAll { spindleLog.notice("MIDI log on · sources: \(sources.joined(separator: ", "))") }
        }
    }

    /// A relative encoder step: centred on 64 (Pioneer/AlphaTheta jogs:
    /// 65 = +1, 63 = −1) or two's complement (1 = +1, 127 = −1).
    nonisolated static func steps(_ value: UInt8) -> Int {
        let v = Int(value)
        if abs(v - 64) < 32 { return v - 64 }
        return v < 64 ? v : v - 128
    }

    private func receive(status: UInt8, data1: UInt8, data2: UInt8) {
        let kind = status & 0xf0
        let channel = Int(status & 0x0f)
        if logAll { spindleLog.notice(String(format: "MIDI %02X %02X %02X", status, data1, data2)) }
        let control: MIDIControl
        var pressed = false
        var value = Double(data2) / 127
        switch kind {
        case 0x80, 0x90:
            control = MIDIControl(isNote: true, channel: channel, number: Int(data1))
            pressed = kind == 0x90 && data2 > 0
        case 0xb0:
            control = MIDIControl(isNote: false, channel: channel, number: Int(data1)); pressed = data2 > 63
        default:
            return
        }
        lastMessage = control.label + " = \(data2)"

        if let target = learning {
            // Learn on a press or a turn, never on a release.
            if control.isNote && !pressed { return }
            // A knob for a knob target, anything for a button target.
            if (target.action.isContinuous || target.action.isRelative) && control.isNote { return }
            for (t, c) in bindings where c == control { bindings[t] = nil }
            bindings[target] = control
            engaged.remove(target)
            learning = nil
            save()
            return
        }

        for (target, bound) in bindings where bound == control {
            if target.action.isRelative {
                let steps = Self.steps(data2)
                if calibratingJog && target.action != .browse {
                    calibrationSteps += steps
                    continue
                }
                if steps != 0 { handler?(target, Double(steps)) }
                continue
            }
            if target.action.isMomentary {
                handler?(target, pressed ? 1 : 0)
                continue
            }
            if target.action.isContinuous {
                if target.action.bipolar { value = value * 2 - 1 }
                let current = currentValue?(target) ?? value
                // Soft takeover: wait until the knob reaches the current value.
                if !engaged.contains(target) {
                    let previous = pickup[target]
                    let crossed = previous.map { ($0 - current) * (value - current) <= 0 } ?? false
                    if abs(value - current) < 0.04 || crossed {
                        engaged.insert(target)
                        pickup[target] = nil
                    } else {
                        pickup[target] = value
                        continue
                    }
                }
                handler?(target, value)
            } else if pressed {
                handler?(target, 1)
            }
        }
    }

    /// The value was changed elsewhere (mouse, clip load): the knob must
    /// catch up again before it takes over.
    func release(_ target: MIDITarget) {
        engaged.remove(target)
    }
}

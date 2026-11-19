//
//  MIDIController.swift
//  Spindle
//
//  MIDI learn for controllers such as the Akai MPK mini: pick an action,
//  press a pad or turn a knob, and it is mapped. Pads (notes or CC presses)
//  trigger; knobs set a value. The MPK mini's knobs are absolute, so a knob
//  only takes over a value once it reaches it (soft takeover); until then
//  the mapping shows how far off it is.
//

import CoreMIDI
import Foundation
import Observation

nonisolated enum MIDIAction: String, Codable, Sendable, CaseIterable {
    case cue1, cue2, cue3, cue4, loop, loopHalve, loopDouble, filter, echo, loadSelected
    case record

    var isContinuous: Bool { self == .filter || self == .echo }
    var perDeck: Bool { self != .record }

    var name: String {
        switch self {
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

    private func receive(status: UInt8, data1: UInt8, data2: UInt8) {
        let kind = status & 0xf0
        let channel = Int(status & 0x0f)
        let control: MIDIControl
        var pressed = false
        var value = Double(data2) / 127
        switch kind {
        case 0x90 where data2 > 0:
            control = MIDIControl(isNote: true, channel: channel, number: Int(data1)); pressed = true
        case 0x80, 0x90:
            return                                                  // note off
        case 0xb0:
            control = MIDIControl(isNote: false, channel: channel, number: Int(data1)); pressed = data2 > 63
        default:
            return
        }
        lastMessage = control.label + " = \(data2)"

        if let target = learning {
            // A knob for a knob target, anything for a button target.
            if target.action.isContinuous && control.isNote { return }
            for (t, c) in bindings where c == control { bindings[t] = nil }
            bindings[target] = control
            engaged.remove(target)
            learning = nil
            save()
            return
        }

        for (target, bound) in bindings where bound == control {
            if target.action.isContinuous {
                if target.action == .filter { value = value * 2 - 1 }
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

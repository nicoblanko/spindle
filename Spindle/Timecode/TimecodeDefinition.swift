//
//  TimecodeDefinition.swift
//  Spindle
//
//  The Traktor Scratch MK1 signal: a 2 kHz stereo sine carrier with the two
//  channels 90° apart (so direction can be read from their order), whose
//  amplitude carries one bit per cycle. The bits come from a 23-bit linear
//  feedback shift register (LFSR), so any 23 consecutive bits identify a
//  unique place on the record.
//
//  Traktor Scratch MK2 (the vinyl Spindle is used with) is different: a 2.5 kHz
//  carrier whose level is shifted up or down. Every 5 cycles form a frame: a
//  2-cycle part and a 3-cycle part, each at one of two levels. The 3-cycle
//  levels, one bit per frame (500 bits/s), follow a 22-bit LFSR:
//      b[n] = b[n−8] ⊕ b[n−14] ⊕ b[n−15] ⊕ b[n−22]
//  which runs through all 4,194,303 states. This was measured from recordings
//  of the actual records (Berlekamp–Massey on the decoded levels), not taken
//  from any other implementation. Where the record starts in that sequence is
//  calibrated per deck (see DeckEngine.startIndex). The 2-cycle parts carry
//  the same sequence 2^21 bits later.
//
//  The MK1 parameters are facts about the published format. No code from xwax
//  or Mixxx (both GPL) is copied into Spindle.
//

import Foundation

nonisolated struct TimecodeDefinition: Sendable, Hashable, Identifiable {
    let id: String
    let name: String
    /// Carrier cycles per second at 33⅓ rpm and 0% pitch. One bit per cycle.
    let resolution: Double
    let bits: Int
    let seed: UInt32
    let taps: UInt32
    /// Number of cycles (bits) pressed on this side.
    let length: Int
    /// MK2 shifts the carrier up and down (offset steps) instead of changing its
    /// amplitude, and carries one bit per 5-cycle frame.
    var offsetModulated = false
    /// Carrier cycles per bit: 1 for MK1, 5 for MK2.
    var cyclesPerBit = 1

    /// Whether Spindle can read absolute position from this format.
    var decodesPosition: Bool { length > 0 }

    /// Positions repeat with this period. For MK2 the 2-cycle and 3-cycle parts
    /// of each frame carry the same sequence exactly 2^21 bits apart, and a
    /// decoder may read either; folding by 2^21 (70 minutes, far longer than a
    /// side) makes both readings the same position.
    var positionModulus: Int { offsetModulated ? 1 << 21 : length }

    /// Bits per second at 0% pitch.
    var bitRate: Double { resolution / Double(cyclesPerBit) }

    /// Traktor Scratch MK2. `seed` is only a reference point in the sequence;
    /// the record's own start is calibrated.
    static let traktorMK2 = TimecodeDefinition(
        id: "traktor_mk2", name: "Traktor MK2 (both sides)",
        resolution: 2500, bits: 22, seed: 1, taps: 0x4180, length: 4_194_303,
        offsetModulated: true, cyclesPerBit: 5)

    static let traktorA = TimecodeDefinition(
        id: "traktor_a", name: "Traktor MK1, first edition · side A",
        resolution: 2000, bits: 23, seed: 0x134503, taps: 0x041040, length: 1_500_000)

    static let traktorB = TimecodeDefinition(
        id: "traktor_b", name: "Traktor MK1, first edition · side B",
        resolution: 2000, bits: 23, seed: 0x32066c, taps: 0x041040, length: 2_110_000)

    // Serato Control Vinyl (2nd edition) and CD. The code's parameters
    // (seed, taps, length) are as listed in xwax's timecoder.c.
    static let seratoA = TimecodeDefinition(
        id: "serato_2a", name: "Serato CV02 · side A",
        resolution: 1000, bits: 20, seed: 0x59017, taps: 0x361e4, length: 712_000)

    static let seratoB = TimecodeDefinition(
        id: "serato_2b", name: "Serato CV02 · side B",
        resolution: 1000, bits: 20, seed: 0x8f3c6, taps: 0x4f0d8, length: 922_000)

    static let seratoCD = TimecodeDefinition(
        id: "serato_cd", name: "Serato CD",
        resolution: 1000, bits: 20, seed: 0xd8b40, taps: 0x34d54, length: 950_000)

    static let all: [TimecodeDefinition] = [.traktorMK2, .traktorA, .traktorB, .seratoA, .seratoB, .seratoCD]

    static func named(_ id: String?) -> TimecodeDefinition? { all.first { $0.id == id } }

    var mask: UInt32 { (UInt32(1) << UInt32(bits)) - 1 }

    /// The register state one cycle further into the record. The new bit enters at the MSB.
    @inline(__always)
    func forward(_ code: UInt32) -> UInt32 {
        let bit = UInt32((code & (taps | 1)).nonzeroBitCount & 1)
        return (code >> 1) | (bit << UInt32(bits - 1))
    }

    /// The exact inverse of `forward`: one cycle back towards the lead-in.
    @inline(__always)
    func reverse(_ code: UInt32) -> UInt32 {
        let bit = UInt32((code & ((taps >> 1) | (UInt32(1) << UInt32(bits - 1)))).nonzeroBitCount & 1)
        return ((code << 1) & mask) | bit
    }

    /// The bit pressed into cycle `code` (the newest bit, at the MSB).
    @inline(__always)
    func bit(of code: UInt32) -> Bool {
        (code >> UInt32(bits - 1)) & 1 == 1
    }
}

/// Maps a register state to its cycle index on the record. 2^23 entries (32 MB),
/// built once per side and shared by every decoder.
nonisolated final class TimecodeLookup: @unchecked Sendable {
    let definition: TimecodeDefinition
    private let table: UnsafeMutablePointer<Int32>
    private let mask: UInt32

    private init(definition: TimecodeDefinition) {
        self.definition = definition
        let size = 1 << definition.bits
        mask = definition.mask
        table = .allocate(capacity: size)
        table.initialize(repeating: -1, count: size)
        var code = definition.seed
        for index in 0..<definition.length {
            table[Int(code)] = Int32(index)
            code = definition.forward(code)
        }
    }

    deinit { table.deallocate() }

    /// Cycle index of `code` on the record, or -1 if this state is not pressed on it.
    @inline(__always)
    func index(of code: UInt32) -> Int {
        Int(table[Int(code & mask)])
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: TimecodeLookup] = [:]

    static func shared(for definition: TimecodeDefinition) -> TimecodeLookup {
        lock.lock()
        defer { lock.unlock() }
        if let existing = cache[definition.id] { return existing }
        let lookup = TimecodeLookup(definition: definition)
        cache[definition.id] = lookup
        return lookup
    }
}

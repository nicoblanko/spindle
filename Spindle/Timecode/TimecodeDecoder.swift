//
//  TimecodeDecoder.swift
//  Spindle
//
//  Turns one deck's stereo timecode signal into speed, direction and position.
//  Runs on the audio thread: no allocation, no locks after init.
//
//  Speed and direction (both formats)
//  • The two channels are 90° apart, so the angle of the (primary, secondary)
//    vector turns once per carrier cycle. Its smoothed rate is the speed and
//    its sign the direction.
//
//  Position, MK1
//  • When the secondary channel crosses zero the primary is at its peak. That
//    peak, compared with a running average, is the cycle's bit.
//
//  Position, MK2
//  • Each completed carrier cycle's average level (before the offset filter,
//    left + right) is compared with the previous one. A clear jump is an edge; its sign is
//    the new level.
//  • Edges only fall on 2 of every 5 cycles, which gives the frame grid. The
//    level in the middle of each frame's 3-cycle part is that frame's bit.
//
//  Both: bits go into a shift register. Once 24 in a row match the LFSR's
//  prediction, the register is looked up for the position.
//
//  Channel order, phase and (MK1) bit polarity or (MK2) cycle alignment vary
//  with format and cabling, so the deck runs every combination
//  (`DecoderConfig.all`) in parallel and follows whichever one locks.
//

import Foundation

nonisolated struct DecoderConfig: Sendable, Hashable {
    var swapChannels: Bool
    var invertPhase: Bool
    /// MK1: read the bit on the rising crossing. MK2: low bit of the cycle alignment.
    var readOnRising: Bool
    /// MK1: a loud cycle is 0. MK2: high bit of the cycle alignment.
    var invertBits: Bool

    static let all: [DecoderConfig] = (0..<16).map { i in
        DecoderConfig(swapChannels: i & 1 != 0, invertPhase: i & 2 != 0,
                      readOnRising: i & 4 != 0, invertBits: i & 8 != 0)
    }

    /// MK2: where cycle boundaries fall, in quarter cycles.
    var alignment: Int { (readOnRising ? 1 : 0) + (invertBits ? 2 : 0) }

    var label: String {
        [swapChannels ? "R/L" : "L/R",
         invertPhase ? "ph−" : "ph+",
         readOnRising ? "rd↑" : "rd↓",
         invertBits ? "bit−" : "bit+"].joined(separator: " ")
    }
}

nonisolated final class TimecodeDecoder {
    let config: DecoderConfig
    let definition: TimecodeDefinition
    private let lookup: TimecodeLookup
    private let sampleRate: Double

    // Signal conditioning
    private var zeroP: Float = 0
    private var zeroS: Float = 0
    private let zeroAlpha: Float = 0.0001
    private var primaryPositive = false
    private var secondaryPositive = false
    private let envelopeDecay: Float
    /// Peak level of the carrier (0…1 full scale), decaying over ~50 ms.
    private(set) var envelope: Float = 0

    // Speed
    private var lastAngle: Float = 0
    /// Smoothed rotation in radians per sample.
    private var angleRate: Double = 0
    private let angleAlpha: Double
    /// Playback speed: 1.0 is 33⅓ rpm at 0%, negative is backwards.
    private(set) var pitch: Double = 0
    private(set) var forwards = true

    // Position
    private var bitstream: UInt32 = 0
    private var timecode: UInt32 = 0
    private var refLevel: Float = 0
    private(set) var validBits = 0
    /// Bit index of the needle in the format's sequence, or -1.
    private(set) var positionIndex = -1
    private var samplesSinceBit: Double = 0

    // MK2 cycle and frame tracking
    private var phaseCycles: Double = 0
    private var currentCycle = 0
    private var cycleSum: Double = 0
    private var cycleCount = 0
    private var previousMean: Double = 0
    private var hasPreviousMean = false
    private var level = false
    private var edgeVotes: (Float, Float, Float, Float, Float) = (0, 0, 0, 0, 0)
    private var frameOffset = 0
    private var cyclesSinceVoteDecay = 0

    static let lockBits = 24
    /// Consecutive mismatching bits tolerated while locked.
    static let flywheelBits = 4
    private var misses = 0
    /// Counts lock acquisitions, so a fresh lock can be told from one that
    /// is still held from before the needle was lifted.
    private(set) var lockSerial = 0

    init(config: DecoderConfig, definition: TimecodeDefinition, sampleRate: Double) {
        self.config = config
        self.definition = definition
        self.lookup = TimecodeLookup.shared(for: definition)
        self.sampleRate = sampleRate
        envelopeDecay = Float(exp(-1.0 / (0.05 * sampleRate)))
        angleAlpha = 1 / (0.004 * sampleRate)
        phaseCycles = Double(config.alignment) * 0.25
    }

    /// True once the register has matched the LFSR for 24 bits and is on the record.
    var hasPosition: Bool { validBits >= Self.lockBits && positionIndex >= 0 }

    /// Seconds of timecode (at 0% pitch) from `startIndex`, wrapping around the
    /// sequence so positions just before the start come out negative.
    func positionSeconds(startIndex: Int = 0) -> Double {
        var bits = positionIndex - startIndex
        let period = definition.positionModulus
        if period > 0 {
            bits %= period
            if bits > period / 2 { bits -= period }
            if bits < -period / 2 { bits += period }
        }
        // Between bits, move on at the current speed, but by no more than about
        // a bit: after the record has stood still, the time since the last bit
        // is long and would otherwise throw the position off on the restart.
        let bitSeconds = 1 / definition.bitRate
        let since = min(max(pitch * samplesSinceBit / sampleRate, -1.5 * bitSeconds), 1.5 * bitSeconds)
        return Double(bits) * bitSeconds + since
    }

    @inline(__always)
    func process(left: Float, right: Float) {
        var p = config.swapChannels ? right : left
        var s = config.swapChannels ? left : right
        // MK2 steps appear with the same sign on both channels; their sum is cleanest.
        let rawSum = p + s

        if definition.offsetModulated {
            removeOffset(&p, &s)
        } else {
            zeroP += (p - zeroP) * zeroAlpha
            zeroS += (s - zeroS) * zeroAlpha
            p -= zeroP
            s -= zeroS
        }

        let magnitude = max(abs(p), abs(s))
        envelope = magnitude > envelope ? magnitude : envelope * envelopeDecay
        samplesSinceBit += 1

        // Speed from the rotation of the (primary, secondary) vector.
        let angle = atan2f(s, p)
        var step = angle - lastAngle
        if step > .pi { step -= 2 * .pi } else if step < -.pi { step += 2 * .pi }
        lastAngle = angle
        let signedStep = Double(config.invertPhase ? step : -step)
        if envelope < 0.002 {
            angleRate = 0
        } else {
            angleRate += (signedStep - angleRate) * angleAlpha
        }
        pitch = angleRate * sampleRate / (2 * .pi * definition.resolution)

        if definition.offsetModulated {
            trackMK2(raw: rawSum, step: signedStep)
        } else {
            trackMK1(p: p, s: s)
        }
    }

    // MARK: MK1

    @inline(__always)
    private func trackMK1(p: Float, s: Float) {
        let threshold = max(envelope * 0.15, 0.001)
        if primaryPositive ? (p < -threshold) : (p > threshold) {
            primaryPositive.toggle()
            forwards = (primaryPositive == secondaryPositive) != config.invertPhase
        }
        if secondaryPositive ? (s < -threshold) : (s > threshold) {
            secondaryPositive.toggle()
            forwards = (primaryPositive != secondaryPositive) != config.invertPhase
            if definition.decodesPosition && secondaryPositive == config.readOnRising {
                var bit = abs(p) > refLevel
                if config.invertBits { bit.toggle() }
                refLevel = refLevel == 0 ? abs(p) * 0.9 : refLevel + (abs(p) - refLevel) / 48
                pushBit(bit)
            }
        }
    }

    // MARK: MK2

    // The data shifts the carrier up and down in steps that the phono stage
    // turns into decaying bumps. A one-pole high-pass on both channels removes
    // them for the speed measurement while keeping the 90° relationship. Its
    // corner follows the speed so slow scratches keep their level; the 200 Hz
    // floor lets it find the carrier from a standstill.
    private var hpP: Float = 0
    private var hpS: Float = 0
    private var lastP: Float = 0
    private var lastS: Float = 0

    @inline(__always)
    private func removeOffset(_ p: inout Float, _ s: inout Float) {
        let corner = min(max(0.35 * abs(pitch) * definition.resolution, 200), 900)
        let a = Float(exp(-2 * Double.pi * corner / sampleRate))
        hpP = a * (hpP + p - lastP)
        hpS = a * (hpS + s - lastS)
        lastP = p
        lastS = s
        p = hpP
        s = hpS
    }

    @inline(__always)
    private func trackMK2(raw: Float, step: Double) {
        guard envelope > 0.002 else { return }
        phaseCycles += step / (2 * .pi)
        let cycle = Int(phaseCycles.rounded(.down))
        if cycle != currentCycle {
            let movedForward = cycle > currentCycle
            if abs(cycle - currentCycle) == 1 && cycleCount >= 3 {
                finishCycle(currentCycle, mean: cycleSum / Double(cycleCount), forward: movedForward)
            } else {
                hasPreviousMean = false
            }
            currentCycle = cycle
            cycleSum = 0
            cycleCount = 0
        }
        cycleSum += Double(raw)
        cycleCount += 1
    }

    @inline(__always)
    private func mod5(_ x: Int) -> Int { ((x % 5) + 5) % 5 }

    private func finishCycle(_ cycle: Int, mean: Double, forward: Bool) {
        forwards = forward
        if hasPreviousMean {
            // The phono stage's AC coupling makes every offset decay (time
            // constant ~1.7 ms). Predict that decay so only real edges stand out.
            let cycleSeconds = 1 / (max(abs(pitch), 0.05) * definition.resolution)
            let decay = exp(-cycleSeconds / 0.0017)
            let jump = mean - previousMean * decay
            if abs(jump) > Double(envelope) * 0.35 {
                // Moving backwards, an edge is seen one cycle later in record order.
                level = jump > 0
                vote(edgeAt: mod5(forward ? cycle : cycle + 1))
            }
        }
        previousMean = mean
        hasPreviousMean = true

        // The middle of the 3-cycle part: two cycles after the second edge slot.
        if mod5(cycle - frameOffset) == 3 {
            pushBit(level)
        }
    }

    private func vote(edgeAt position: Int) {
        switch position {
        case 0: edgeVotes.0 += 1
        case 1: edgeVotes.1 += 1
        case 2: edgeVotes.2 += 1
        case 3: edgeVotes.3 += 1
        default: edgeVotes.4 += 1
        }
        cyclesSinceVoteDecay += 1
        if cyclesSinceVoteDecay >= 64 {
            cyclesSinceVoteDecay = 0
            edgeVotes = (edgeVotes.0 * 0.5, edgeVotes.1 * 0.5, edgeVotes.2 * 0.5, edgeVotes.3 * 0.5, edgeVotes.4 * 0.5)
        }
        // Edges fall on frame positions 0 and 2.
        var best = frameOffset
        var bestScore: Float = -1
        for o in 0..<5 {
            let score = votes(o) + votes((o + 2) % 5)
            if score > bestScore { bestScore = score; best = o }
        }
        frameOffset = best
    }

    @inline(__always)
    private func votes(_ i: Int) -> Float {
        switch i {
        case 0: edgeVotes.0
        case 1: edgeVotes.1
        case 2: edgeVotes.2
        case 3: edgeVotes.3
        default: edgeVotes.4
        }
    }

    // MARK: Register

    @inline(__always)
    private func pushBit(_ bit: Bool) {
        let top = UInt32(definition.bits - 1)
        if forwards {
            timecode = definition.forward(timecode)
            bitstream = (bitstream >> 1) | (bit ? UInt32(1) << top : 0)
        } else {
            timecode = definition.reverse(timecode)
            bitstream = ((bitstream << 1) & definition.mask) | (bit ? 1 : 0)
        }

        if timecode == bitstream {
            validBits += 1
            misses = 0
            if validBits == Self.lockBits { lockSerial &+= 1 }
        } else if validBits >= Self.lockBits && misses < Self.flywheelBits {
            // Flywheel: once locked, a few bad bits (dust, a nudge, a change
            // of direction) don't drop the lock. Trust the prediction and
            // correct the register; give up after several misses in a row.
            misses += 1
            bitstream = timecode
        } else {
            timecode = bitstream
            validBits = 0
            misses = 0
        }

        if validBits >= Self.lockBits {
            let index = lookup.index(of: timecode)
            // Reading backwards, the register describes the bit 21 places ahead of the needle.
            positionIndex = index < 0 ? -1 : (forwards ? index : index - (definition.bits - 1))
        } else {
            positionIndex = -1
        }
        samplesSinceBit = 0
    }
}

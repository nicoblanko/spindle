//
//  TimecodeSimulator.swift
//  Spindle
//
//  A virtual turntable that generates the timecode signal the decoder expects,
//  so the whole chain can be tested without vinyl. The platter has inertia, so
//  changing the speed behaves like a motor spinning up or a hand dragging it.
//
//  MK1: a 2 kHz quadrature carrier whose amplitude carries one bit per cycle.
//  MK2: a 2.5 kHz quadrature carrier shifted up or down. Each 5-cycle frame has
//  a 2-cycle part (the sequence 2^21 bits further on) and a 3-cycle part (the
//  frame's own bit). The phono stage's AC coupling (~1.7 ms) is applied, so
//  the steps decay as they do on the real records. Levels match recordings of
//  the user's MK2 records: carrier ~0.12, steps ~0.08.
//

import Foundation

nonisolated final class TimecodeSimulator {
    let definition: TimecodeDefinition
    /// Target speed set from the UI: 1 = 33⅓ rpm, 0 = stopped, negative = backwards.
    var targetPitch: Double = 0
    /// How quickly the platter reaches `targetPitch` per sample: 0.0008 is
    /// a motor (~25 ms); higher is a hand yanking it.
    var inertia = 0.0008
    private(set) var pitch: Double = 0
    /// Needle position in carrier cycles.
    private(set) var phase: Double
    /// Position in the bit sequence (cycles for MK1, frames for MK2).
    private var codeIndex = 0
    private var code: UInt32
    /// MK2 only: the register 2^21 bits ahead, for the 2-cycle parts.
    private var farCode: UInt32 = 0

    /// Needle lifted off the record: only a little noise reaches the input,
    /// while the platter keeps turning.
    var lifted = false {
        didSet { if lifted && !oldValue { liftSamples = 0 } }
    }
    /// A real lift isn't a clean cut: for ~30 ms the stylus scrapes out of
    /// the groove, the carrier fades and its phase wanders.
    var realisticLift = false
    /// Phase noise at full level: a hand spinning the record roughly (the
    /// reading zig-zags, but the needle stays in the groove).
    var roughness = 0.0
    private var liftSamples = 0
    private var wobble = 0.0
    private var noise: UInt32 = 0x12345

    /// Set from the UI to drop the needle; applied on the audio thread.
    var seekRequest: Double = -1

    // AC coupling of the phono stage (MK2).
    private var hpL: Float = 0, hpR: Float = 0, lastL: Float = 0, lastR: Float = 0

    init(definition: TimecodeDefinition, startSeconds: Double = 1) {
        self.definition = definition
        code = definition.seed
        if definition.offsetModulated {
            var far = definition.seed
            for _ in 0..<(1 << 21) { far = definition.forward(far) }
            farCode = far
        }
        phase = startSeconds * definition.resolution
        seek(toIndex: index(ofCycle: phase))
    }

    func seek(seconds: Double) {
        phase = max(0, seconds * definition.resolution)
        seek(toIndex: index(ofCycle: phase))
    }

    @inline(__always)
    private func index(ofCycle cycle: Double) -> Int {
        Int((cycle / Double(definition.cyclesPerBit)).rounded(.down))
    }

    private func seek(toIndex target: Int) {
        guard definition.decodesPosition else { codeIndex = target; return }
        let mk2 = definition.offsetModulated
        while codeIndex < target {
            code = definition.forward(code)
            if mk2 { farCode = definition.forward(farCode) }
            codeIndex += 1
        }
        while codeIndex > target {
            code = definition.reverse(code)
            if mk2 { farCode = definition.reverse(farCode) }
            codeIndex -= 1
        }
    }

    func generate(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>,
                  frames: Int, sampleRate: Double) {
        if seekRequest >= 0 {
            seek(seconds: seekRequest)
            seekRequest = -1
        }
        let step = definition.resolution / sampleRate
        let maxCycle = definition.decodesPosition
            ? Double(definition.length * definition.cyclesPerBit - 1) : 1e9
        let mk2 = definition.offsetModulated
        let coupling = Float(exp(-1 / (0.0017 * sampleRate)))

        for i in 0..<frames {
            pitch += (targetPitch - pitch) * inertia
            phase = min(max(phase + pitch * step, 0), maxCycle)
            let index = index(ofCycle: phase)
            if index != codeIndex { seek(toIndex: index) }

            var l: Float, r: Float
            var fade: Float = 1
            if lifted && realisticLift {
                // As on the user's records: the stylus scrapes for ~100 ms at
                // full level (the decoder loses lock first), then fades.
                liftSamples += 1
                let scrape = 0.1 * sampleRate
                fade = max(0, 1 - Float(max(0, Double(liftSamples) - scrape)) / Float(0.03 * sampleRate))
                noise = noise &* 1664525 &+ 1013904223
                wobble += (Double(noise >> 8) / Double(1 << 24) - 0.5) * 1.2
            }
            if roughness > 0 && !lifted {
                noise = noise &* 1664525 &+ 1013904223
                wobble = (Double(noise >> 8) / Double(1 << 24) - 0.5) * roughness
            }
            if lifted && fade <= 0 {
                noise = noise &* 1664525 &+ 1013904223
                l = (Float(noise >> 8) / Float(1 << 24) - 0.5) * 0.001
                r = l
            } else if mk2 {
                let theta = 2 * Double.pi * phase + wobble
                let inFrame = Int(phase.rounded(.down)) - index * 5
                let high = inFrame < 2 ? definition.bit(of: farCode) : definition.bit(of: code)
                let offset: Float = high ? 0.04 : -0.04
                l = (Float(sin(theta)) * 0.12 + offset) * fade
                r = (Float(cos(theta)) * 0.12 + offset) * fade
            } else {
                let amplitude: Float = !definition.decodesPosition || definition.bit(of: code) ? 0.3 : 0.2
                let theta = 2 * Double.pi * phase
                l = Float(sin(theta)) * amplitude
                r = Float(cos(theta)) * amplitude
            }

            if mk2 {
                hpL = coupling * (hpL + l - lastL); lastL = l; l = hpL
                hpR = coupling * (hpR + r - lastR); lastR = r; r = hpR
            }
            if !lifted { wobble = 0 }
            left[i] = l
            right[i] = r
        }
    }
}

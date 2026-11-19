//
//  TimecodeSimulator.swift
//  Spindle
//
//  A virtual turntable that generates the timecode signal the decoder expects,
//  so the whole chain can be tested without vinyl. The platter has inertia, so
//  changing the speed behaves like a motor spinning up or a hand dragging it.
//

import Foundation

nonisolated final class TimecodeSimulator {
    let definition: TimecodeDefinition
    /// Target speed set from the UI: 1 = 33⅓ rpm, 0 = stopped, negative = backwards.
    var targetPitch: Double = 0
    private(set) var pitch: Double = 0
    /// Needle position in carrier cycles.
    private(set) var phase: Double
    private var codeIndex = 0
    private var code: UInt32

    init(definition: TimecodeDefinition, startSeconds: Double = 1) {
        self.definition = definition
        code = definition.seed
        phase = startSeconds * definition.resolution
        seek(toCycle: Int(phase))
    }

    func seek(seconds: Double) {
        phase = max(0, seconds * definition.resolution)
        seek(toCycle: Int(phase))
    }

    private func seek(toCycle target: Int) {
        guard definition.decodesPosition else { codeIndex = target; return }
        while codeIndex < target { code = definition.forward(code); codeIndex += 1 }
        while codeIndex > target { code = definition.reverse(code); codeIndex -= 1 }
    }

    /// Needle lifted off the record: only a little noise reaches the input,
    /// while the platter keeps turning.
    var lifted = false
    private var noise: UInt32 = 0x12345

    /// Set from the UI to drop the needle; applied on the audio thread.
    var seekRequest: Double = -1

    func generate(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>,
                  frames: Int, sampleRate: Double) {
        if seekRequest >= 0 {
            seek(seconds: seekRequest)
            seekRequest = -1
        }
        let step = definition.resolution / sampleRate
        let maxCycle = definition.decodesPosition ? Double(definition.length - 1) : 1e9
        for i in 0..<frames {
            pitch += (targetPitch - pitch) * 0.0008
            phase = min(max(phase + pitch * step, 0), maxCycle)
            let cycle = Int(phase)
            if cycle != codeIndex { seek(toCycle: cycle) }
            if lifted {
                noise = noise &* 1664525 &+ 1013904223
                left[i] = (Float(noise >> 8) / Float(1 << 24) - 0.5) * 0.001
                right[i] = left[i]
                continue
            }
            let amplitude: Float = !definition.decodesPosition || definition.bit(of: code) ? 0.3 : 0.2
            let theta = 2 * Double.pi * phase
            left[i] = Float(sin(theta)) * amplitude
            right[i] = Float(cos(theta)) * amplitude
        }
    }
}

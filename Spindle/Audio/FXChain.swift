//
//  FXChain.swift
//  Spindle
//
//  The extra deck FX after filter and echo: reverb, flanger, bit crusher and
//  a beat-synced gate. Each is a single amount, 0 … 1 (0 = off), smoothed
//  so a knob never clicks. Runs on the audio thread: fixed buffers, no
//  allocation.
//
//  The reverb follows the Freeverb design (Jezar at Dreampoint, public
//  domain), cut down to four combs and two allpasses per channel.
//

import Foundation

nonisolated final class FXChain: @unchecked Sendable {
    // Set from the UI.
    var reverb: Double = 0
    var flanger: Double = 0
    var crush: Double = 0
    var gate: Double = 0

    private let sampleRate: Double
    private var reverbAmt: Float = 0, flangerAmt: Float = 0, crushAmt: Float = 0, gateAmt: Float = 0
    private let smooth: Float

    // Reverb: combs and allpasses for left and right in one buffer each.
    private static let combTuning = [1116, 1188, 1277, 1356]
    private static let allpassTuning = [556, 441]
    private static let spread = 23
    private var combs: [UnsafeMutablePointer<Float>] = []
    private var combLength: [Int] = []
    private var combIndex: [Int] = []
    private var combStore: [Float] = []
    private var allpasses: [UnsafeMutablePointer<Float>] = []
    private var allpassLength: [Int] = []
    private var allpassIndex: [Int] = []

    // Flanger.
    private static let flangeFrames = 4096
    private let flangeL: UnsafeMutablePointer<Float>
    private let flangeR: UnsafeMutablePointer<Float>
    private var flangeWrite = 0
    private var lfo: Double = 0

    // Crusher.
    private var holdL: Float = 0, holdR: Float = 0, holdCount = 0

    // Gate.
    private var gateLevel: Float = 1

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        smooth = Float(1 - exp(-1 / (0.02 * sampleRate)))
        let scale = sampleRate / 44100
        for channel in 0..<2 {
            for t in Self.combTuning {
                let n = Int(Double(t + channel * Self.spread) * scale)
                let b = UnsafeMutablePointer<Float>.allocate(capacity: n)
                b.initialize(repeating: 0, count: n)
                combs.append(b); combLength.append(n); combIndex.append(0); combStore.append(0)
            }
            for t in Self.allpassTuning {
                let n = Int(Double(t + channel * Self.spread) * scale)
                let b = UnsafeMutablePointer<Float>.allocate(capacity: n)
                b.initialize(repeating: 0, count: n)
                allpasses.append(b); allpassLength.append(n); allpassIndex.append(0)
            }
        }
        flangeL = .allocate(capacity: Self.flangeFrames)
        flangeL.initialize(repeating: 0, count: Self.flangeFrames)
        flangeR = .allocate(capacity: Self.flangeFrames)
        flangeR.initialize(repeating: 0, count: Self.flangeFrames)
    }

    deinit {
        combs.forEach { $0.deallocate() }
        allpasses.forEach { $0.deallocate() }
        flangeL.deallocate()
        flangeR.deallocate()
    }

    var active: Bool {
        reverb > 0.005 || flanger > 0.005 || crush > 0.005 || gate > 0.005
            || reverbAmt > 0.001 || flangerAmt > 0.001 || crushAmt > 0.001 || gateAmt > 0.001
    }

    /// One stereo sample. `beatPhase` is the position in beats (for the gate).
    @inline(__always)
    func process(_ l: inout Float, _ r: inout Float, beatPhase: Double) {
        reverbAmt += (Float(reverb) - reverbAmt) * smooth
        flangerAmt += (Float(flanger) - flangerAmt) * smooth
        crushAmt += (Float(crush) - crushAmt) * smooth
        gateAmt += (Float(gate) - gateAmt) * smooth

        // Crusher: fewer bits and a lower sample rate as it turns up.
        if crushAmt > 0.002 {
            let hold = 1 + Int(crushAmt * 14)
            holdCount += 1
            if holdCount >= hold {
                holdCount = 0
                let steps = pow(2, 15 - 11 * crushAmt)
                holdL = (l * steps).rounded() / steps
                holdR = (r * steps).rounded() / steps
            }
            l += (holdL - l) * min(1, crushAmt * 3)
            r += (holdR - r) * min(1, crushAmt * 3)
        }

        // Flanger: a 1–6 ms delay swept by a slow LFO, with feedback.
        flangeL[flangeWrite] = l
        flangeR[flangeWrite] = r
        if flangerAmt > 0.002 {
            lfo += 2 * .pi * 0.18 / sampleRate
            if lfo > 2 * .pi { lfo -= 2 * .pi }
            let delay = (0.001 + 0.005 * (0.5 + 0.5 * sin(lfo))) * sampleRate
            let read = Double(flangeWrite) - delay
            let i0 = Int(read.rounded(.down))
            let f = Float(read - Double(i0))
            let mask = Self.flangeFrames - 1
            let a = (i0 + Self.flangeFrames) & mask, b = (i0 + 1 + Self.flangeFrames) & mask
            let dl = flangeL[a] + (flangeL[b] - flangeL[a]) * f
            let dr = flangeR[a] + (flangeR[b] - flangeR[a]) * f
            let fb = 0.7 * flangerAmt
            flangeL[flangeWrite] = l + dl * fb
            flangeR[flangeWrite] = r + dr * fb
            l = l * (1 - 0.3 * flangerAmt) + dl * 0.8 * flangerAmt
            r = r * (1 - 0.3 * flangerAmt) + dr * 0.8 * flangerAmt
        }
        flangeWrite = (flangeWrite + 1) & (Self.flangeFrames - 1)

        // Reverb.
        if reverbAmt > 0.001 {
            let input = (l + r) * 0.02
            let feedback: Float = 0.78 + 0.16 * reverbAmt
            let damp: Float = 0.25
            var outL: Float = 0, outR: Float = 0
            let combsPerSide = Self.combTuning.count
            for c in 0..<(combsPerSide * 2) {
                let buf = combs[c]
                let i = combIndex[c]
                let y = buf[i]
                combStore[c] = y * (1 - damp) + combStore[c] * damp
                buf[i] = input + combStore[c] * feedback
                combIndex[c] = i + 1 >= combLength[c] ? 0 : i + 1
                if c < combsPerSide { outL += y } else { outR += y }
            }
            let apPerSide = Self.allpassTuning.count
            for a in 0..<(apPerSide * 2) {
                let buf = allpasses[a]
                let i = allpassIndex[a]
                let stored = buf[i]
                let x = a < apPerSide ? outL : outR
                let y = stored - x
                buf[i] = x + stored * 0.5
                allpassIndex[a] = i + 1 >= allpassLength[a] ? 0 : i + 1
                if a < apPerSide { outL = y } else { outR = y }
            }
            let wet = reverbAmt * 1.2
            l = l * (1 - 0.35 * reverbAmt) + outL * wet
            r = r * (1 - 0.35 * reverbAmt) + outR * wet
        }

        // Gate: chops on eighth notes of the grid.
        if gateAmt > 0.002 {
            let phase = beatPhase * 2
            let open = phase - phase.rounded(.down) < 0.5
            let target: Float = open ? 1 : 1 - gateAmt
            gateLevel += (target - gateLevel) * 0.01
            l *= gateLevel
            r *= gateLevel
        } else {
            gateLevel = 1
        }
    }
}

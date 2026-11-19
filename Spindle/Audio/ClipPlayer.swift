//
//  ClipPlayer.swift
//  Spindle
//
//  One channel of the Launch page: plays a clip (a region of a track, looped
//  or once) at the master tempo. Clips start and stop exactly on the master
//  clock's beat, to the sample, so every channel stays in phase. Speed is
//  master BPM ÷ the clip's own BPM, so pitch moves with it (like vinyl).
//
//  The UI hands a clip over by filling the pending fields and then storing
//  the sample pointer (release); the audio thread picks it up (acquire) and
//  swaps it in on the launch beat. The UI owns the sample memory.
//

import Foundation
import Synchronization

nonisolated struct ClipTelemetry {
    var playing = false
    var queued = false
    /// 0…1 through the loop (or the whole clip).
    var progress: Double = 0
    /// Id of the clip playing, −1 for none.
    var clipID: Int = -1
    var pendingID: Int = -1
    var level: Float = 0
}

nonisolated final class ClipPlayer: @unchecked Sendable {
    let telemetry: UnsafeMutablePointer<ClipTelemetry>

    // Set from the UI.
    var gain: Float = 1
    var filter: Double = 0
    var muted = false

    // A launch: fill these, then store the pointer.
    var pendingBeat: Double = 0
    var pendingBPM: Double = 120
    /// Loop length in frames (fractional, so long loops don't drift); 0 = play to the end once.
    var pendingLoopFrames: Double = 0
    var pendingID = -1
    private let pending = Atomic<UnsafeMutableRawPointer?>(nil)
    /// Stop on this master beat (NaN = no stop pending).
    var stopAtBeat: Double = .nan

    private var current: UnsafeMutablePointer<TrackSamples>?
    private var clipBPM: Double = 120
    private var loopFrames: Double = 0
    private var position: Double = 0
    private var playing = false
    private var currentID = -1
    private var currentGain: Float = 0
    private var l1: Float = 0, l2: Float = 0, r1: Float = 0, r2: Float = 0
    private let sampleRate: Double

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        telemetry = .allocate(capacity: 1)
        telemetry.initialize(to: ClipTelemetry())
    }

    deinit { telemetry.deallocate() }

    /// UI: start `samples` on master beat `beat`.
    func launch(_ samples: UnsafeMutablePointer<TrackSamples>, id: Int, bpm: Double, loopFrames: Double, atBeat beat: Double) {
        pendingBeat = beat
        pendingBPM = bpm
        pendingLoopFrames = loopFrames
        pendingID = id
        stopAtBeat = .nan
        pending.store(UnsafeMutableRawPointer(samples), ordering: .releasing)
    }

    /// UI: stop on master beat `beat` (and drop a launch still waiting).
    func stop(atBeat beat: Double) {
        pending.store(nil, ordering: .releasing)
        stopAtBeat = beat
    }

    /// Is this sample memory in use (playing or waiting)? The UI keeps it until not.
    func uses(_ samples: UnsafeMutablePointer<TrackSamples>) -> Bool {
        current == samples || pending.load(ordering: .acquiring) == UnsafeMutableRawPointer(samples)
    }

    /// Audio thread: mixes into left/right. `beatStart` is the master beat at
    /// the first frame; the master clock moves `beatsPerFrame` per frame.
    func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int,
                beatStart: Double, beatsPerFrame: Double, masterBPM: Double) {
        // When (in this buffer) does a waiting launch or stop happen?
        let next = pending.load(ordering: .acquiring)
        var launchAt = Int.max
        if next != nil {
            let k = Int(((pendingBeat - beatStart) / beatsPerFrame).rounded())
            launchAt = max(0, k)
        }
        var stopAt = Int.max
        if !stopAtBeat.isNaN {
            stopAt = max(0, Int(((stopAtBeat - beatStart) / beatsPerFrame).rounded()))
        }

        let filterOn = abs(filter) > 0.01
        let highPass = filter > 0
        let cutoff = highPass ? 20 * pow(200.0, filter) : 20_000 * pow(0.01, -filter)
        let g = Float(tan(Double.pi * min(cutoff, sampleRate * 0.45) / sampleRate))
        let k: Float = 1.1
        let a1 = 1 / (1 + g * (g + k)), a2 = g * a1, a3 = g * a2
        let targetGain: Float = muted ? 0 : gain
        var peak: Float = 0

        for i in 0..<frames {
            if i == launchAt, let raw = next {
                current = raw.assumingMemoryBound(to: TrackSamples.self)
                clipBPM = pendingBPM
                loopFrames = pendingLoopFrames
                currentID = pendingID
                // Late by part of a beat (a launch in the past): start in phase.
                let late = beatStart + Double(i) * beatsPerFrame - pendingBeat
                position = max(0, late) * 60 / max(clipBPM, 1) * sampleRate
                playing = true
                _ = pending.compareExchange(expected: raw, desired: nil, ordering: .acquiringAndReleasing)
            }
            if i == stopAt {
                playing = false
                stopAtBeat = .nan
                currentID = -1
            }
            currentGain += (targetGain - currentGain) * 0.002
            guard playing, let samples = current else { continue }
            let t = samples.pointee
            let x = position * t.sampleRate / sampleRate
            var outL = Self.read(t.left, t.frames, x)
            var outR = Self.read(t.right, t.frames, x)
            if filterOn {
                func run(_ v0: Float, _ c1: inout Float, _ c2: inout Float) -> Float {
                    let v3 = v0 - c2
                    let v1 = a1 * c1 + a2 * v3
                    let v2 = c2 + a2 * c1 + a3 * v3
                    c1 = 2 * v1 - c1
                    c2 = 2 * v2 - c2
                    return highPass ? v0 - k * v1 - v2 : v2
                }
                outL = run(outL, &l1, &l2)
                outR = run(outR, &r1, &r2)
            }
            outL *= currentGain
            outR *= currentGain
            left[i] += outL
            right[i] += outR
            peak = max(peak, abs(outL), abs(outR))
            position += masterBPM / max(clipBPM, 1)
            if loopFrames > 0 {
                if position >= loopFrames { position -= loopFrames }
            } else if position >= Double(t.frames) {
                playing = false
                currentID = -1
            }
        }

        let total = loopFrames > 0 ? loopFrames : Double(current?.pointee.frames ?? 1)
        telemetry.pointee = ClipTelemetry(
            playing: playing, queued: pending.load(ordering: .relaxed) != nil,
            progress: playing ? min(1, position / max(total, 1)) : 0,
            clipID: playing ? currentID : -1,
            pendingID: next != nil && launchAt >= frames ? pendingID : -1,
            level: peak)
    }

    @inline(__always)
    private static func read(_ data: UnsafeMutablePointer<Float>, _ count: Int, _ x: Double) -> Float {
        let i = Int(x)
        guard i >= 0, i + 1 < count else { return 0 }
        let f = Float(x - Double(i))
        return data[i] + (data[i + 1] - data[i]) * f
    }
}

//
//  DeckEngine.swift
//  Spindle
//
//  One deck on the audio thread: decodes its timecode input, moves the
//  playhead and plays the loaded track at the record's speed.
//

import Foundation
import Synchronization

/// What the UI reads each frame. Written by the audio thread; a torn read only
/// affects one frame of display.
nonisolated struct DeckTelemetry {
    var pitch: Double = 0
    var forwards = true
    var playhead: Double = 0
    var timecodeSeconds: Double = 0
    /// Raw index in the timecode sequence; used to calibrate the record start.
    var positionIndex = -1
    var hasPosition = false
    var absolute = false
    var signal: Float = 0
    var activeConfig: Int32 = 0
    var validBits: Int32 = 0
}

nonisolated final class DeckEngine: @unchecked Sendable {
    static let scopeFrames = 512

    let decoders: [TimecodeDecoder]
    private var active = 0
    private let canSearch: Bool
    /// Position index (in the format's bit sequence) of the record's start,
    /// calibrated per deck. Set from the UI.
    var startIndex = 0

    /// Plays a quiet tone (A 440 Hz, B 660 Hz) on this deck's output, to check
    /// which mixer channel it reaches. Set from the UI.
    var testTone = false
    private var tonePhase: Double = 0

    /// Starts from a remembered channel order, so direction is right before
    /// the first lock.
    func prefer(config index: Int) {
        if decoders.indices.contains(index) { active = index }
    }
    let sampleRate: Double

    let telemetry: UnsafeMutablePointer<DeckTelemetry>
    /// Last 512 input frames, interleaved L/R, for the scope.
    let scope: UnsafeMutablePointer<Float>
    private var scopeWrite = 0

    /// The TrackSamples being played, swapped in by the UI thread.
    let track = Atomic<UnsafeMutableRawPointer?>(nil)

    /// Follow the record's absolute position (true) or only its speed (false).
    var absoluteMode = true

    private var playhead: Double = 0
    private var rate: Double = 0

    /// Record position (seconds) where the track's start sits. Set when a track
    /// is loaded, so it starts wherever the needle is: a 20-minute side can
    /// play a 6-minute track from any groove. Needle drops then move the track
    /// relative to that point.
    private var trackOffset: Double = 0
    /// Set from the UI; the audio thread re-anchors on the next buffer (or on
    /// the first lock, if the record isn't locked yet).
    var cueRequest = false
    private var anchorPending = false

    var toneFrequency: Double = 440

    init(definition: TimecodeDefinition, sampleRate: Double) {
        self.sampleRate = sampleRate
        decoders = DecoderConfig.all.map { TimecodeDecoder(config: $0, definition: definition, sampleRate: sampleRate) }
        canSearch = definition.decodesPosition
        telemetry = .allocate(capacity: 1)
        telemetry.initialize(to: DeckTelemetry())
        scope = .allocate(capacity: Self.scopeFrames * 2)
        scope.initialize(repeating: 0, count: Self.scopeFrames * 2)
    }

    deinit {
        telemetry.deallocate()
        scope.deallocate()
    }

    /// Swaps in a new track and returns the previous one, which the caller frees
    /// once the audio thread can no longer be using it.
    func exchangeTrack(_ samples: UnsafeMutablePointer<TrackSamples>?) -> UnsafeMutablePointer<TrackSamples>? {
        let old = track.exchange(samples.map { UnsafeMutableRawPointer($0) }, ordering: .acquiringAndReleasing)
        if samples != nil { cueRequest = true }
        return old?.assumingMemoryBound(to: TrackSamples.self)
    }

    /// Samples since the active decoder last had position. While it holds lock
    /// only that decoder runs; after 0.5 s without lock all of them search again.
    private var unlockedSamples = Int.max / 2

    func decode(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int) {
        let current = decoders[active]
        // No carrier (needle up, record stopped): nothing to search for.
        let searching = canSearch && unlockedSamples > Int(sampleRate * 0.5) && current.envelope > 0.002 && abs(current.pitch) > 0.02
        for i in 0..<frames {
            let l = left[i], r = right[i]
            if searching {
                for decoder in decoders { decoder.process(left: l, right: r) }
            } else {
                current.process(left: l, right: r)
            }
            scope[scopeWrite * 2] = l
            scope[scopeWrite * 2 + 1] = r
            scopeWrite = (scopeWrite + 1) & (Self.scopeFrames - 1)
        }
        unlockedSamples = current.hasPosition ? 0 : unlockedSamples + frames

        // Follow the decoder that has locked onto the position. Stay with it
        // until it loses lock and another one has it.
        if searching && !decoders[active].hasPosition {
            var best = -1
            var bestBits = 0
            for (index, decoder) in decoders.enumerated() where decoder.hasPosition && decoder.validBits > bestBits {
                best = index
                bestBits = decoder.validBits
            }
            if best >= 0 { active = best }
        }
    }

    func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int, mix: Bool) {
        let decoder = decoders[active]
        var target = decoder.pitch
        if cueRequest {
            cueRequest = false
            playhead = 0
            anchorPending = true
        }
        if anchorPending && decoder.hasPosition {
            // Tie the track to the record where it is now.
            trackOffset = decoder.positionSeconds(startIndex: startIndex) - playhead
            anchorPending = false
        }
        let position = decoder.positionSeconds(startIndex: startIndex) - trackOffset
        let absolute = absoluteMode && decoder.hasPosition && !anchorPending
        if absolute {
            let error = position - playhead
            if abs(error) > 0.15 {
                playhead = position                  // needle drop
            } else {
                target += error * 2                  // pull gently into place
            }
        }

        let start = rate
        let step = (target - start) / Double(max(frames, 1))
        let samples = track.load(ordering: .acquiring)?.assumingMemoryBound(to: TrackSamples.self)

        for i in 0..<frames {
            let r = start + step * Double(i + 1)
            var outL: Float = 0, outR: Float = 0
            if let samples {
                let t = samples.pointee
                let x = playhead * t.sampleRate
                outL = Self.hermite(t.left, t.frames, x)
                outR = Self.hermite(t.right, t.frames, x)
            }
            if testTone {
                let tone = Float(sin(tonePhase)) * 0.1
                tonePhase += 2 * .pi * toneFrequency / sampleRate
                if tonePhase > 2 * .pi { tonePhase -= 2 * .pi }
                outL += tone
                outR += tone
            }
            if mix {
                left[i] += outL
                right[i] += outR
            } else {
                left[i] = outL
                right[i] = outR
            }
            playhead += r / sampleRate
        }
        rate = target

        telemetry.pointee = DeckTelemetry(
            pitch: decoder.pitch,
            forwards: decoder.forwards,
            playhead: playhead,
            timecodeSeconds: decoder.hasPosition ? position : telemetry.pointee.timecodeSeconds,
            positionIndex: decoder.hasPosition ? decoder.positionIndex : telemetry.pointee.positionIndex,
            hasPosition: decoder.hasPosition,
            absolute: absolute,
            signal: decoder.envelope,
            activeConfig: Int32(active),
            validBits: Int32(decoder.validBits))
    }

    @inline(__always)
    private static func hermite(_ data: UnsafeMutablePointer<Float>, _ count: Int, _ x: Double) -> Float {
        let floorX = x.rounded(.down)
        let i = Int(floorX)
        if i < 1 || i + 2 >= count { return 0 }
        let f = Float(x - floorX)
        let ym1 = data[i - 1], y0 = data[i], y1 = data[i + 1], y2 = data[i + 2]
        let c1 = 0.5 * (y1 - ym1)
        let c2 = ym1 - 2.5 * y0 + 2 * y1 - 0.5 * y2
        let c3 = 0.5 * (y2 - ym1) + 1.5 * (y0 - y1)
        return ((c3 * f + c2) * f + c1) * f + y0
    }
}

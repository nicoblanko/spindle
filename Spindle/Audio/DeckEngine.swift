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
    /// Locked now or within the last half second: what the UI shows, so a
    /// short drop (holding the platter, a backspin) doesn't flicker.
    var lockHeld = false
    var absolute = false
    var signal: Float = 0
    var activeConfig: Int32 = 0
    var validBits: Int32 = 0
    /// The needle left the record while the track was playing, and the deck
    /// carries on at the last speed until the needle is back.
    var coasting = false
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
    private var samplesSinceLock = Int.max / 2

    var toneFrequency: Double = 440

    // MARK: Laptop mode (no timecode)

    /// The deck is driven by its own transport instead of a record.
    var internalMode = false
    var transportPlaying = false
    /// Playback speed in laptop mode (1 = the track's own tempo).
    var tempo: Double = 1
    /// Channel level (laptop mode's built-in mixer: volume × crossfader).
    var gain: Float = 1
    private var currentGain: Float = 1

    // MARK: Cues, loops, FX (set from the UI)

    /// Jump the track to this time (seconds); NaN = none. The record keeps
    /// control: the track's offset to the record moves with the jump.
    var jumpRequest: Double = .nan
    /// Scrolling while playing: the UI adds seconds here and the track
    /// catches up over a few milliseconds by playing a little faster or
    /// slower, like pushing a record, instead of jumping. Only the UI
    /// writes `nudgeTotal`; only the audio thread writes `nudgeDone`.
    var nudgeTotal: Double = 0
    private var nudgeDone: Double = 0
    /// What's still to come of the nudges sent so far.
    var nudgePending: Double { nudgeTotal - nudgeDone }

    /// A short crossfade from the old position after any jump, so it
    /// doesn't click.
    private static let fadeFrames = 240
    private var fadeFrom: Double = 0
    private var fadeLeft = 0
    /// Fades the track out when it isn't moving: a stopped deck would
    /// otherwise hold the sample under the playhead, and every move while
    /// stopped would be heard as a soft thump.
    private var motionGain: Float = 0
    private let motionStep: Float

    @inline(__always)
    private func startFade(from old: Double) {
        fadeFrom = old
        fadeLeft = Self.fadeFrames
    }
    var loopActive = false
    var loopStart: Double = 0
    var loopLength: Double = 0
    /// −1 … 1: low-pass below 0, high-pass above.
    var filter: Double = 0
    /// 0 … 1: echo wet level and feedback.
    var echo: Double = 0
    /// Length of one beat of the loaded track at its own tempo, for the echo.
    var beatSeconds: Double = 0.5

    // MARK: Metronome (Prep preview)

    /// Clicks on every beat of the grid: higher and louder on each bar's first beat.
    var metronome = false
    var gridOffset: Double = 0
    var gridBeat: Double = 0.5
    private var lastBeat = Int.min
    private var clickPhase: Double = 0
    private var clickEnv: Float = 0
    private var clickFreq: Double = 1000
    private var clickLevel: Float = 0
    private let clickDecay: Float

    /// Reverb, flanger, crusher and gate.
    let effects: FXChain

    /// Sets one FX amount (from the UI).
    func setFX(_ kind: FXKind, _ value: Double) {
        switch kind {
        case .filter: filter = value
        case .echo: echo = value
        case .reverb: effects.reverb = value
        case .flanger: effects.flanger = value
        case .crush: effects.crush = value
        case .gate: effects.gate = value
        }
    }

    private var svfL1: Float = 0, svfL2: Float = 0, svfR1: Float = 0, svfR2: Float = 0
    private static let delayFrames = 1 << 17
    private let delayL: UnsafeMutablePointer<Float>
    private let delayR: UnsafeMutablePointer<Float>
    private var delayWrite = 0
    private var delaySamples: Double = 0
    private var echoWet: Float = 0

    // MARK: Needle up

    /// Set from the UI to stop a deck that is playing on with the needle up.
    var stopCoastRequest = false
    private(set) var coasting = false
    private var coastPitch: Double = 0
    private var coastSamples = 0
    private var wasLocked = false
    /// Pitch of the last buffers, newest last, to read the speed from just
    /// before the needle left (the decoder's own reading is noise by then).
    private var pitchHistory = [Double](repeating: 0, count: 64)
    private var levelHistory = [Float](repeating: 0, count: 64)
    private var historyWrite = 0
    /// Peak input level of the last buffer.
    private var inputLevel: Float = 0
    private var coastLevel: Float = 0
    private var coastSerial = 0
    private var levelBackSamples = 0
    /// A new lock must hold this many bits (0.3 s) before the deck follows it
    /// again: a false lock on landing drops out well before that.
    private let confirmBits: Int
    /// A needle that is up for longer than this was put back (the record ran
    /// out): the track carries on. A shorter hop is a needle drop.
    static let returnSeconds = 1.0

    init(definition: TimecodeDefinition, sampleRate: Double) {
        self.sampleRate = sampleRate
        decoders = DecoderConfig.all.map { TimecodeDecoder(config: $0, definition: definition, sampleRate: sampleRate) }
        canSearch = definition.decodesPosition
        confirmBits = Int(0.3 * definition.bitRate)
        clickDecay = Float(exp(-1 / (0.025 * sampleRate)))
        effects = FXChain(sampleRate: sampleRate)
        motionStep = Float(1 / (0.004 * sampleRate))
        telemetry = .allocate(capacity: 1)
        telemetry.initialize(to: DeckTelemetry())
        scope = .allocate(capacity: Self.scopeFrames * 2)
        scope.initialize(repeating: 0, count: Self.scopeFrames * 2)
        delayL = .allocate(capacity: Self.delayFrames)
        delayL.initialize(repeating: 0, count: Self.delayFrames)
        delayR = .allocate(capacity: Self.delayFrames)
        delayR.initialize(repeating: 0, count: Self.delayFrames)
    }

    deinit {
        telemetry.deallocate()
        scope.deallocate()
        delayL.deallocate()
        delayR.deallocate()
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
        var peak: Float = 0
        for i in 0..<frames {
            let l = left[i], r = right[i]
            peak = max(peak, abs(l), abs(r))
            if searching {
                for decoder in decoders { decoder.process(left: l, right: r) }
            } else {
                current.process(left: l, right: r)
            }
            scope[scopeWrite * 2] = l
            scope[scopeWrite * 2 + 1] = r
            scopeWrite = (scopeWrite + 1) & (Self.scopeFrames - 1)
        }
        inputLevel = peak
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
        if !jumpRequest.isNaN {
            let delta = jumpRequest - playhead
            if abs(delta) > 0.002 { startFade(from: playhead) }
            playhead = jumpRequest
            trackOffset -= delta
            jumpRequest = .nan
            lastBeat = Int.min
        }
        var position = 0.0
        var absolute = false
        if internalMode {
            target = transportPlaying ? tempo : 0
        } else {
            updateCoasting(decoder: decoder, frames: frames)
            if coasting {
                target = coastPitch
            }
            if anchorPending && decoder.hasPosition && !coasting {
                // Tie the track to the record where it is now.
                trackOffset = decoder.positionSeconds(startIndex: startIndex) - playhead
                anchorPending = false
            }
            position = decoder.positionSeconds(startIndex: startIndex) - trackOffset
            absolute = absoluteMode && decoder.hasPosition && !anchorPending && !coasting
            if absolute {
                let error = position - playhead
                if abs(error) > 0.15 {
                    startFade(from: playhead)
                    playhead = position                  // needle drop
                } else {
                    target += error * 2                  // pull gently into place
                }
            }

        }

        let start = rate
        let step = (target - start) / Double(max(frames, 1))
        let samples = track.load(ordering: .acquiring)?.assumingMemoryBound(to: TrackSamples.self)

        // Filter: a state-variable filter, cutoff swept exponentially.
        let filterOn = abs(filter) > 0.01
        let highPass = filter > 0
        let cutoff = highPass ? 20 * pow(200.0, filter) : 20_000 * pow(0.01, -filter)
        let g = Float(tan(Double.pi * min(cutoff, sampleRate * 0.45) / sampleRate))
        let k: Float = 1.1
        let a1 = 1 / (1 + g * (g + k)), a2 = g * a1, a3 = g * a2
        // Echo: three-quarter beat at the playing speed.
        let speed = max(abs(target), 0.25)
        let wantedDelay = min(0.75 * beatSeconds / speed * sampleRate, Double(Self.delayFrames - 2))
        let echoTarget = Float(echo)
        let feedback = Float(0.3 + 0.45 * echo)
        let loopEnd = loopStart + loopLength
        let looping = loopActive && loopLength > 0.05
        let fxOn = effects.active

        // Nudges: a big one jumps; otherwise most of what's pending is
        // played out over this buffer as extra speed.
        var pending = nudgeTotal - nudgeDone
        if abs(pending) > 3 {
            startFade(from: playhead)
            playhead += pending
            trackOffset -= pending
            nudgeDone += pending
            pending = 0
        }
        let take = pending * (1 - exp(-Double(frames) / (0.025 * sampleRate)))
        nudgeDone += take
        let nudgeStep = take / Double(max(frames, 1))

        for i in 0..<frames {
            let r = start + step * Double(i + 1)
            var outL: Float = 0, outR: Float = 0
            if let samples {
                let t = samples.pointee
                let x = playhead * t.sampleRate
                outL = Self.hermite(t.left, t.frames, x)
                outR = Self.hermite(t.right, t.frames, x)
                if fadeLeft > 0 {
                    let g = Float(fadeLeft) / Float(Self.fadeFrames)
                    let xo = fadeFrom * t.sampleRate
                    outL = outL * (1 - g) + Self.hermite(t.left, t.frames, xo) * g
                    outR = outR * (1 - g) + Self.hermite(t.right, t.frames, xo) * g
                }
            }
            if fadeLeft > 0 {
                fadeFrom += r / sampleRate
                fadeLeft -= 1
            }
            // Moving at all (playing, scratching, nudging): sound; stopped: silence.
            let moving = abs(r) > 0.002 || abs(nudgeStep) > 1e-7
            motionGain = moving ? min(1, motionGain + motionStep) : max(0, motionGain - motionStep)
            outL *= motionGain
            outR *= motionGain
            if filterOn {
                func run(_ v0: Float, _ c1: inout Float, _ c2: inout Float) -> Float {
                    let v3 = v0 - c2
                    let v1 = a1 * c1 + a2 * v3
                    let v2 = c2 + a2 * c1 + a3 * v3
                    c1 = 2 * v1 - c1
                    c2 = 2 * v2 - c2
                    return highPass ? v0 - k * v1 - v2 : v2
                }
                outL = run(outL, &svfL1, &svfL2)
                outR = run(outR, &svfR1, &svfR2)
            }
            echoWet += (echoTarget - echoWet) * 0.0005
            delaySamples += (wantedDelay - delaySamples) * 0.0002
            if echoWet > 0.0005 || echoTarget > 0 {
                let read = (delayWrite - Int(delaySamples) + Self.delayFrames) & (Self.delayFrames - 1)
                let dl = delayL[read], dr = delayR[read]
                delayL[delayWrite] = outL + dl * feedback
                delayR[delayWrite] = outR + dr * feedback
                outL += dl * echoWet
                outR += dr * echoWet
            } else {
                delayL[delayWrite] = 0
                delayR[delayWrite] = 0
                delaySamples = wantedDelay       // start at the right time, no sweep
            }
            delayWrite = (delayWrite + 1) & (Self.delayFrames - 1)
            if fxOn {
                effects.process(&outL, &outR, beatPhase: (playhead - gridOffset) / max(gridBeat, 0.05))
            }
            currentGain += (gain - currentGain) * 0.002
            outL *= currentGain
            outR *= currentGain
            if metronome && gridBeat > 0.05 {
                let beatPos = (playhead - gridOffset) / gridBeat
                let beat = beatPos >= 0 ? Int(beatPos) : Int(beatPos.rounded(.down))
                if beat != lastBeat {
                    if lastBeat != Int.min && r > 0.05 && beatPos - Double(beat) < 0.1 {
                        let down = ((beat % 4) + 4) % 4 == 0
                        clickFreq = down ? 1760 : 1175
                        clickLevel = down ? 0.35 : 0.2
                        clickEnv = 1
                        clickPhase = 0
                    }
                    lastBeat = beat
                }
            }
            if clickEnv > 0.001 {
                let c = Float(sin(clickPhase)) * clickEnv * clickLevel * currentGain
                clickPhase += 2 * .pi * clickFreq / sampleRate
                clickEnv *= clickDecay
                outL += c
                outR += c
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
            playhead += r / sampleRate + nudgeStep
            trackOffset -= nudgeStep
            if looping {
                // Wrap inside the loop; the record keeps its place, so the
                // track's offset to it moves by one loop length.
                if r > 0 && playhead >= loopEnd {
                    startFade(from: playhead)
                    playhead -= loopLength
                    trackOffset += loopLength
                } else if r < 0 && playhead < loopStart && playhead > loopStart - 0.25 {
                    startFade(from: playhead)
                    playhead += loopLength
                    trackOffset -= loopLength
                }
            }
        }
        rate = target
        wasLocked = decoder.hasPosition
        samplesSinceLock = decoder.hasPosition ? 0 : samplesSinceLock + frames

        telemetry.pointee = DeckTelemetry(
            pitch: internalMode ? target : (coasting ? coastPitch : decoder.pitch),
            forwards: decoder.forwards,
            playhead: playhead,
            timecodeSeconds: decoder.hasPosition ? position : telemetry.pointee.timecodeSeconds,
            positionIndex: decoder.hasPosition ? decoder.positionIndex : telemetry.pointee.positionIndex,
            hasPosition: decoder.hasPosition,
            lockHeld: samplesSinceLock < Int(sampleRate * 0.5),
            absolute: absolute,
            signal: decoder.envelope,
            activeConfig: Int32(active),
            validBits: Int32(decoder.validBits),
            coasting: coasting)
    }

    /// The input level fell away at once while the record was turning
    /// steadily: the needle was lifted or ran off the end. Keep playing at that
    /// speed. When the needle is back and the decoder has locked afresh, a
    /// needle that was up for a while carries the track on from where it is;
    /// a quick hop in absolute mode stays a needle drop.
    private func updateCoasting(decoder: TimecodeDecoder, frames: Int) {
        if stopCoastRequest {
            stopCoastRequest = false
            coasting = false
        }
        let bufferSeconds = Double(frames) / sampleRate
        let count = pitchHistory.count
        func back(_ seconds: Double) -> Int {
            let n = min(count - 1, max(1, Int((seconds / bufferSeconds).rounded())))
            return (historyWrite - n + count * 2) % count
        }

        if coasting {
            coastSamples += frames
            if inputLevel > coastLevel * 0.3 {
                levelBackSamples += frames
            } else {
                levelBackSamples = 0
            }
            let back = Double(levelBackSamples) / sampleRate
            let freshLock = decoder.hasPosition && decoder.lockSerial != coastSerial && decoder.validBits >= confirmBits
            if back > 0.02 && (freshLock || (back > 1.5 && decoder.hasPosition)) {
                coasting = false
                let upFor = Double(coastSamples - levelBackSamples) / sampleRate
                if !absoluteMode || upFor > Self.returnSeconds {
                    anchorPending = true          // carry on from the playhead
                }
            }
        } else {
            let earlier = back(0.04), recent = back(0.01)
            let p40 = pitchHistory[earlier], p10 = pitchHistory[recent]
            let level40 = levelHistory[earlier]
            let steady = abs(p10 - p40) < 0.06 * abs(p40) && abs(p40) > 0.5 && abs(p40) < 1.6
            if wasLocked && steady && level40 > 0.005 && inputLevel < level40 * 0.2 {
                coasting = true
                coastPitch = p40
                coastLevel = level40
                coastSerial = decoder.lockSerial
                coastSamples = 0
                levelBackSamples = 0
            }
        }

        pitchHistory[historyWrite] = decoder.pitch
        levelHistory[historyWrite] = inputLevel
        historyWrite = (historyWrite + 1) % count
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

    /// Self-test: plays a 440 Hz tone offline while "scrolling" 10 ms every
    /// 4 buffers, once with jumps and once with nudges, and reports the
    /// largest step between samples (a clean tone stays under ~0.03).
    static func scrubTest() -> String {
        let rate = 48000.0, frames = Int(rate * 10)
        func run(nudge: Bool, stopped: Bool = false) -> Float {
            let l = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            let r = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            for i in 0..<frames { let v = Float(0.5 * sin(2 * .pi * 440 * Double(i) / rate)); l[i] = v; r[i] = v }
            let samples = UnsafeMutablePointer<TrackSamples>.allocate(capacity: 1)
            samples.initialize(to: TrackSamples(left: l, right: r, frames: frames, sampleRate: rate))
            let deck = DeckEngine(definition: .traktorMK2, sampleRate: rate)
            deck.internalMode = true
            _ = deck.exchangeTrack(samples)
            deck.jumpRequest = 1
            deck.transportPlaying = !stopped
            let outL = UnsafeMutablePointer<Float>.allocate(capacity: 128), outR = UnsafeMutablePointer<Float>.allocate(capacity: 128)
            var last: Float = 0, worst: Float = 0
            for b in 0..<600 {
                if b > 40 && b % 4 == 0 {
                    if nudge { deck.nudgeTotal += 0.01 } else { deck.jumpRequest = deck.telemetry.pointee.playhead + 0.01 }
                }
                deck.render(left: outL, right: outR, frames: 128, mix: false)
                for i in 0..<128 {
                    if b > 30 { worst = max(worst, stopped ? abs(outL[i]) : abs(outL[i] - last)) }
                    last = outL[i]
                }
            }
            samples.pointee.free(); samples.deallocate(); outL.deallocate(); outR.deallocate()
            return worst
        }
        return String(format: "Scrub test: largest sample step with jumps %.3f, with nudges %.3f (clean tone ≈ 0.029); loudest output scrolling while stopped %.4f (should be 0)",
                      run(nudge: false), run(nudge: true), run(nudge: false, stopped: true))
    }
}

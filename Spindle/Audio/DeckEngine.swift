//
//  DeckEngine.swift
//  Spindle
//
//  One deck on the audio thread: decodes its timecode input, moves the
//  playhead and plays the loaded track at the record's speed.
//

import AVFoundation
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
    /// The start of the record side the needle is on (else -1).
    var recordStart = -1
    var jumps: Int32 = 0
    var lastJump: Double = 0
    var lostLockEvents: Int32 = 0
    var lastLossRatio: Float = 0
    var lastLossCoasting = false
    /// When this was written (seconds, system uptime clock).
    var stamp: Double = 0
    /// Diagnostics (replay): the speed the track actually played this
    /// buffer, whether the lead-in hold was on, and the record position.
    var played: Double = 0
    var leadIn = false
    var onRecord: Double = 0

    /// The playhead now, between audio buffers: where it was at `stamp`
    /// plus how far it has moved since at the current speed. Waveforms use
    /// this so they move evenly with the screen's frames.
    var smoothPlayhead: Double {
        let dt = min(max(DeckTelemetry.now - stamp, 0), 0.03)
        return playhead + pitch * dt
    }

    /// The playhead at the moment a frame will be shown (its timeline date),
    /// so every frame moves exactly as far as time has passed.
    func playhead(at frame: Date) -> Double {
        let lead = frame.timeIntervalSinceNow                  // frame time ahead of now
        let dt = min(max(DeckTelemetry.now + lead - stamp, 0), 0.05)
        return playhead + pitch * dt
    }

    static var now: Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
}

nonisolated final class DeckEngine: @unchecked Sendable {
    static let scopeFrames = 512

    let decoders: [TimecodeDecoder]
    private var active = 0
    private let canSearch: Bool
    /// Position index (in the format's bit sequence) of the record's start,
    /// calibrated per deck. Set from the UI.
    var startIndex = 0
    /// Whether `startIndex` is the start of the side the needle is on.
    /// Then the record maps straight onto the track, as in Traktor: needle
    /// at the start of the record = start of the track.
    var startKnown = false

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
    /// The needle is in the lead-in: the track holds at its start.
    private var leadIn = false
    /// Samples since the needle came down (the signal was gone, now locked)
    /// or a track was loaded; jumps are allowed for the first second.
    private var sinceLanding = 0
    private var quietSamples = 0
    /// Diagnostics: jumps made, and the size of the last one.
    private var jumpCount = 0
    private var lastJump = 0.0
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
    private var playheadHistory = [Double](repeating: 0, count: 64)
    private var historyWrite = 0
    /// Peak input level of the last buffer.
    private var inputLevel: Float = 0
    private var coastLevel: Float = 0
    private var coastSerial = 0
    private var levelBackSamples = 0
    /// Diagnostics for real needle lifts: how often the lock went while
    /// playing, the level then against just before, and whether it coasted.
    private var lostLockEvents = 0
    private var lastLossRatio: Float = 0
    private var lastLossCoasting = false
    /// A new lock must hold this many bits (0.12 s) before the deck follows it
    /// again: a false lock on landing drops out well before that.
    private let confirmBits: Int

    /// The vinyl this deck reads.
    let definition: TimecodeDefinition

    init(definition: TimecodeDefinition, sampleRate: Double) {
        self.definition = definition
        self.sampleRate = sampleRate
        decoders = DecoderConfig.all.map { TimecodeDecoder(config: $0, definition: definition, sampleRate: sampleRate) }
        canSearch = definition.decodesPosition
        confirmBits = TimecodeDecoder.lockBits + 12
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
    private var wasSearching = false
    private var landingSamples = 0
    private var lastLockID = -1

    func decode(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int) {
        let current = decoders[active]
        // No carrier (needle up, record stopped): nothing to search for.
        let searching = canSearch && unlockedSamples > Int(sampleRate * 0.5) && current.envelope > 0.002 && abs(current.pitch) > 0.02
        // The other decoders sat idle since they last ran and still hold the
        // lock they had then. Measured on a real record: one of them would
        // "lock" at once on that old place (seconds away), so a fast spin
        // threw the track back to wherever the needle once was. They start
        // a search with nothing.
        if searching && !wasSearching {
            for (i, d) in decoders.enumerated() where i != active { d.dropLock() }
        }
        wasSearching = searching
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
            sinceLanding = 0
            playhead = 0
            coasting = false          // a new track waits for the needle
            if absoluteMode && startKnown {
                trackOffset = 0       // the record is the track
                anchorPending = false
            } else {
                anchorPending = true  // tie the track to where the needle is
            }
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
            target = followSpeed(decoder, frames: frames)
            // Needle off = almost no signal (a spinning record still gives
            // plenty). After 0.1 s of that, the next lock is a landing.
            if inputLevel < 0.02 { quietSamples += frames } else if decoder.hasPosition { quietSamples = 0 }
            if quietSamples > Int(0.1 * sampleRate) { sinceLanding = 0 }
            else if decoder.hasPosition && decoder.validBits >= confirmBits { sinceLanding += frames }
            // The needle just came down and the place isn't read yet: wait in
            // silence instead of playing on from where the track was (that
            // was the slip on every needle drop). If it can't be read within
            // 0.4 s, follow the speed after all.
            let landing = quietSamples > Int(0.1 * sampleRate) && inputLevel >= 0.02
            landingSamples = landing ? landingSamples + frames : 0
            if landing && absoluteMode && landingSamples < Int(0.4 * sampleRate) { target = 0 }
            findSide(decoder)
            if anchorPending && decoder.hasPosition && !coasting {
                // Tie the track to the record where it is now.
                trackOffset = decoder.positionSeconds(startIndex: startIndex) - playhead
                anchorPending = false
            }
            let onRecord = decoder.positionSeconds(startIndex: startIndex)
            // The lead-in (needle on the edge, before the side's first
            // groove): the track waits at its start and begins as the needle
            // reaches the first groove, as in Traktor.
            let confirmed = decoder.hasPosition && decoder.validBits >= confirmBits
            leadIn = absoluteMode && startKnown && decoder.hasPosition && !anchorPending
                && onRecord < 0 && onRecord > -30 && (confirmed || leadIn)
            if leadIn {
                trackOffset = 0
                if playhead != 0 { startFade(from: playhead); playhead = 0 }
                target = 0
            }
            position = onRecord - trackOffset
            absolute = absoluteMode && decoder.hasPosition && !anchorPending && !coasting && !leadIn
            if absolute {
                let error = position - playhead
                let length = track.load(ordering: .acquiring)
                    .map { $0.assumingMemoryBound(to: TrackSamples.self).pointee }
                    .map { Double($0.frames) / $0.sampleRate } ?? .infinity
                // As in Mixxx (vinylcontrolxwax.cpp) the track runs at the
                // record's speed; the position only steers it.
                // A fresh lock (the needle just came down, or the reading came
                // back after a spin) puts the track where the record is, with
                // a short crossfade. Taking up seconds of difference by
                // playing faster was what made it slide after a spin.
                let lockID = active << 32 | decoder.lockSerial
                let fresh = confirmed && lockID != lastLockID
                if confirmed { lastLockID = lockID }
                // Landing: 0.1 s. A fresh lock while the record clearly moves: 50 ms
                // (while the needle scrapes on a lift the reading jitters by
                // ±40 ms, which mustn't make it jump back and forth).
                let jumpFrom = sinceLanding < Int(sampleRate) ? 0.1 : (fresh && abs(decoder.pitch) > 0.5 ? 0.05 : 1.5)
                if confirmed && abs(error) > jumpFrom {
                    startFade(from: playhead)
                    jumpCount &+= 1
                    lastJump = position - playhead
                    if position > length - 1 || position < -2 {
                        // The needle is past the end of the track (or well
                        // before its start): the track starts at this groove,
                        // so wherever the needle goes down, it plays.
                        trackOffset += position
                        playhead = 0
                        position = 0
                    } else {
                        playhead = position          // needle drop within the track
                    }
                } else if confirmed {
                    // Small differences (a reading glitch, the speed estimate
                    // a hair off) are taken up gently: at most 2% around
                    // normal speed, which you don't hear; more room when the
                    // record moves faster than that.
                    let room = 0.02 + 0.15 * max(abs(decoder.pitch) - 1, 0)
                    target += min(max(error * 2, -room), room)
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
        if wasLocked && !decoder.hasPosition && !internalMode {
            let old = (historyWrite - 10 + pitchHistory.count) % pitchHistory.count
            let before = levelHistory[old]
            if abs(pitchHistory[old]) > 0.5 && before > 0 {
                lostLockEvents &+= 1
                lastLossRatio = inputLevel / before
                lastLossCoasting = coasting
            }
        }
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
            coasting: coasting,
            recordStart: startKnown ? startIndex : -1,
            jumps: Int32(truncatingIfNeeded: jumpCount),
            lastJump: lastJump,
            lostLockEvents: Int32(truncatingIfNeeded: lostLockEvents),
            lastLossRatio: lastLossRatio,
            lastLossCoasting: lastLossCoasting,
            stamp: DeckTelemetry.now,
            played: target,
            leadIn: leadIn,
            onRecord: decoder.hasPosition ? decoder.positionSeconds(startIndex: startIndex) : .nan)
    }

    /// The input level fell away at once while the record was turning
    /// steadily: the needle was lifted or ran off the end. Keep playing at that
    /// speed. When the needle is back and the decoder has locked afresh, a
    /// landing in absolute mode is always a needle drop.
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
            // Every lock was dropped when the needle came up, so any
            // confirmed lock now is the needle's new place.
            let freshLock = decoder.hasPosition && decoder.validBits >= confirmBits
            if back > 0.02 && (freshLock || (back > 1.5 && decoder.hasPosition)) {
                coasting = false
                // Absolute mode: wherever the needle lands is where the track
                // plays, however long it was up (as in Traktor). Moving the
                // tonearm by hand takes longer than a second, and treating
                // that as "put back" left the track out of step with the
                // record. Relative mode carries on from the playhead.
                if !absoluteMode {
                    anchorPending = true
                }
            }
        } else {
            // Judge the speed from 60–120 ms back: by the time the level has
            // fallen, the last few buffers already hold the scratchy reading
            // of a needle leaving the groove.
            let old = back(0.12), mid = back(0.06)
            let p120 = pitchHistory[old], p60 = pitchHistory[mid]
            let level120 = levelHistory[old]
            let steady = abs(p60 - p120) < 0.06 * abs(p120) && abs(p120) > 0.5 && abs(p120) < 1.6
            // A hand stopping the record also lowers the level, but the
            // decoder keeps reading it, slowing down: that's not a lift.
            let slowing = decoder.hasPosition && abs(decoder.pitch) < abs(p120) * 0.9
            if wasLocked && steady && !slowing && level120 > 0.005 && inputLevel < level120 * 0.35 {
                coasting = true
                for d in decoders { d.dropLock() }
                coastPitch = (p60 + p120) / 2
                coastLevel = level120
                coastSerial = decoder.lockSerial
                coastSamples = 0
                levelBackSamples = 0
                // Undo the slide: put the track where it would be had it
                // carried on at that speed since 60 ms ago.
                let n = Double((historyWrite - mid + count) % count)
                let expected = playheadHistory[mid] + coastPitch * n * bufferSeconds
                if abs(expected - playhead) > 0.003 {
                    startFade(from: playhead)
                    playhead = expected
                }
            }
        }

        pitchHistory[historyWrite] = decoder.pitch
        levelHistory[historyWrite] = inputLevel
        playheadHistory[historyWrite] = playhead
        historyWrite = (historyWrite + 1) % count
    }

    // MARK: Speed from the record

    /// The last moment the record read cleanly (confirmed lock).
    private var goodPitch = 0.0
    private var sinceGood = Int.max / 2
    private var lastPitch = 0.0
    private var lastDelta = 0.0
    private var garbage = 0
    private var needleOff = false
    /// How long a scraping, jumping reading is bridged with the last good
    /// speed before the deck stops.
    private var holdSamples: Int { Int(0.15 * sampleRate) }

    /// Needle on the record: the track follows it. Needle off: it stops.
    /// When the reading turns to noise (the stylus scraping on a lift or a
    /// skip, a speed that jumps from buffer to buffer), the last good speed
    /// is held for a moment instead, so the music doesn't slide; if the
    /// noise goes on, the deck stops and forgets the old position. A lock
    /// lost while the speed still reads smoothly (dust, a worn groove) just
    /// follows the speed.
    private func followSpeed(_ decoder: TimecodeDecoder, frames: Int) -> Double {
        coasting = false
        let pitch = decoder.pitch
        // Scraping reads as a zig-zag: big changes that flip direction from
        // buffer to buffer. A hand spinning the record changes speed fast
        // too, but in one direction at a time.
        let delta = pitch - lastPitch
        let big = 0.15 + 0.05 * abs(pitch)
        let jumpy = abs(delta) > big && abs(lastDelta) > big && delta * lastDelta < 0
        lastDelta = delta
        lastPitch = pitch
        if decoder.hasPosition && decoder.validBits >= confirmBits {
            goodPitch = pitch
            sinceGood = 0
            garbage = 0
            return pitch
        }
        sinceGood += frames
        // Needle off: almost no signal. Stop, and clear the decoders' lock
        // once, so the old position can't carry over to where it lands.
        if inputLevel < 0.02 {
            if !needleOff { for d in decoders { d.dropLock() } }
            needleOff = true
            return 0
        }
        needleOff = false
        if decoder.hasPosition { return pitch }
        garbage = jumpy ? garbage + frames : max(0, garbage - frames)
        // A zig-zag reading (the stylus scraping as it lifts) is bridged with
        // the last good speed for a moment; after that the record is followed
        // again: a hand spinning it reads rough too, and must not be stopped.
        if garbage > 0 && sinceGood < holdSamples { return goodPitch }
        return pitch
    }

    /// Counts the record from the outer edge of the side the needle is on
    /// (known per vinyl format). Switching sides keeps the track where it is;
    /// the next load maps it from the new side's edge.
    private func findSide(_ decoder: TimecodeDecoder) {
        guard decoder.hasPosition, decoder.validBits >= confirmBits else { return }
        let period = definition.positionModulus
        let index = period > 0 ? ((decoder.positionIndex % period) + period) % period : decoder.positionIndex
        // On MK2 the code runs straight on from one side into the next, and
        // a needle on a side's edge reads a few seconds before its first
        // groove. So a side counts from 30 s before its start, and once a
        // side is found it only changes when the needle is clearly (60 s)
        // past that point: no flipping at the edge.
        let early = Int(30 * definition.bitRate), clear = Int(60 * definition.bitRate)
        func side(_ margin: Int) -> Int {
            definition.sideStarts.last { index >= $0 - margin } ?? definition.sideStarts[0]
        }
        var found = side(early)
        if startKnown && found != startIndex {
            // Moving up needs the needle well into the new side; moving down,
            // well before the current side's edge.
            if found > startIndex { if index < found - early + clear { found = startIndex } }
            else if index >= startIndex - early - clear { found = startIndex }
        }
        guard !startKnown || found != startIndex else { return }
        if startKnown {
            // A side change mid-track (the record flipped): the track carries
            // on where it is; the next load maps it from the new side's edge.
            trackOffset -= Double(found - startIndex) / definition.bitRate
        }
        startIndex = found
        startKnown = true
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

    /// Self-test on a simulated MK2 record (the needle comes up the way a
    /// real one does: ~30 ms of fading, scratchy signal):
    ///  · drops: needle up 0.5 s / 2.5 s, down 90 s further on; track minus
    ///    record every half second after landing (0 = following)
    ///  · slide: how far the track strays in the 0.4 s after the lift
    ///  · mix in: side 1 found at the first groove played (60 s), a new
    ///    track loaded with the needle at 200 s, needle moved back to 60 s;
    ///    the playhead every half second after landing (should be ~0.5, 1…)
    static func needleTest() -> String {
        let rate = 48000.0, block = 128, def = TimecodeDefinition.traktorMK2
        func makeTrack() -> UnsafeMutablePointer<TrackSamples> {
            let frames = Int(rate * 600)
            let l = UnsafeMutablePointer<Float>.allocate(capacity: frames), r = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            l.initialize(repeating: 0, count: frames); r.initialize(repeating: 0, count: frames)
            let samples = UnsafeMutablePointer<TrackSamples>.allocate(capacity: 1)
            samples.initialize(to: TrackSamples(left: l, right: r, frames: frames, sampleRate: rate))
            return samples
        }
        let inL = UnsafeMutablePointer<Float>.allocate(capacity: block), inR = UnsafeMutablePointer<Float>.allocate(capacity: block)
        let outL = UnsafeMutablePointer<Float>.allocate(capacity: block), outR = UnsafeMutablePointer<Float>.allocate(capacity: block)
        defer { [inL, inR, outL, outR].forEach { $0.deallocate() } }

        /// Plays until `until`, calling `each` after every block with the time.
        func play(_ deck: DeckEngine, _ sim: TimecodeSimulator, _ t: inout Double, until: Double, _ each: (Double) -> Void = { _ in }) {
            while t < until {
                sim.generate(left: inL, right: inR, frames: block, sampleRate: rate)
                deck.decode(left: inL, right: inR, frames: block)
                deck.render(left: outL, right: outR, frames: block, mix: false)
                t += Double(block) / rate
                each(t)
            }
        }
        func needle(_ sim: TimecodeSimulator) -> Double { sim.phase / def.resolution }

        func drop(up: Double) -> String {
            let deck = DeckEngine(definition: def, sampleRate: rate)
            let track = makeTrack()
            _ = deck.exchangeTrack(track)
            let sim = TimecodeSimulator(definition: def, startSeconds: 60)
            sim.realisticLift = true
            sim.targetPitch = 1
            var t = 0.0
            play(deck, sim, &t, until: 4)
            let offset = needle(sim) - deck.telemetry.pointee.playhead
            // The lift: how far the track strays from steady play.
            let liftPlay = deck.telemetry.pointee.playhead, liftT = t
            var slide = 0.0
            sim.lifted = true
            // The scrape (first 0.1 s): the track should go on evenly.
            play(deck, sim, &t, until: 4.1) { now in
                slide = max(slide, abs(deck.telemetry.pointee.playhead - (liftPlay + (now - liftT))))
            }
            // Needle off: the track should stand still.
            play(deck, sim, &t, until: 4.4)
            let off = deck.telemetry.pointee.playhead
            play(deck, sim, &t, until: 4 + up)
            let movedOff = deck.telemetry.pointee.playhead - off
            sim.seek(seconds: needle(sim) + 90)
            sim.lifted = false
            var marks: [String] = []
            var next = t + 0.1
            play(deck, sim, &t, until: t + 1.01) { now in
                if now >= next {
                    marks.append(String(format: "%+.2f", deck.telemetry.pointee.playhead - (needle(sim) - offset)))
                    next += 0.1
                }
            }
            track.pointee.free(); track.deallocate()
            return String(format: "up %.1f s: slide %.3f s, moved %.3f s with the needle off, then ", up, slide, movedOff) + marks.joined(separator: " ")
        }

        func mixIn() -> String {
            let deck = DeckEngine(definition: def, sampleRate: rate)
            let first = makeTrack()
            _ = deck.exchangeTrack(first)
            let sim = TimecodeSimulator(definition: def, startSeconds: 60)
            sim.realisticLift = true
            sim.targetPitch = 1
            var t = 0.0
            play(deck, sim, &t, until: 3)                 // learns the start at ~60 s
            sim.lifted = true
            play(deck, sim, &t, until: 3.5)
            sim.seek(seconds: 200)
            sim.lifted = false
            play(deck, sim, &t, until: 5)                 // needle mid-record
            let second = makeTrack()
            let old = deck.exchangeTrack(second)          // load the next track there
            play(deck, sim, &t, until: 6)
            let atLoad = deck.telemetry.pointee.playhead
            sim.lifted = true
            play(deck, sim, &t, until: 8)                 // tonearm moved by hand
            sim.seek(seconds: 16.2)                       // the side's outer edge
            sim.lifted = false
            var marks: [String] = []
            var next = t + 0.1
            play(deck, sim, &t, until: t + 2.01) { now in
                if now >= next {
                    let tel = deck.telemetry.pointee
                    marks.append(String(format: "%.2f%@%@/%d", tel.playhead, tel.coasting ? "c" : "", tel.hasPosition ? "" : "?", tel.validBits))
                    next += 0.1
                }
            }
            old?.pointee.free(); old?.deallocate()
            second.pointee.free(); second.deallocate()
            return String(format: "loaded at 200 s → %.1f s into the track; back at the start: ", atLoad) + marks.joined(separator: " ")
        }

        func handStop() -> String {
            let deck = DeckEngine(definition: def, sampleRate: rate)
            let track = makeTrack()
            _ = deck.exchangeTrack(track)
            let sim = TimecodeSimulator(definition: def, startSeconds: 60)
            sim.targetPitch = 1
            var t = 0.0
            play(deck, sim, &t, until: 3)
            sim.targetPitch = 0                            // a hand on the record
            var coasted = false
            play(deck, sim, &t, until: 4) { _ in coasted = coasted || deck.telemetry.pointee.coasting }
            let a = deck.telemetry.pointee.playhead
            play(deck, sim, &t, until: 5)
            let moved = deck.telemetry.pointee.playhead - a
            track.pointee.free(); track.deallocate()
            return String(format: "hand stop: %@, moved %.3f s in the next second", coasted ? "CARRIED ON (wrong)" : "stopped", moved)
        }

        /// Fast spins by hand: 4× forwards, 4× backwards, then play. The
        /// track should stay with the record throughout (largest gap, and
        /// the gap at the end).
        func spin() -> String {
            let deck = DeckEngine(definition: def, sampleRate: rate)
            let track = makeTrack()
            _ = deck.exchangeTrack(track)
            let sim = TimecodeSimulator(definition: def, startSeconds: 120)
            sim.targetPitch = 1
            var t = 0.0
            play(deck, sim, &t, until: 3)
            // A hand turning the record round: ~10 ms (measured on real
            // scratches: 35–120 ms below 1.5×, so this is on the fast side).
            sim.inertia = 0.002
            let offset = needle(sim) - deck.telemetry.pointee.playhead
            var worst = 0.0
            func gap() -> Double { deck.telemetry.pointee.playhead - (needle(sim) - offset) }
            var trace: [String] = []
            var nextTrace = t
            var jumps = 0
            var lastPlay = deck.telemetry.pointee.playhead
            for (speed, until) in [(4.0, 3.5), (-4.0, 4.0), (6.0, 4.3), (-6.0, 4.6), (2.0, 4.8), (-3.0, 5.0), (1.0, 6.5)] {
                sim.targetPitch = speed
                play(deck, sim, &t, until: until) { now in
                    worst = max(worst, abs(gap()))
                    let p = deck.telemetry.pointee.playhead
                    if abs(p - lastPlay) > 0.06 { jumps += 1 }     // more than 6× speed in one block
                    lastPlay = p
                    if now >= nextTrace && now < 5.2 {
                        let tel = deck.telemetry.pointee
                        trace.append(String(format: "%.1f/%.1f%@ g%.2f", sim.pitch, tel.pitch, tel.hasPosition ? "" : "?", gap()))
                        nextTrace += 0.05
                    }
                }
            }
            spindleLog.notice("Spin trace (record/read): \(trace.joined(separator: " "))")
            let end = gap()
            track.pointee.free(); track.deallocate()
            return String(format: "fast spins: largest gap %.2f s, at the end %+.3f s, %d jumps", worst, end, jumps)
        }

        /// Every vinyl format: lock onto a simulated record at 60 s and read
        /// where it is (should be ~61.5 s after 1.5 s of play).
        func formats() -> String {
            TimecodeDefinition.all.map { d in
                let deck = DeckEngine(definition: d, sampleRate: rate)
                let sim = TimecodeSimulator(definition: d, startSeconds: 60)
                sim.targetPitch = 1
                var t = 0.0
                play(deck, sim, &t, until: 1.5)
                let decoder = deck.decoders[deck.active]
                let at = decoder.hasPosition ? decoder.positionSeconds() : -1
                let truth = sim.phase / d.resolution
                return String(format: "%@ %@ (read %.2f s, record %.2f s)", d.id, decoder.hasPosition && abs(at - truth) < 0.05 ? "ok" : "FAIL", at, truth)
            }.joined(separator: ", ")
        }

        /// A 5-minute track loaded while the needle is 8 minutes into the
        /// record: it should start at the needle (playhead ~0, 0.5, 1…).
        func lateLoad() -> String {
            let deck = DeckEngine(definition: def, sampleRate: rate)
            let frames = Int(rate * 300)
            let l = UnsafeMutablePointer<Float>.allocate(capacity: frames), r = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            l.initialize(repeating: 0, count: frames); r.initialize(repeating: 0, count: frames)
            let short = UnsafeMutablePointer<TrackSamples>.allocate(capacity: 1)
            short.initialize(to: TrackSamples(left: l, right: r, frames: frames, sampleRate: rate))
            let first = makeTrack()
            _ = deck.exchangeTrack(first)
            let sim = TimecodeSimulator(definition: def, startSeconds: 10)
            sim.targetPitch = 1
            var t = 0.0
            play(deck, sim, &t, until: 2)                  // learns the start at ~10 s
            sim.seek(seconds: 490)                         // needle 8 minutes in
            play(deck, sim, &t, until: 3)
            let old = deck.exchangeTrack(short)
            var marks: [String] = []
            var next = t + 0.5
            play(deck, sim, &t, until: t + 2.01) { now in
                if now >= next { marks.append(String(format: "%.2f", deck.telemetry.pointee.playhead)); next += 0.5 }
            }
            old?.pointee.free(); old?.deallocate(); short.pointee.free(); short.deallocate()
            return "5-min track loaded 8 min into the record: " + marks.joined(separator: " ")
        }

        /// The second MK2 side: needle on its outer edge (~921 s into the
        /// sequence) with a track loaded: the track plays from its top.
        func sideTwo() -> String {
            let deck = DeckEngine(definition: def, sampleRate: rate)
            let track = makeTrack()
            _ = deck.exchangeTrack(track)
            let sim = TimecodeSimulator(definition: def, startSeconds: 913)   // just before side 2's first groove
            sim.targetPitch = 1
            var t = 0.0
            var marks: [String] = []
            var next = 1.0
            play(deck, sim, &t, until: 11.01) { now in
                if now >= next { marks.append(String(format: "%.2f", deck.telemetry.pointee.playhead)); next += 1 }
            }
            track.pointee.free(); track.deallocate()
            return "side 2, needle 8.3 s before its first groove, each second: " + marks.joined(separator: " ")
        }

        /// A rough 3× spin for 2 s (zig-zag readings, strong signal): the
        /// track should keep moving with the record, not stop.
        func roughSpin() -> String {
            let deck = DeckEngine(definition: def, sampleRate: rate)
            let track = makeTrack()
            _ = deck.exchangeTrack(track)
            let sim = TimecodeSimulator(definition: def, startSeconds: 120)
            sim.targetPitch = 1
            var t = 0.0
            play(deck, sim, &t, until: 3)
            let p0 = deck.telemetry.pointee.playhead, n0 = needle(sim)
            sim.inertia = 0.02
            sim.targetPitch = 3
            sim.roughness = 0.4
            var stopped = 0
            play(deck, sim, &t, until: 5) { _ in if abs(deck.telemetry.pointee.pitch) < 0.2 { stopped += 1 } }
            let moved = deck.telemetry.pointee.playhead - p0, record = needle(sim) - n0
            track.pointee.free(); track.deallocate()
            return String(format: "rough 3× spin: track moved %.2f s with the record's %.2f s, stopped %.2f s of 2", moved, record, Double(stopped * block) / rate)
        }

        return "Needle test · " + roughSpin() + " · " + sideTwo() + " · " + lateLoad() + " · " + formats() + " · " + spin() + " · " + drop(up: 0.5) + " · " + drop(up: 2.5) + " · mix in: " + mixIn() + " · " + handStop()
    }

    /// Self-test: a click on every beat at 128 BPM; loop 4 beats while
    /// playing (like a loop slot pressed mid-beat) and report the gaps
    /// between clicks in the output (all should be one beat, 468.75 ms).
    /// SPINDLE_REPLAY=<wav>: runs a captured deck input (SPINDLE_CAPTURE)
    /// through a deck as the app would, with a 296 s track loaded at the
    /// given seconds, and writes a trace (one row per 128-frame buffer) to
    /// `out`. Returns a summary.
    static func replay(path: String, out: String, vinyl: TimecodeDefinition, absolute: Bool, loads: [Double]) -> String {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil, let ch = buffer.floatChannelData else { return "Replay: can't read \(path)" }
        let rate = file.processingFormat.sampleRate, total = Int(buffer.frameLength), block = 128
        let deck = DeckEngine(definition: vinyl, sampleRate: rate)
        deck.absoluteMode = absolute
        deck.startIndex = vinyl.sideStarts[0]
        deck.startKnown = false
        var tracks: [UnsafeMutablePointer<TrackSamples>] = []
        func makeTrack() -> UnsafeMutablePointer<TrackSamples> {
            let frames = Int(rate * 296.3)
            let l = UnsafeMutablePointer<Float>.allocate(capacity: frames), r = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            l.initialize(repeating: 0, count: frames); r.initialize(repeating: 0, count: frames)
            let t = UnsafeMutablePointer<TrackSamples>.allocate(capacity: 1)
            t.initialize(to: TrackSamples(left: l, right: r, frames: frames, sampleRate: rate))
            tracks.append(t)
            return t
        }
        let outL = UnsafeMutablePointer<Float>.allocate(capacity: block), outR = UnsafeMutablePointer<Float>.allocate(capacity: block)
        var pending = loads.sorted()
        var rows = "t,level,signal,has,bits,config,index,onRecord,pitch,played,playhead,leadIn,absolute,jumps\n"
        rows.reserveCapacity(total / block * 90)
        var probeRows = "t,config,pitch,jump,cycle,offset\n"
        var probeT = 0.0
        if let probePath = ProcessInfo.processInfo.environment["SPINDLE_REPLAY_PROBE"] {
            _ = probePath
            TimecodeDecoder.probe = { d, pitch, jump, cycle, offset in
                guard d === deck.decoders[deck.active] else { return }
                probeRows += String(format: "%.5f,%d,%.3f,%.3f,%d,%d\n", probeT, deck.active, pitch, jump, cycle, offset)
            }
        }
        var at = 0
        while at + block <= total {
            probeT = Double(at) / rate
            let t = Double(at) / rate
            if let next = pending.first, t >= next { pending.removeFirst(); _ = deck.exchangeTrack(makeTrack()) }
            deck.decode(left: ch[0] + at, right: ch[1] + at, frames: block)
            deck.render(left: outL, right: outR, frames: block, mix: false)
            let x = deck.telemetry.pointee
            rows += String(format: "%.4f,%.3f,%.3f,%d,%d,%d,%d,%.3f,%.3f,%.3f,%.4f,%d,%d,%d\n",
                           t, deck.inputLevel, x.signal, x.hasPosition ? 1 : 0, x.validBits, x.activeConfig,
                           x.hasPosition ? x.positionIndex : -1, x.onRecord, x.pitch, x.played, x.playhead,
                           x.leadIn ? 1 : 0, x.absolute ? 1 : 0, x.jumps)
            at += block
        }
        try? rows.write(toFile: out, atomically: true, encoding: .utf8)
        if let probePath = ProcessInfo.processInfo.environment["SPINDLE_REPLAY_PROBE"] {
            TimecodeDecoder.probe = nil
            try? probeRows.write(toFile: probePath, atomically: true, encoding: .utf8)
        }
        outL.deallocate(); outR.deallocate()
        for t in tracks { t.pointee.free(); t.deallocate() }
        return String(format: "Replay %@: %.1f s, %d jumps → %@", (path as NSString).lastPathComponent,
                      Double(total) / rate, deck.jumpCount, out)
    }

    static func loopTest() -> String {
        let rate = 48000.0, frames = Int(rate * 30), beat = 60.0 / 128
        let l = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        let r = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        l.initialize(repeating: 0, count: frames); r.initialize(repeating: 0, count: frames)
        var t = 0.0
        while t < 29 { let i = Int(t * rate); for k in 0..<48 { l[i + k] = 0.9 * Float(1 - Double(k) / 48); r[i + k] = l[i + k] }; t += beat }
        let samples = UnsafeMutablePointer<TrackSamples>.allocate(capacity: 1)
        samples.initialize(to: TrackSamples(left: l, right: r, frames: frames, sampleRate: rate))
        let deck = DeckEngine(definition: .traktorMK2, sampleRate: rate)
        deck.internalMode = true
        _ = deck.exchangeTrack(samples)
        deck.jumpRequest = 0.5
        deck.transportPlaying = true
        let out = UnsafeMutablePointer<Float>.allocate(capacity: 128), out2 = UnsafeMutablePointer<Float>.allocate(capacity: 128)
        var clicks: [Double] = []
        var peaks: [String] = []
        var n = 0, above = false
        for b in 0..<3000 {
            if b == 900 {
                // Press a loop slot: 4 beats from beat 8 (3.75 s), mid-beat.
                deck.loopActive = false
                deck.jumpRequest = 8 * beat
                deck.loopStart = 8 * beat
                deck.loopLength = 4 * beat
                deck.loopActive = true
            }
            deck.render(left: out, right: out2, frames: 128, mix: false)
            let m = (0..<128).map { abs(out[$0]) }.max() ?? 0
            if m > 0.1 && peaks.count < 12 { peaks.append(String(format: "b%d %.2f@%.3f", b, m, deck.telemetry.pointee.playhead)) }
            for i in 0..<128 {
                let v = abs(out[i])
                if v > 0.5 && !above { clicks.append(Double(n + i) / rate) }
                above = v > 0.3
            }
            n += 128
        }
        let gaps = zip(clicks.dropFirst(), clicks).map { ($0 - $1) * 1000 }
        let odd = gaps.enumerated().filter { abs($0.element - beat * 1000) > 2 }.map { String(format: "#%d %.1f ms", $0.offset, $0.element) }
        samples.pointee.free(); samples.deallocate(); out.deallocate(); out2.deallocate()
        return "Loop test: \(gaps.count) gaps, uneven ones: " + (odd.isEmpty ? "none" : odd.joined(separator: ", "))
            + " · peaks " + peaks.joined(separator: " ") + " · clicks at " + clicks.map { String(format: "%.3f", $0) }.joined(separator: " ")
    }
}

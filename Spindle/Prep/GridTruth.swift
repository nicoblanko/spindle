//
//  GridTruth.swift
//  Spindle
//
//  Self-test (SPINDLE_GRIDTRUTH): builds a techno-like test track where
//  every kick's time is known (128 BPM, first kick at 0.300 s, off-beat
//  bass and hi-hats), as WAV and as MP3, and reports where the grid
//  detector puts the beat and where the player's decoded audio has the
//  first kick. Both should be 0 ms off.
//

@preconcurrency import AVFoundation
import Foundation

nonisolated enum GridTruth {
    nonisolated(unsafe) static var bpm = 128.0
    nonisolated(unsafe) static var firstKick = 0.300
    nonisolated(unsafe) static var click = true

    static func run() async -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gridtruth", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let wav = dir.appendingPathComponent("truth.wav"), mp3 = dir.appendingPathComponent("truth.mp3")
        var out: [String] = []
        for (b, f, c) in [(128.0, 0.300, true), (140.0, 0.123, false)] {
            bpm = b; firstKick = f; click = c
            out.append(await runOne(wav: wav, mp3: mp3))
        }
        return out.joined(separator: "\n")
    }

    private static func runOne(wav: URL, mp3: URL) async -> String {
        do { try write(wav) } catch { return "Grid truth: couldn't write test file: \(error)" }
        try? FileManager.default.removeItem(at: mp3)
        try? MP3Encoder.encode(from: wav, to: mp3, kbps: 320)
        var lines: [String] = []
        for url in [wav, mp3] where FileManager.default.fileExists(atPath: url.path) {
            lines.append(await measure(url))
        }
        return String(format: "Grid truth (%.0f BPM, first kick %.0f ms, %@):\n", bpm, firstKick * 1000, click ? "with click" : "soft kick") + lines.joined(separator: "\n")
    }

    private static func measure(_ url: URL) async -> String {
        let beat = 60 / bpm
        func wrap(_ x: Double) -> Double { var d = x.truncatingRemainder(dividingBy: beat); if d > beat / 2 { d -= beat }; if d < -beat / 2 { d += beat }; return d }
        var parts = [url.pathExtension.uppercased()]
        if let s = try? PrepAnalyzer.suggest(url: url, bpm: nil) {
            parts.append(String(format: "grid %.3f BPM, beat off by %+.1f ms", s.prep.bpm, wrap(s.prep.gridOffset - firstKick) * 1000))
        }
        // Where the analysis decoder (22 kHz) has the first kick.
        if let mono = try? TrackAnalyzer.decodeMono(url: url), let i = mono.firstIndex(where: { abs($0) > 0.2 }) {
            parts.append(String(format: "analysis audio %+.1f ms", (Double(i) / TrackAnalyzer.sampleRate - firstKick) * 1000))
        }
        // Where the player (48 kHz) has it.
        if let t = try? await TrackLoader.load(url: url, sampleRate: 48000) {
            let s = t.samples.pointee
            var i = 0
            while i < s.frames && abs(s.left[i]) < 0.2 { i += 1 }
            parts.append(String(format: "player audio %+.1f ms", (Double(i) / 48000 - firstKick) * 1000))
            s.free(); t.samples.deallocate()
        }
        return parts.joined(separator: " · ")
    }

    /// 2 minutes: a kick on every beat (pitch-dropping sine with a click),
    /// an off-beat bass note and off-beat hi-hats.
    private static func write(_ url: URL) throws {
        let rate = 44100.0, seconds = 120.0, n = Int(rate * seconds)
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
        buffer.frameLength = AVAudioFrameCount(n)
        let l = buffer.floatChannelData![0], r = buffer.floatChannelData![1]
        for i in 0..<n { l[i] = 0; r[i] = 0 }
        let beat = 60 / bpm
        var seed: UInt32 = 1
        func noise() -> Float { seed = seed &* 1664525 &+ 1013904223; return Float(seed >> 8) / Float(1 << 24) * 2 - 1 }
        var t = firstKick
        while t < seconds - 1 {
            let k0 = Int(t * rate)
            var phase = 0.0
            for j in 0..<Int(0.25 * rate) {          // kick
                let tt = Double(j) / rate
                phase += 2 * .pi * (45 + 110 * exp(-tt * 30)) / rate
                var v = Float(sin(phase) * exp(-tt * 9)) * 0.8
                if click && j < 44 { v += noise() * 0.3 * Float(1 - Double(j) / 44) }   // click
                if !click && j < 88 { v *= Float(j) / 88 }                              // 2 ms soft attack
                l[k0 + j] += v; r[k0 + j] += v
            }
            let b0 = Int((t + beat / 2) * rate)       // off-beat bass
            for j in 0..<Int(0.12 * rate) {
                let tt = Double(j) / rate
                let v = Float(sin(2 * .pi * 70 * tt) * exp(-tt * 18)) * 0.35
                l[b0 + j] += v; r[b0 + j] += v
            }
            for j in 0..<Int(0.04 * rate) {            // off-beat hat
                let v = noise() * Float(exp(-Double(j) / rate * 90)) * 0.15
                l[b0 + j] += v; r[b0 + j] += v
            }
            t += beat
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}

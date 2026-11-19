//
//  TrackAnalyzer.swift
//  Spindle
//
//  Analyses a track for the Organize page: BPM, key (Camelot), energy
//  (E1–E10), intro and outro type, duration. Written for Spindle with
//  Accelerate; no Essentia or libKeyFinder code (both (A)GPL).
//
//  • Audio is decoded to mono at 22,050 Hz.
//  • BPM: spectral-flux onset strength (172 frames/s), autocorrelated; each
//    candidate tempo is scored on its first four multiples, with a mild
//    preference around 125 BPM so half/double tempo is resolved the DJ way.
//  • Key: a pitch-class profile (chroma) summed over the track, correlated
//    with major and minor key profiles in all 12 transpositions.
//  • Energy: loudness, onset density and brightness, mapped to 1–10.
//  • Intro/outro: kick presence (low-band attacks relative to the whole
//    track) and level over the first and last 32 beats.
//

import Accelerate
import AVFoundation
import Foundation

nonisolated enum SectionType: String, Codable, Sendable, CaseIterable {
    case beat = "Beat"
    case breakdown = "Breakdown"
    case ambient = "Ambient"
}

nonisolated struct TrackAnalysis: Codable, Sendable, Equatable {
    var bpm: Double
    /// 0 = C … 11 = B.
    var keyRoot: Int
    var keyMinor: Bool
    var energy: Int
    var intro: SectionType
    var outro: SectionType
    var duration: Double
    /// How clearly the key won (correlation gap to the runner-up).
    var keyConfidence: Double

    /// Camelot code, e.g. "8A" for A minor, "8B" for C major.
    var camelot: String { Self.camelot(root: keyRoot, minor: keyMinor) }

    var keyName: String {
        let names = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]
        return names[keyRoot] + (keyMinor ? "m" : "")
    }

    /// Camelot number 1…12.
    var camelotNumber: Int { Self.camelotNumber(root: keyRoot, minor: keyMinor) }

    static func camelotNumber(root: Int, minor: Bool) -> Int {
        // Major: C = 8B, each fifth up adds one. Minor: A = 8A.
        let tonic = minor ? (root + 3) % 12 : root   // relative major
        return ((tonic * 7) % 12 + 7) % 12 + 1
    }

    static func camelot(root: Int, minor: Bool) -> String {
        "\(camelotNumber(root: root, minor: minor))\(minor ? "A" : "B")"
    }
}

nonisolated enum AnalysisError: LocalizedError {
    case unreadable(String)
    var errorDescription: String? {
        switch self { case .unreadable(let why): "Couldn't analyse: \(why)" }
    }
}

nonisolated enum TrackAnalyzer {
    static let sampleRate = 22_050.0

    static func analyze(url: URL) throws -> TrackAnalysis {
        let mono = try decodeMono(url: url)
        guard mono.count > Int(sampleRate * 10) else { throw AnalysisError.unreadable("shorter than 10 s") }

        let onset = OnsetFeatures(samples: mono, sampleRate: sampleRate)
        let bpm = estimateTempo(onset.full, frameRate: onset.frameRate)
        let key = estimateKey(mono)
        let energy = estimateEnergy(mono, onset: onset)
        let beatSeconds = 60 / bpm
        let window = 32 * beatSeconds
        let intro = classifySection(mono, onset: onset, from: 0, to: window, bpm: bpm)
        let duration = Double(mono.count) / sampleRate
        let outro = classifySection(mono, onset: onset, from: max(0, duration - window), to: duration, bpm: bpm)

        return TrackAnalysis(bpm: bpm, keyRoot: key.root, keyMinor: key.minor, energy: energy,
                             intro: intro, outro: outro, duration: duration, keyConfidence: key.confidence)
    }

    // MARK: Decoding

    static func decodeMono(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let source = file.processingFormat
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: source, to: target) else {
            throw AnalysisError.unreadable("unsupported format")
        }
        converter.downmix = true
        let chunk: AVAudioFrameCount = 65_536
        guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: chunk),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(chunk) * sampleRate / source.sampleRate) + 1024) else {
            throw AnalysisError.unreadable("out of memory")
        }
        var result: [Float] = []
        result.reserveCapacity(Int(Double(file.length) * sampleRate / source.sampleRate) + 1024)
        var finished = false
        while !finished {
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, outStatus in
                do {
                    try file.read(into: input, frameCount: chunk)
                } catch {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                if input.frameLength == 0 {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return input
            }
            if let error { throw error }
            if let data = output.floatChannelData, output.frameLength > 0 {
                result.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
            }
            if status == .endOfStream || status == .error || output.frameLength == 0 { finished = true }
        }
        return result
    }

    // MARK: Onsets

    /// Spectral-flux onset strength, full-band and low-band (kick), at 172 frames/s.
    struct OnsetFeatures {
        let full: [Float]
        let low: [Float]
        let rms: [Float]          // per frame
        let centroid: [Float]     // Hz, per frame
        let frameRate: Double

        init(samples: [Float], sampleRate: Double) {
            let n = 1024, hop = 128
            frameRate = sampleRate / Double(hop)
            let frames = max(0, (samples.count - n) / hop)
            let fft = RealFFT(size: n)
            var previous = [Float](repeating: 0, count: n / 2)
            var full = [Float](repeating: 0, count: frames)
            var low = [Float](repeating: 0, count: frames)
            var rms = [Float](repeating: 0, count: frames)
            var centroid = [Float](repeating: 0, count: frames)
            let binHz = Float(sampleRate) / Float(n)
            let lowBins = Int(150 / binHz)
            let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)
            var frame = [Float](repeating: 0, count: n)
            samples.withUnsafeBufferPointer { s in
                for f in 0..<frames {
                    let start = f * hop
                    vDSP.multiply(UnsafeBufferPointer(rebasing: s[start..<(start + n)]), window, result: &frame)
                    var magnitude = fft.magnitudes(frame)
                    // Log compression keeps quiet onsets visible.
                    var energy: Float = 0
                    var weighted: Float = 0
                    for i in 0..<magnitude.count {
                        energy += magnitude[i]
                        weighted += magnitude[i] * Float(i) * binHz
                        magnitude[i] = log1p(100 * magnitude[i])
                    }
                    var fluxFull: Float = 0, fluxLow: Float = 0
                    for i in 1..<magnitude.count {
                        let d = magnitude[i] - previous[i]
                        if d > 0 {
                            fluxFull += d
                            if i <= lowBins { fluxLow += d }
                        }
                    }
                    full[f] = fluxFull
                    low[f] = fluxLow
                    centroid[f] = energy > 0 ? weighted / energy : 0
                    var sum: Float = 0
                    vDSP_svesq(s.baseAddress! + start, 1, &sum, vDSP_Length(n))
                    rms[f] = sqrt(sum / Float(n))
                    previous = magnitude
                }
            }
            self.full = Self.highPass(full)
            self.low = Self.highPass(low)
            self.rms = rms
            self.centroid = centroid
        }

        /// Removes the slow trend so autocorrelation sees the pulse.
        private static func highPass(_ x: [Float]) -> [Float] {
            guard x.count > 64 else { return x }
            let w = 32
            var out = x
            var sum: Float = x[0..<min(w, x.count)].reduce(0, +)
            for i in 0..<x.count {
                let lo = max(0, i - w / 2), hi = min(x.count, i + w / 2)
                if i == 0 { sum = x[lo..<hi].reduce(0, +) } else {
                    if i + w / 2 - 1 < x.count { sum += x[i + w / 2 - 1] }
                    if i - w / 2 - 1 >= 0 { sum -= x[i - w / 2 - 1] }
                }
                out[i] = max(0, x[i] - sum / Float(hi - lo))
            }
            return out
        }
    }

    // MARK: Tempo

    static let tempoPriorWidth = 0.45

    static func estimateTempo(_ onset: [Float], frameRate: Double) -> Double {
        let minBPM = 60.0, maxBPM = 200.0
        let maxLag = Int(frameRate * 60 / minBPM * 16) + 2
        let ac = autocorrelation(onset, maxLag: min(maxLag, onset.count - 1))

        func acAt(_ lag: Double) -> Double {
            let i = Int(lag)
            guard i + 1 < ac.count, i >= 0 else { return 0 }
            let f = lag - Double(i)
            return Double(ac[i]) * (1 - f) + Double(ac[i + 1]) * f
        }

        // 1. Coarse: the beat and its first four multiples.
        func score(_ bpm: Double) -> Double {
            let lag = frameRate * 60 / bpm
            var s = 0.0
            for k in 1...4 { s += acAt(lag * Double(k)) / Double(k).squareRoot() }
            return s
        }
        var best = 120.0, bestScore = -Double.infinity
        var bpm = minBPM
        while bpm <= maxBPM {
            // DJ prior around 125 settles half/double ties.
            let prior = exp(-pow(log2(bpm / 125), 2) / (2 * tempoPriorWidth * tempoPriorWidth))
            let s = score(bpm) * prior
            if s > bestScore { bestScore = s; best = bpm }
            bpm += 0.1
        }

        // 2. Fine: 16 beats of lag pin the tempo to ~0.02 BPM.
        func fine(_ bpm: Double) -> Double {
            let lag = frameRate * 60 / bpm
            var s = 0.0
            for k in [4.0, 8.0, 12.0, 16.0] { s += acAt(lag * k) }
            return s
        }
        var refined = best, refinedScore = -Double.infinity
        var candidate = best - 0.6
        while candidate <= best + 0.6 {
            let s = fine(candidate)
            if s > refinedScore { refinedScore = s; refined = candidate }
            candidate += 0.01
        }

        // 3. DJ range: fold into 85–175 BPM.
        while refined < 85 { refined *= 2 }
        while refined > 175 { refined /= 2 }
        // Electronic music is almost always produced at a whole BPM.
        let rounded = refined.rounded()
        return abs(refined - rounded) < 0.15 ? rounded : (refined * 10).rounded() / 10
    }

    static func autocorrelation(_ x: [Float], maxLag: Int) -> [Float] {
        let n = x.count
        guard n > maxLag else { return [Float](repeating: 0, count: maxLag + 1) }
        var mean: Float = 0
        vDSP_meanv(x, 1, &mean, vDSP_Length(n))
        let centred = x.map { $0 - mean }
        var result = [Float](repeating: 0, count: maxLag + 1)
        centred.withUnsafeBufferPointer { p in
            for lag in 0...maxLag {
                var dot: Float = 0
                vDSP_dotpr(p.baseAddress!, 1, p.baseAddress! + lag, 1, &dot, vDSP_Length(n - lag))
                result[lag] = dot / Float(n - lag)
            }
        }
        return result
    }

    // MARK: Key

    // Shaath's profiles (Krumhansl's, tuned for dance music) matched Traktor's
    // keys best on the test library: 33% exact, 51% within one Camelot step.
    static let majorProfile: [Double] = [6.6, 2.0, 3.5, 2.3, 4.6, 4.0, 2.5, 5.2, 2.4, 3.7, 2.3, 3.4]
    static let minorProfile: [Double] = [6.5, 2.7, 3.5, 5.4, 2.6, 3.5, 2.5, 5.2, 4.0, 2.7, 4.3, 3.2]

    static func chroma(_ samples: [Float]) -> [Double] {
        let n = 8192, hop = 4096
        let fft = RealFFT(size: n)
        let binHz = sampleRate / Double(n)
        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)
        // Map each FFT bin between 55 Hz and 1.76 kHz to its pitch class.
        var binClass = [Int](repeating: -1, count: n / 2)
        for i in 1..<(n / 2) {
            let f = Double(i) * binHz
            guard f >= 55, f <= 1760 else { continue }
            let midi = 69 + 12 * log2(f / 440)
            // Only bins near a semitone centre, to keep tuning noise out.
            if abs(midi - midi.rounded()) < 0.35 {
                binClass[i] = ((Int(midi.rounded()) % 12) + 12) % 12
            }
        }
        var total = [Double](repeating: 0, count: 12)
        var frame = [Float](repeating: 0, count: n)
        var start = 0
        samples.withUnsafeBufferPointer { s in
            while start + n <= s.count {
                vDSP.multiply(UnsafeBufferPointer(rebasing: s[start..<(start + n)]), window, result: &frame)
                let magnitude = fft.magnitudes(frame)
                // Whitening: count only what stands above the local spectrum
                // (±40 bins), so drums and noise don't colour the key.
                var cumulative = [Double](repeating: 0, count: magnitude.count + 1)
                for i in 0..<magnitude.count { cumulative[i + 1] = cumulative[i] + Double(magnitude[i]) }
                var frameChroma = [Double](repeating: 0, count: 12)
                for i in 0..<magnitude.count where binClass[i] >= 0 {
                    let lo = max(0, i - 40), hi = min(magnitude.count, i + 40)
                    let local = (cumulative[hi] - cumulative[lo]) / Double(hi - lo)
                    frameChroma[binClass[i]] += max(0, Double(magnitude[i]) - local)
                }
                // Normalise each frame so loud passages don't dominate.
                let peak = frameChroma.max() ?? 0
                if peak > 0 { for c in 0..<12 { total[c] += frameChroma[c] / peak } }
                start += hop
            }
        }
        return total
    }

    static func estimateKey(_ samples: [Float]) -> (root: Int, minor: Bool, confidence: Double) {
        let c = chroma(samples)
        var scores: [(root: Int, minor: Bool, r: Double)] = []
        for minor in [false, true] {
            let profile = minor ? minorProfile : majorProfile
            for root in 0..<12 {
                let rotated = (0..<12).map { profile[($0 - root + 12) % 12] }
                scores.append((root, minor, pearson(c, rotated)))
            }
        }
        scores.sort { $0.r > $1.r }
        return (scores[0].root, scores[0].minor, scores[0].r - scores[1].r)
    }

    static func pearson(_ a: [Double], _ b: [Double]) -> Double {
        let n = Double(a.count)
        let ma = a.reduce(0, +) / n, mb = b.reduce(0, +) / n
        var num = 0.0, da = 0.0, db = 0.0
        for i in 0..<a.count {
            num += (a[i] - ma) * (b[i] - mb)
            da += (a[i] - ma) * (a[i] - ma)
            db += (b[i] - mb) * (b[i] - mb)
        }
        return da > 0 && db > 0 ? num / (da * db).squareRoot() : 0
    }

    // MARK: Energy

    static func estimateEnergy(_ samples: [Float], onset: OnsetFeatures) -> Int {
        // Loudness of the louder half of the track (ignores breakdowns).
        let sortedRMS = onset.rms.sorted()
        let loud = sortedRMS[Int(Double(sortedRMS.count) * 0.75)]
        let loudness = 20 * log10(max(Double(loud), 1e-6))            // dBFS, ~ -20 … -6
        // Onset density: how busy the percussion is.
        let meanOnset = Double(onset.full.reduce(0, +)) / Double(max(onset.full.count, 1))
        // Brightness: median spectral centroid.
        let sortedCentroid = onset.centroid.sorted()
        let brightness = Double(sortedCentroid[sortedCentroid.count / 2])  // Hz

        // Scales set from a techno/electro library: loudness −16…−4 dBFS,
        // onset density 15…50, median centroid 600…2800 Hz.
        let l = clamp((loudness + 16) / 12)
        let d = clamp((meanOnset - 15) / 35)
        let b = clamp((brightness - 600) / 2200)
        let score = 0.45 * l + 0.35 * d + 0.2 * b
        return min(10, max(1, 1 + Int((score * 9).rounded())))
    }

    private static func clamp(_ x: Double) -> Double { min(1, max(0, x)) }

    // MARK: Intro / outro

    static func classifySection(_ samples: [Float], onset: OnsetFeatures, from: Double, to: Double, bpm: Double) -> SectionType {
        let a = Int(from * onset.frameRate), b = min(onset.low.count, Int(to * onset.frameRate))
        guard b - a > 64 else { return .ambient }
        // Kick: low-band attacks compared with the track as a whole (which,
        // in dance music, has the kick most of the time). ~1 = kick present.
        let sectionLow = onset.low[a..<b].reduce(0, +) / Float(b - a)
        let trackLow = onset.low.reduce(0, +) / Float(max(onset.low.count, 1))
        let kick = Double(sectionLow / max(trackLow, 1e-9))
        // Level compared with the track's loud passages.
        let sectionRMS = onset.rms[a..<b].reduce(0, +) / Float(b - a)
        let sortedRMS = onset.rms.sorted()
        let loud = sortedRMS[Int(Double(sortedRMS.count) * 0.75)]
        let level = Double(sectionRMS / max(loud, 1e-6))
        if kick >= 0.6 && level > 0.05 { return .beat }
        return level > 0.45 ? .breakdown : .ambient
    }
}

/// Real-input FFT returning magnitudes of the first n/2 bins.
nonisolated final class RealFFT {
    private let setup: vDSP.FFT<DSPSplitComplex>
    private let n: Int
    private var real: [Float]
    private var imag: [Float]

    init(size: Int) {
        n = size
        setup = vDSP.FFT(log2n: vDSP_Length(log2(Double(size))), radix: .radix2, ofType: DSPSplitComplex.self)!
        real = [Float](repeating: 0, count: size / 2)
        imag = [Float](repeating: 0, count: size / 2)
    }

    func magnitudes(_ input: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: n / 2)
        real.withUnsafeMutableBufferPointer { r in
            imag.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                input.withUnsafeBufferPointer { p in
                    p.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                setup.forward(input: split, output: &split)
                vDSP.absolute(split, result: &out)
            }
        }
        return out
    }
}

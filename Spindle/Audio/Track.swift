//
//  Track.swift
//  Spindle
//
//  Decodes an audio file into memory at the device's sample rate and builds a
//  peak overview for the waveform.
//

@preconcurrency import AVFoundation
import Foundation

/// Raw sample memory the audio thread plays from. Plain C-style memory so the
/// render callback touches no Swift reference counting.
nonisolated struct TrackSamples {
    let left: UnsafeMutablePointer<Float>
    let right: UnsafeMutablePointer<Float>
    let frames: Int
    let sampleRate: Double

    func free() {
        left.deallocate()
        right.deallocate()
    }
}

nonisolated struct LoadedTrack: Sendable {
    let url: URL
    let title: String
    let artist: String
    let duration: Double
    /// Peak level per waveform column, 0…1.
    let peaks: [Float]
    /// Loudness (RMS) per column, on the same scale as `peaks`.
    let rms: [Float]
    /// Peak per column of the bass (< 200 Hz), mids and highs (> 2.5 kHz),
    /// each 0…1 against its own loudest moments: what the coloured
    /// waveforms are drawn from.
    let low: [Float]
    let mid: [Float]
    let high: [Float]
    static let peaksPerSecond: Double = 200
    /// Pointer to a heap-allocated TrackSamples, handed to the deck.
    nonisolated(unsafe) let samples: UnsafeMutablePointer<TrackSamples>
}

enum TrackLoadError: LocalizedError {
    case unreadable(String)
    var errorDescription: String? {
        switch self { case .unreadable(let why): "Couldn't read the file: \(why)" }
    }
}

nonisolated enum TrackLoader {
    /// Runs in the background (@concurrent), never on the caller's thread:
    /// decoding a whole file takes up to a second.
    @concurrent
    static func load(url: URL, sampleRate: Double) async throws -> LoadedTrack {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }

        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let sourceFormat = file.processingFormat
        guard let source = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw TrackLoadError.unreadable("out of memory")
        }
        try file.read(into: source)

        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false),
              let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw TrackLoadError.unreadable("unsupported format")
        }
        if sourceFormat.channelCount == 1 {
            converter.channelMap = [0, 0]
        }
        let capacity = AVAudioFrameCount(Double(source.frameLength) * sampleRate / sourceFormat.sampleRate) + 4096
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            throw TrackLoadError.unreadable("out of memory")
        }
        var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return source
        }
        if let error { throw error }

        let frames = Int(output.frameLength)
        guard frames > 0, let channels = output.floatChannelData else { throw TrackLoadError.unreadable("empty file") }
        let left = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        left.update(from: channels[0], count: frames)
        right.update(from: channels[1], count: frames)

        let samples = UnsafeMutablePointer<TrackSamples>.allocate(capacity: 1)
        samples.initialize(to: TrackSamples(left: left, right: right, frames: frames, sampleRate: sampleRate))

        let (title, artist) = await metadata(url: url)
        let overview = levels(left: left, right: right, frames: frames, sampleRate: sampleRate)
        let bands = Self.bands(left: left, right: right, frames: frames, sampleRate: sampleRate)
        return LoadedTrack(url: url, title: title, artist: artist,
                           duration: Double(frames) / sampleRate,
                           peaks: overview.peaks, rms: overview.rms,
                           low: bands.low, mid: bands.mid, high: bands.high,
                           samples: samples)
    }

    /// Peak and loudness per column, both scaled by the loudest peak.
    private static func levels(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int, sampleRate: Double) -> (peaks: [Float], rms: [Float]) {
        let block = max(1, Int(sampleRate / LoadedTrack.peaksPerSecond))
        let count = frames / block + 1
        var peaks = [Float](repeating: 0, count: count)
        var rms = [Float](repeating: 0, count: count)
        var maxPeak: Float = 0.0001
        for column in 0..<count {
            let start = column * block
            let end = min(start + block, frames)
            var peak: Float = 0
            var sum: Float = 0
            var i = start
            while i < end {
                let m = max(abs(left[i]), abs(right[i]))
                peak = max(peak, m)
                sum += 0.5 * (left[i] * left[i] + right[i] * right[i])
                i += 1
            }
            peaks[column] = peak
            rms[column] = end > start ? (sum / Float(end - start)).squareRoot() : 0
            maxPeak = max(maxPeak, peak)
        }
        // RMS of a full-scale signal sits ~3 dB under its peak; lift it a
        // little so the solid layer fills most of the outline.
        return (peaks.map { $0 / maxPeak }, rms.map { min(1, $0 * 1.5 / maxPeak) })
    }

    /// A second-order (biquad) filter, RBJ cookbook coefficients.
    private struct Biquad {
        var b0: Float, b1: Float, b2: Float, a1: Float, a2: Float
        var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

        init(lowPass f: Double, rate: Double) { self.init(f, rate, high: false) }
        init(highPass f: Double, rate: Double) { self.init(f, rate, high: true) }
        private init(_ f: Double, _ rate: Double, high: Bool) {
            let w = 2 * Double.pi * f / rate, q = 0.7071
            let alpha = sin(w) / (2 * q), c = cos(w)
            let a0 = 1 + alpha
            let bb0 = high ? (1 + c) / 2 : (1 - c) / 2
            let bb1 = high ? -(1 + c) : 1 - c
            b0 = Float(bb0 / a0); b1 = Float(bb1 / a0); b2 = Float(bb0 / a0)
            a1 = Float(-2 * c / a0); a2 = Float((1 - alpha) / a0)
        }
        @inline(__always) mutating func run(_ x: Float) -> Float {
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x; y2 = y1; y1 = y
            return y
        }
    }

    /// Bass, mids and highs per waveform column.
    private static func bands(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int, sampleRate: Double) -> (low: [Float], mid: [Float], high: [Float]) {
        let block = max(1, Int(sampleRate / LoadedTrack.peaksPerSecond))
        let count = frames / block + 1
        var low = [Float](repeating: 0, count: count), mid = low, high = low
        var lp = Biquad(lowPass: 200, rate: sampleRate)
        var mHP = Biquad(highPass: 200, rate: sampleRate), mLP = Biquad(lowPass: 2500, rate: sampleRate)
        var hp = Biquad(highPass: 2500, rate: sampleRate)
        var i = 0
        for column in 0..<count {
            let end = min(i + block, frames)
            var l: Float = 0, m: Float = 0, h: Float = 0
            while i < end {
                let x = 0.5 * (left[i] + right[i])
                l = max(l, abs(lp.run(x)))
                m = max(m, abs(mLP.run(mHP.run(x))))
                h = max(h, abs(hp.run(x)))
                i += 1
            }
            low[column] = l; mid[column] = m; high[column] = h
        }
        // Each band against its own loud moments (99.5th percentile), so
        // quiet highs still show.
        func norm(_ v: [Float]) -> [Float] {
            let sorted = v.sorted()
            let top = max(sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.995))], 1e-6)
            return v.map { min(1, $0 / top) }
        }
        return (norm(low), norm(mid), norm(high))
    }

    private static func metadata(url: URL) async -> (String, String) {
        let asset = AVURLAsset(url: url)
        var title = url.deletingPathExtension().lastPathComponent
        var artist = ""
        if let items = try? await asset.load(.commonMetadata) {
            for item in items {
                if item.commonKey == .commonKeyTitle, let value = try? await item.load(.stringValue), !value.isEmpty { title = value }
                if item.commonKey == .commonKeyArtist, let value = try? await item.load(.stringValue) { artist = value }
            }
        }
        return (title, artist)
    }
}

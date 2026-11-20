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
    /// How full each moment's section is (loudness averaged over 4 s),
    /// 0 = the track's emptiest part, 1 = its fullest: breaks and intros
    /// low, drops high. Shades the waveforms so the build reads at a glance.
    let sections: [Float]
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
        return LoadedTrack(url: url, title: title, artist: artist,
                           duration: Double(frames) / sampleRate,
                           peaks: overview.peaks, rms: overview.rms,
                           sections: Self.sections(overview.rms),
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

    private static func sections(_ rms: [Float]) -> [Float] {
        let n = rms.count
        guard n > 0 else { return [] }
        let half = Int(2 * LoadedTrack.peaksPerSecond)            // ±2 s
        var prefix = [Double](repeating: 0, count: n + 1)
        for i in 0..<n { prefix[i + 1] = prefix[i] + Double(rms[i]) }
        var avg = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let a = max(0, i - half), b = min(n, i + half + 1)
            avg[i] = Float((prefix[b] - prefix[a]) / Double(b - a))
        }
        // Spread between the quiet and full parts (5th…95th percentile).
        let sorted = avg.sorted()
        let lo = sorted[Int(Double(n - 1) * 0.05)], hi = max(sorted[Int(Double(n - 1) * 0.95)], lo + 1e-4)
        return avg.map { min(1, max(0, ($0 - lo) / (hi - lo))) }
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

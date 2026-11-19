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

    /// Decodes only `duration` seconds from `start` (a clip's bars), at the
    /// device's sample rate. The caller frees the result.
    static func loadRegion(url: URL, sampleRate: Double, start: Double, duration: Double) throws -> UnsafeMutablePointer<TrackSamples> {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        let first = AVAudioFramePosition(max(0, start) * format.sampleRate)
        let count = AVAudioFrameCount(min(Double(file.length - first), duration * format.sampleRate))
        guard first < file.length, count > 0,
              let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else {
            throw TrackLoadError.unreadable("region outside the track")
        }
        file.framePosition = first
        try file.read(into: source, frameCount: count)
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false),
              let converter = AVAudioConverter(from: format, to: target),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(count) * sampleRate / format.sampleRate) + 4096) else {
            throw TrackLoadError.unreadable("unsupported format")
        }
        if format.channelCount == 1 { converter.channelMap = [0, 0] }
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
        guard frames > 0, let channels = output.floatChannelData else { throw TrackLoadError.unreadable("empty region") }
        let left = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        left.update(from: channels[0], count: frames)
        right.update(from: channels[1], count: frames)
        let samples = UnsafeMutablePointer<TrackSamples>.allocate(capacity: 1)
        samples.initialize(to: TrackSamples(left: left, right: right, frames: frames, sampleRate: sampleRate))
        return samples
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

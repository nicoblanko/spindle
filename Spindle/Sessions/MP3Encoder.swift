//
//  MP3Encoder.swift
//  Spindle
//
//  Encodes a recording to MP3 with LAME (Vendor/lame, LGPL): 320 kbps
//  constant bit rate, high quality, with a LAME/Xing header so players
//  show the right length.
//

@preconcurrency import AVFoundation
import Foundation
import LAME

nonisolated enum MP3Encoder {
    enum Failure: LocalizedError {
        case setup
        case encode(Int32)
        var errorDescription: String? {
            switch self {
            case .setup: "The MP3 encoder couldn't be set up."
            case .encode(let code): "MP3 encoding failed (\(code))."
            }
        }
    }

    static func encode(from source: URL, to target: URL, kbps: Int32 = 320) throws {
        let input = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = input.processingFormat
        guard let lame = lame_init() else { throw Failure.setup }
        defer { lame_close(lame) }
        lame_set_in_samplerate(lame, Int32(format.sampleRate))
        lame_set_num_channels(lame, 2)
        lame_set_mode(lame, JOINT_STEREO)
        lame_set_VBR(lame, vbr_off)
        lame_set_brate(lame, kbps)
        lame_set_quality(lame, 2)
        lame_set_bWriteVbrTag(lame, 1)
        guard lame_init_params(lame) >= 0 else { throw Failure.setup }

        FileManager.default.createFile(atPath: target.path, contents: nil)
        let out = try FileHandle(forWritingTo: target)
        defer { try? out.close() }

        let chunk: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk),
              let channels = buffer.floatChannelData else { throw Failure.setup }
        let mp3Size = Int(chunk) * 5 / 4 + 7200
        var mp3 = [UInt8](repeating: 0, count: mp3Size)
        let mono = format.channelCount == 1

        while input.framePosition < input.length {
            try input.read(into: buffer, frameCount: chunk)
            let frames = Int32(buffer.frameLength)
            if frames == 0 { break }
            let written = mp3.withUnsafeMutableBufferPointer { p in
                lame_encode_buffer_ieee_float(lame, channels[0], mono ? channels[0] : channels[1],
                                              frames, p.baseAddress, Int32(mp3Size))
            }
            guard written >= 0 else { throw Failure.encode(written) }
            out.write(Data(mp3[0..<Int(written)]))
        }
        let tail = mp3.withUnsafeMutableBufferPointer { lame_encode_flush(lame, $0.baseAddress, Int32(mp3Size)) }
        if tail > 0 { out.write(Data(mp3[0..<Int(tail)])) }

        // The LAME/Xing header goes over the first (placeholder) frame.
        let tagSize = mp3.withUnsafeMutableBufferPointer { lame_get_lametag_frame(lame, $0.baseAddress, mp3Size) }
        if tagSize > 0 && tagSize <= mp3Size {
            try out.seek(toOffset: 0)
            out.write(Data(mp3[0..<tagSize]))
        }
    }
}

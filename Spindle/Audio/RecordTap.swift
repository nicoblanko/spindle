//
//  RecordTap.swift
//  Spindle
//
//  Hands audio from the render callback to the session recorder without
//  locks: a single-producer, single-consumer ring of interleaved stereo
//  samples. The audio thread only copies; the recorder drains and writes.
//

import Foundation
import Synchronization

nonisolated final class RecordTap: @unchecked Sendable {
    /// Floats (interleaved L/R): about 20 s at 48 kHz.
    static let capacity = 1 << 21
    private static let mask = capacity - 1
    private let buffer: UnsafeMutablePointer<Float>
    private let written = Atomic<Int>(0)
    private let read = Atomic<Int>(0)
    let armed = Atomic<Bool>(false)
    /// Frames lost because the recorder fell behind (should stay 0).
    let dropped = Atomic<Int>(0)
    /// Peak of the last buffer, for the level meter.
    let peakBits = Atomic<UInt32>(0)
    var peak: Float { Float(bitPattern: peakBits.load(ordering: .relaxed)) }

    init() {
        buffer = .allocate(capacity: Self.capacity)
        buffer.initialize(repeating: 0, count: Self.capacity)
    }

    deinit { buffer.deallocate() }

    /// Audio thread.
    func push(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int) {
        var peak: Float = 0
        for i in 0..<frames { peak = max(peak, abs(left[i]), abs(right[i])) }
        peakBits.store(peak.bitPattern, ordering: .relaxed)
        guard armed.load(ordering: .relaxed) else { return }
        let w = written.load(ordering: .relaxed)
        let r = read.load(ordering: .acquiring)
        guard Self.capacity - (w - r) >= frames * 2 else {
            dropped.add(frames, ordering: .relaxed)
            return
        }
        for i in 0..<frames {
            buffer[(w + 2 * i) & Self.mask] = left[i]
            buffer[(w + 2 * i + 1) & Self.mask] = right[i]
        }
        written.store(w + frames * 2, ordering: .releasing)
    }

    /// Frames handed over since the tap was armed (capture time line).
    var framesWritten: Int { written.load(ordering: .relaxed) / 2 }

    /// Recorder thread: moves everything waiting into `left`/`right`.
    func drain(left: inout [Float], right: inout [Float]) {
        let w = written.load(ordering: .acquiring)
        let r = read.load(ordering: .relaxed)
        let frames = (w - r) / 2
        left.removeAll(keepingCapacity: true)
        right.removeAll(keepingCapacity: true)
        guard frames > 0 else { return }
        left.reserveCapacity(frames)
        right.reserveCapacity(frames)
        for i in 0..<frames {
            left.append(buffer[(r + 2 * i) & Self.mask])
            right.append(buffer[(r + 2 * i + 1) & Self.mask])
        }
        read.store(r + frames * 2, ordering: .releasing)
    }

    /// Drops anything left over from before (call while not armed).
    func reset() {
        read.store(written.load(ordering: .acquiring), ordering: .releasing)
        dropped.store(0, ordering: .relaxed)
    }
}

//
//  AudioEngineCore.swift
//  Spindle
//
//  One AUHAL unit running input and output on the same device, so timecode in
//  and music out share a clock and a single callback. Each callback reads the
//  timecode, decodes it, and writes the decks' audio: latency is one buffer
//  each way.
//
//  Each deck reads one stereo input pair and plays to one output pair, chosen
//  in the UI (see EngineRouting). On a device with only 2 outputs both decks
//  are mixed onto outputs 1–2.
//

import AudioToolbox
import CoreAudio
import Foundation

/// Channel pairs per deck, as the first (left) channel of a stereo pair, 0-based.
nonisolated struct EngineRouting: Sendable, Equatable {
    // Plain integers, not arrays: the audio thread reads these while the UI may write them.
    var inputA = 0, inputB = 2
    var outputA = 0, outputB = 2

    func input(_ deck: Int) -> Int { deck == 0 ? inputA : inputB }
    func output(_ deck: Int) -> Int { deck == 0 ? outputA : outputB }

    /// Measured on the Xone:24C (6 in / 6 out): turntable 1 arrives on inputs
    /// 3–4, so turntable 2 is expected on 5–6. Outputs 1–2 and 3–4 are a guess.
    static func defaults(for device: AudioDevice) -> EngineRouting {
        if device.inputChannels >= 6 {
            return EngineRouting(inputA: 2, inputB: 4, outputA: 0, outputB: 2)
        }
        return EngineRouting()
    }
}

enum EngineError: LocalizedError {
    case status(String, OSStatus)
    var errorDescription: String? {
        switch self { case .status(let step, let code): "\(step) failed (OSStatus \(code))" }
    }
}

nonisolated final class AudioEngineCore: @unchecked Sendable {
    static let maxFrames = 4096

    let device: AudioDevice
    let sampleRate: Double
    let simulate: Bool
    let definition: TimecodeDefinition
    let decks: [DeckEngine]
    let simulators: [TimecodeSimulator]
    /// Prep's pre-listen player: its own transport, never recorded. Plays on
    /// outputs 5–6 (the Xone's AUX/headphone pair) when the device has them
    /// and the decks are on turntables; otherwise mixed onto outputs 1–2.
    let preview: DeckEngine
    var previewOutput = 0
    private(set) var bufferFrames: UInt32 = 0

    private var unit: AudioUnit?
    private let inputChannels: Int
    private let outputChannels: Int
    private let inputList: UnsafeMutableAudioBufferListPointer
    private let inputData: [UnsafeMutablePointer<Float>]
    private let silence: UnsafeMutablePointer<Float>
    private let simBuffers: [UnsafeMutablePointer<Float>]
    /// Read by the audio thread each buffer; set from the UI.
    var routing: EngineRouting

    /// What the session recorder hears.
    let recordTap = RecordTap()
    /// First input channel of the pair to record (the mixer's record/master
    /// send), or −1 for Spindle's own output of both decks.
    var recordInput = -1
    private let mixL: UnsafeMutablePointer<Float>
    private let mixR: UnsafeMutablePointer<Float>
    /// Whether this device can supply a recording input pair.
    var hasInputs: Bool { inputChannels >= 2 }

    /// Laptop mode: no timecode, the decks play from their own transport.
    let laptop: Bool

    init(device: AudioDevice, definition: TimecodeDefinition, simulate: Bool, laptop: Bool = false, routing: EngineRouting) {
        self.laptop = laptop
        self.device = device
        self.sampleRate = device.sampleRate > 0 ? device.sampleRate : 48000
        self.simulate = !laptop && (simulate || device.inputChannels < 2)
        self.definition = definition
        self.routing = routing
        inputChannels = self.simulate || laptop ? 0 : device.inputChannels
        outputChannels = device.outputChannels

        decks = [DeckEngine(definition: definition, sampleRate: sampleRate),
                 DeckEngine(definition: definition, sampleRate: sampleRate)]
        simulators = [TimecodeSimulator(definition: definition), TimecodeSimulator(definition: definition)]
        for deck in decks { deck.internalMode = laptop }
        preview = DeckEngine(definition: definition, sampleRate: sampleRate)
        preview.internalMode = true
        previewOutput = !laptop && device.outputChannels >= 6 ? 4 : 0

        inputList = AudioBufferList.allocate(maximumBuffers: max(inputChannels, 1))
        var data: [UnsafeMutablePointer<Float>] = []
        for channel in 0..<max(inputChannels, 1) {
            let buffer = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxFrames)
            buffer.initialize(repeating: 0, count: Self.maxFrames)
            data.append(buffer)
            inputList[channel] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(Self.maxFrames * 4), mData: buffer)
        }
        inputData = data
        silence = .allocate(capacity: Self.maxFrames)
        silence.initialize(repeating: 0, count: Self.maxFrames)
        mixL = .allocate(capacity: Self.maxFrames)
        mixL.initialize(repeating: 0, count: Self.maxFrames)
        mixR = .allocate(capacity: Self.maxFrames)
        mixR.initialize(repeating: 0, count: Self.maxFrames)
        simBuffers = (0..<4).map { _ in
            let b = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxFrames)
            b.initialize(repeating: 0, count: Self.maxFrames)
            return b
        }
    }

    deinit {
        stop()
        inputData.forEach { $0.deallocate() }
        inputList.unsafeMutablePointer.deallocate()
        silence.deallocate()
        simBuffers.forEach { $0.deallocate() }
        mixL.deallocate()
        mixR.deallocate()
    }

    func start() throws {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw EngineError.status("Finding the HAL unit", -1)
        }
        var newUnit: AudioUnit?
        try check("Creating the HAL unit", AudioComponentInstanceNew(component, &newUnit))
        guard let unit = newUnit else { throw EngineError.status("Creating the HAL unit", -1) }
        self.unit = unit

        var enableInput: UInt32 = inputChannels > 0 ? 1 : 0
        try check("Enabling input", AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enableInput, 4))
        var enableOutput: UInt32 = 1
        try check("Enabling output", AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enableOutput, 4))

        var deviceID = device.id
        try check("Selecting \(device.name)", AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)))

        bufferFrames = AudioDevices.setBufferSize(device.id, frames: 128)
        var maxFrames = UInt32(Self.maxFrames)
        AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, 4)

        var outFormat = Self.format(channels: outputChannels, sampleRate: sampleRate)
        try check("Setting the output format", AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &outFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)))
        if inputChannels > 0 {
            var inFormat = Self.format(channels: inputChannels, sampleRate: sampleRate)
            try check("Setting the input format", AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &inFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)))
        }

        var callback = AURenderCallbackStruct(
            inputProc: spindleRenderCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try check("Installing the render callback", AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)))

        try check("Initialising audio", AudioUnitInitialize(unit))
        try check("Starting audio", AudioOutputUnitStart(unit))
    }

    func stop() {
        guard let unit else { return }
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        self.unit = nil
    }

    private func check(_ step: String, _ status: OSStatus) throws {
        if status != noErr { throw EngineError.status(step, status) }
    }

    private static func format(channels: Int, sampleRate: Double) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
    }

    // MARK: Audio thread

    fileprivate func render(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                            timestamp: UnsafePointer<AudioTimeStamp>,
                            frameCount: UInt32,
                            output: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
        let frames = min(Int(frameCount), Self.maxFrames)

        if inputChannels > 0, let unit {
            for channel in 0..<inputChannels {
                inputList[channel].mDataByteSize = UInt32(frames * 4)
                inputList[channel].mData = UnsafeMutableRawPointer(inputData[channel])
            }
            if AudioUnitRender(unit, flags, timestamp, 1, UInt32(frames), inputList.unsafeMutablePointer) != noErr {
                for channel in 0..<inputChannels { inputData[channel].update(repeating: 0, count: frames) }
            }
        }

        for (index, deck) in decks.enumerated() where !laptop {
            let left: UnsafeMutablePointer<Float>
            let right: UnsafeMutablePointer<Float>
            if simulate {
                left = simBuffers[index * 2]
                right = simBuffers[index * 2 + 1]
                simulators[index].generate(left: left, right: right, frames: frames, sampleRate: sampleRate)
            } else {
                let first = routing.input(index)
                left = first < inputChannels ? inputData[first] : silence
                right = first + 1 < inputChannels ? inputData[first + 1] : silence
            }
            deck.decode(left: left, right: right, frames: frames)
        }

        guard let output else { return noErr }
        let buffers = UnsafeMutableAudioBufferListPointer(output)
        for buffer in buffers {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        let separate = buffers.count >= 4
        for (index, deck) in decks.enumerated() {
            let l = separate ? routing.output(index) : 0
            guard l + 1 < buffers.count,
                  let left = buffers[l].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[l + 1].mData?.assumingMemoryBound(to: Float.self) else { continue }
            deck.render(left: left, right: right, frames: frames, mix: true)
        }

        // Recording: the mixer's record send if chosen, else both decks' output.
        let source = recordInput
        if source >= 0 && source + 1 < inputChannels {
            recordTap.push(left: inputData[source], right: inputData[source + 1], frames: frames)
        } else {
            mixL.update(repeating: 0, count: frames)
            mixR.update(repeating: 0, count: frames)
            var pairs = [0]
            if separate { pairs = [routing.output(0), routing.output(1)] }
            if pairs.count == 2 && pairs[0] == pairs[1] { pairs.removeLast() }
            for l in pairs where l + 1 < buffers.count {
                guard let a = buffers[l].mData?.assumingMemoryBound(to: Float.self),
                      let b = buffers[l + 1].mData?.assumingMemoryBound(to: Float.self) else { continue }
                for i in 0..<frames {
                    mixL[i] += a[i]
                    mixR[i] += b[i]
                }
            }
            recordTap.push(left: mixL, right: mixR, frames: frames)
        }

        // Pre-listen, after the recording tap so it's never in a recording.
        let p = previewOutput + 1 < buffers.count ? previewOutput : 0
        if p + 1 < buffers.count,
           let left = buffers[p].mData?.assumingMemoryBound(to: Float.self),
           let right = buffers[p + 1].mData?.assumingMemoryBound(to: Float.self) {
            preview.render(left: left, right: right, frames: frames, mix: true)
        }
        return noErr
    }
}

private nonisolated func spindleRenderCallback(
    refCon: UnsafeMutableRawPointer,
    flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    timestamp: UnsafePointer<AudioTimeStamp>,
    bus: UInt32,
    frames: UInt32,
    data: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let engine = Unmanaged<AudioEngineCore>.fromOpaque(refCon).takeUnretainedValue()
    return engine.render(flags: flags, timestamp: timestamp, frameCount: frames, output: data)
}

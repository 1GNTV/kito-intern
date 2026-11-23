import AVFoundation

/// One instance per movie. Filter memory and the gain envelope span capture buffers.
final class CameraMicrophone {
    private let lowCut: Float
    private let highCut: Float
    private let quietGain: Float
    private let presence: Float
    private let recoveryTime: Float
    private let drive: Float
    private var midLow: Float = 0
    private var midHigh: Float = 0
    private var preampGain: Float = 1
    private var activity: Float = 0
    private var hissMemory: Float = 0
    private var randomState: UInt32 = 0x745dc97
    private var converter: AVAudioConverter?
    private var rumble: Float = 0
    private var low1: Float = 0
    private var low2: Float = 0
    private var envelope: Float = 0
    private var nextTime = CMTime.invalid

    init(profile: CameraProfile) {
        let dv = profile.family == .camcorder
        lowCut = dv ? 135 : 205
        highCut = dv ? 6100 : (profile.id == "compact02" ? 3000 : 4050)
        quietGain = dv ? 1.85 : 2.45
        presence = dv ? 0.36 : 0.65
        recoveryTime = dv ? 0.40 : 0.64
        drive = dv ? 1.18 : 1.38
    }

    func process(_ sample: CMSampleBuffer) -> CMSampleBuffer? {
        let count = CMSampleBufferGetNumSamples(sample)
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        guard count > 0, let description = CMSampleBufferGetFormatDescription(sample),
              CMFormatDescriptionGetMediaSubType(description) == kAudioFormatLinearPCM else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let rate = format.sampleRate
        guard rate.isFinite, rate > 0, format.channelCount > 0 else { return nil }
        let changed = converter?.inputFormat != format
        if changed {
            guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                           channels: 1, interleaved: true) else { return nil }
            converter = AVAudioConverter(from: format, to: mono)
            converter?.downmix = true
        }
        if changed || (nextTime.isNumeric && abs((pts - nextTime).seconds) > 0.02) {
            rumble = 0
            low1 = 0
            low2 = 0
            midLow = 0
            midHigh = 0
            envelope = 0
            preampGain = 1
            activity = 0
            hissMemory = 0
            randomState = 0x745dc97
            converter?.reset()
        }
        guard let converter,
              let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: AVAudioFrameCount(count)) else { return nil }
        input.frameLength = AVAudioFrameCount(count)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(count),
                                                           into: input.mutableAudioBufferList) == noErr else { return nil }
        do {
            try converter.convert(to: output, from: input)
        } catch { return nil }
        guard output.frameLength == count, let samples = output.floatChannelData?[0] else { return nil }
        let hz = Float(rate)
        let bass = 1 - exp(-2 * .pi * lowCut / hz)
        let treble = 1 - exp(-2 * .pi * highCut / hz)
        let lowerMid = 1 - exp(-2 * .pi * 800 / hz)
        let upperMid = 1 - exp(-2 * .pi * 2900 / hz)
        let attack = 1 - exp(-1 / (0.005 * hz))
        let release = 1 - exp(-1 / (0.075 * hz))
        let gainDown = 1 - exp(-1 / (0.012 * hz))
        let gainUp = 1 - exp(-1 / (recoveryTime * hz))
        let roomDecay = exp(-1 / (0.10 * hz))
        for i in 0..<count {
            let x = samples[i]
            rumble += bass * (x - rumble)
            low1 += treble * (x - rumble - low1)
            low2 += treble * (low1 - low2)
            midLow += lowerMid * (low2 - midLow)
            midHigh += upperMid * (low2 - midHigh)
            let mic = low2 + presence * (midHigh - midLow)
            let peak = abs(mic)
            envelope += (peak > envelope ? attack : release) * (peak - envelope)

            // The small preamp turns down on a nearby sound, then slowly brings
            // back the room between phrases. The maximum lift is bounded.
            let targetGain = max(0.45, quietGain / (1 + 5.5 * envelope))
            preampGain += (targetGain < preampGain ? gainDown : gainUp) * (targetGain - preampGain)
            let driven = drive * mic * preampGain
            let limited = driven / (1 + 0.70 * abs(driven))

            // A quiet, band-limited electronics floor follows an active mic.
            // Disconnected/muted input starts silent and a trailing floor decays.
            activity = max(min(1, abs(x) * 180), activity * roomDecay)
            randomState = randomState &* 1664525 &+ 1013904223
            let noise = Float(randomState >> 8) / 8388608 - 1
            hissMemory += treble * (noise - hissMemory)
            samples[i] = max(-1, min(1, limited + 0.00125 * preampGain * activity * hissMemory))
        }
        nextTime = pts + CMTime(value: CMTimeValue(count), timescale: CMTimeScale(rate.rounded()))
        return Self.timedBuffer(output, at: pts)
    }

    // All callers supply packed LPCM. Copy into writer-owned storage so that
    // capture can recycle its buffers immediately after this callback returns.
    static func timedBuffer(_ pcm: AVAudioPCMBuffer, at pts: CMTime) -> CMSampleBuffer? {
        let buffer = pcm.audioBufferList.pointee.mBuffers
        let length = Int(buffer.mDataByteSize)
        guard pcm.audioBufferList.pointee.mNumberBuffers == 1, let bytes = buffer.mData, length > 0 else { return nil }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
              blockLength: length, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
              offsetToData: 0, dataLength: length, flags: 0, blockBufferOut: &block) == noErr, let block,
              CMBlockBufferReplaceDataBytes(with: bytes, blockBuffer: block, offsetIntoDestination: 0,
                                            dataLength: length) == noErr else { return nil }
        var result: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault,
              dataBuffer: block, formatDescription: pcm.format.formatDescription,
              sampleCount: Int(pcm.frameLength), presentationTimeStamp: pts,
              packetDescriptions: nil, sampleBufferOut: &result) == noErr else { return nil }
        return result
    }
}

import AVFoundation

/// One instance per movie. Filter memory and the gain envelope span capture buffers.
final class CameraMicrophone {
    private let lowCut: Float
    private let highCut: Float
    private let threshold: Float
    private var converter: AVAudioConverter?
    private var rumble: Float = 0
    private var low1: Float = 0
    private var low2: Float = 0
    private var envelope: Float = 0
    private var nextTime = CMTime.invalid

    init(profile: CameraProfile) {
        let dv = profile.family == .camcorder
        lowCut = dv ? 105 : 165
        highCut = dv ? 6500 : (profile.id == "compact02" ? 3600 : 4700)
        threshold = dv ? 0.25 : 0.20
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
            rumble = 0; low1 = 0; low2 = 0; envelope = 0
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
        let attack = 1 - exp(-1 / (0.008 * hz))
        let release = 1 - exp(-1 / (0.22 * hz))
        for i in 0..<count {
            let x = samples[i]
            rumble += bass * (x - rumble)
            low1 += treble * (x - rumble - low1)
            low2 += treble * (low1 - low2)
            let peak = abs(low2)
            envelope += (peak > envelope ? attack : release) * (peak - envelope)
            let gain = 1 / (1 + 1.5 * max(0, envelope - threshold))
            let driven = 1.11 * low2 * gain
            samples[i] = driven / (1 + 0.17 * abs(driven))
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

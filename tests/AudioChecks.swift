import AVFoundation

@main
struct AudioChecks {
    static let rate = 48_000
    static let pts = CMTime(seconds: 3.25, preferredTimescale: 48_000)

    static func tone(_ hz: Double, _ amplitude: Double, frames: Int, start: Int = 0) -> CMSampleBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(rate), channels: 2, interleaved: true)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(frames))!
        pcm.frameLength = UInt32(frames)
        let data = pcm.int16ChannelData![0]
        for i in 0..<frames {
            let value = Int16(32767 * amplitude * sin(2 * Double.pi * hz * Double(i+start) / Double(rate)))
            data[i*2] = value
            data[i*2+1] = value
        }
        return CameraMicrophone.timedBuffer(pcm, at: pts + CMTime(value: Int64(start), timescale: Int32(rate)))!
    }

    static func level(_ hz: Double, _ amplitude: Double, _ profile: CameraProfile) -> Double {
        let model = CameraMicrophone(profile: profile)
        var energy = 0.0
        for n in 0..<8 {
            let buffer = tone(hz, amplitude, frames: 1200, start: 1200*n)
            let out = model.process(buffer)!
            let format = AVAudioFormat(cmAudioFormatDescription: CMSampleBufferGetFormatDescription(out)!)
            precondition(format.channelCount == 1 && format.sampleRate == Double(rate))
            precondition(CMSampleBufferGetPresentationTimeStamp(out) == CMSampleBufferGetPresentationTimeStamp(buffer))
            precondition(CMSampleBufferGetNumSamples(out) == 1200)
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1200)!
            pcm.frameLength = 1200
            precondition(CMSampleBufferCopyPCMDataIntoAudioBufferList(out, at: 0, frameCount: 1200, into: pcm.mutableAudioBufferList) == noErr)
            if n == 7 {
                for i in 0..<1200 { energy += pow(Double(pcm.floatChannelData![0][i]), 2) }
            }
        }
        return sqrt(energy / 1200)
    }

    static func checkGainRecovery() {
        let mic = CameraMicrophone(profile: .ccd3MP)
        var index = 0
        func burst(_ blocks: Int, amplitude: Double) -> Double {
            var last = 0.0
            for _ in 0..<blocks {
                let output = mic.process(tone(1000, amplitude, frames: 1200, start: index))!
                index += 1200
                let desc = CMSampleBufferGetFormatDescription(output)!
                let pcm = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(cmAudioFormatDescription: desc),
                                           frameCapacity: 1200)!
                pcm.frameLength = 1200
                precondition(CMSampleBufferCopyPCMDataIntoAudioBufferList(output, at: 0, frameCount: 1200,
                                                                         into: pcm.mutableAudioBufferList) == noErr)
                var power = 0.0
                for i in 0..<1200 {
                    let x = Double(pcm.floatChannelData![0][i])
                    precondition(x.isFinite && abs(x) <= 1)
                    power += x * x
                }
                last = sqrt(power / 1200)
            }
            return last
        }
        let room = burst(80, amplitude: 0.025)
        _ = burst(12, amplitude: 0.8)
        let afterPeak = burst(2, amplitude: 0.025)
        let recovered = burst(80, amplitude: 0.025)
        precondition(afterPeak < room * 0.75, "a loud sound should turn down the preamp")
        precondition(recovered > room * 0.94, "the room should return between phrases")
        precondition(burst(90, amplitude: 0) < 0.00001, "the floor must decay on mute")
    }

    static func main() async throws {
        checkGainRecovery()
        let voice = level(1000, 0.12, .miniDV03)
        precondition(voice > 0.04)
        precondition(level(30, 0.12, .miniDV03) < voice * 0.40)
        precondition(level(14000, 0.12, .miniDV03) < voice * 0.35)
        precondition(level(7000, 0.12, .compact02) < level(7000, 0.12, .miniDV03) * 0.8)
        precondition(level(1000, 0.9, .miniDV03) / voice < 6.9)
        precondition(level(1000, 0, .miniDV03) == 0)
        let recorder = VideoRecorder(profile: .compact02, microphone: true)!
        var buffer: CVPixelBuffer?
        precondition(CVPixelBufferCreate(nil, 320, 240, kCVPixelFormatType_32BGRA,
                                         nil, &buffer) == kCVReturnSuccess)
        for n in 0..<15 {
            recorder.appendVideo(buffer!, at: pts + CMTime(value: Int64(n), timescale: 15))
            recorder.appendAudio(tone(900, 0.14, frames: 3200, start: n * 3200))
            try await Task.sleep(nanoseconds: 65_000_000)
        }
        let url: URL = try await withCheckedThrowingContinuation { continuation in
            recorder.finish { continuation.resume(with: $0) }
        }
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let video = try await asset.loadTracks(withMediaType: .video)
        precondition(audio.count == 1 && video.count == 1)
        let a = try await audio[0].load(.timeRange)
        let v = try await video[0].load(.timeRange)
        precondition(a.duration.seconds > 0.9 && abs(a.start.seconds - v.start.seconds) < 0.06)
        let descriptions = try await audio[0].load(.formatDescriptions)
        precondition(CMFormatDescriptionGetMediaSubType(descriptions[0]) == kAudioFormatMPEG4AAC)
        print("Microphone frequency, dynamics, silence and PTS checks passed; exported a mono AAC movie with aligned tracks.")
    }
}

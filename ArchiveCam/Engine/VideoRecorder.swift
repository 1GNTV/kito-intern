import AVFoundation
import CoreVideo
import Foundation

/// All append/finish methods must be called from the single capture queue.
final class VideoRecorder {
    let url: URL
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var firstTime: CMTime?
    private(set) var appendedFrames = 0
    private var videoBackpressure = false
    private var audioBackpressure = false

    init?(profile: CameraProfile, microphone: Bool) {
        let directory = FileManager.default.temporaryDirectory
        let filename = "ArchiveCam-\(UUID().uuidString).mp4"
        self.url = directory.appendingPathComponent(filename)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else {
            return nil
        }
        let bitRate = profile.family == .camcorder ? 5_000_000 : (profile.id == "compact02" ? 420_000 : 1_800_000)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: profile.videoWidth,
            AVVideoHeightKey: profile.videoHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoExpectedSourceFrameRateKey: profile.videoFPS,
                AVVideoMaxKeyFrameIntervalKey: profile.family == .compact ? 1 : profile.videoFPS
            ]
        ]
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        video.expectsMediaDataInRealTime = true
        guard writer.canAdd(video) else { return nil }
        writer.add(video)
        self.videoInput = video

        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: profile.videoWidth,
            kCVPixelBufferHeightKey as String: profile.videoHeight,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        self.adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: video, sourcePixelBufferAttributes: attrs
        )

        if microphone {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 96_000
            ]
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audio.expectsMediaDataInRealTime = true
            if writer.canAdd(audio) {
                writer.add(audio)
                self.audioInput = audio
            } else {
                self.audioInput = nil
            }
        } else {
            self.audioInput = nil
        }
        self.writer = writer
    }

    func appendVideo(_ pixelBuffer: CVPixelBuffer, at time: CMTime) {
        if firstTime == nil {
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: time)
            firstTime = time
        }
        guard writer.status == .writing else { return }
        guard videoInput.isReadyForMoreMediaData else {
            videoBackpressure = true
            return
        }
        if adaptor.append(pixelBuffer, withPresentationTime: time) {
            appendedFrames += 1
        } else {
            videoBackpressure = true
        }
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard let audioInput, let firstTime,
              CMSampleBufferDataIsReady(sampleBuffer),
              CMSampleBufferGetPresentationTimeStamp(sampleBuffer) >= firstTime,
              writer.status == .writing else { return }
        guard audioInput.isReadyForMoreMediaData, audioInput.append(sampleBuffer) else {
            audioBackpressure = true
            return
        }
    }

    func noteDroppedVideoFrame() { videoBackpressure = true }

    func finish(_ completion: @escaping (Result<URL, Error>) -> Void) {
        guard !videoBackpressure && !audioBackpressure else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            completion(.failure(NSError(
                domain: "ArchiveCam", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Capture or encoder could not keep up; recording discarded."]
            )))
            return
        }
        guard firstTime != nil else {
            completion(.failure(NSError(
                domain: "ArchiveCam", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No video frames were captured."]
            )))
            return
        }
        guard writer.status == .writing else {
            completion(.failure(writer.error ?? NSError(
                domain: "ArchiveCam", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Video encoder failed."]
            )))
            return
        }
        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        writer.finishWriting { [writer, url] in
            if writer.status == .completed {
                completion(.success(url))
            } else {
                completion(.failure(writer.error ?? NSError(
                    domain: "ArchiveCam", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Cannot finalize video."]
                )))
            }
        }
    }
}

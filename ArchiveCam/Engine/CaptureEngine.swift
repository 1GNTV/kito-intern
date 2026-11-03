import AVFoundation
import Combine
import Photos
import UIKit

/// AVFoundation configuration, frame rendering and AVAssetWriter appends are serialized
/// on captureQueue. The SwiftUI-facing published state is changed on the main queue.
final class CaptureEngine: NSObject, ObservableObject,
    AVCaptureVideoDataOutputSampleBufferDelegate,
    AVCaptureAudioDataOutputSampleBufferDelegate,
    AVCapturePhotoCaptureDelegate {

    @Published private(set) var status = "AWAITING CAMERA"
    @Published private(set) var isReady = false
    @Published private(set) var isRecording = false
    @Published private(set) var hasMicrophone = false
    @Published private(set) var hasFiftyFPS = false
    @Published private(set) var recordingSince: Date?

    let renderer: RenderEngine?
    let preview = PreviewStore()

    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private let captureQueue = DispatchQueue(label: "cam.archive.capture", qos: .userInitiated)
    private let photoQueue = DispatchQueue(label: "cam.archive.stills", qos: .userInitiated)
    private var camera: AVCaptureDevice?
    private var configured = false
    private var activeProfile = CameraProfile.compact04
    private var recorder: VideoRecorder?
    private var microphoneGranted = false
    private var fiftyFPSActive = false
    private var pendingField: CMSampleBuffer?
    private var samplingOrigin: CMTime = .invalid
    private var lastSampleIndex: Int = -1
    private var isFlashEnabled = false
    private var photoProfile: CameraProfile?

    override init() {
        renderer = RenderEngine()
        super.init()
        if renderer == nil {
            updateStatus("METAL UNAVAILABLE")
        }
    }

    func start() {
        guard renderer != nil else { return }
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.updateStatus("CAMERA ACCESS DENIED")
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] micGranted in
                guard let self else { return }
                self.captureQueue.async {
                    self.microphoneGranted = micGranted
                    if !self.configured { self.configure() }
                    if self.configured && !self.session.isRunning {
                        self.session.startRunning()
                        DispatchQueue.main.async {
                            self.isReady = true
                            self.hasMicrophone = micGranted
                            self.status = "CAMERA READY"
                        }
                    }
                }
            }
        }
    }

    func stop() {
        captureQueue.async {
            if self.recorder != nil { self.stopRecordingOnQueue() }
            self.pendingField = nil
            if self.session.isRunning { self.session.stopRunning() }
            DispatchQueue.main.async { self.isReady = false }
        }
    }

    private func configure() {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .hd1280x720

        guard let device = AVCaptureDevice.default(
            .builtInWideAngleCamera, for: .video, position: .back
        ), let videoInput = try? AVCaptureDeviceInput(device: device),
            session.canAddInput(videoInput) else {
            updateStatus("NO BACK CAMERA")
            return
        }
        session.addInput(videoInput)
        camera = device

        if microphoneGranted,
            let mic = AVCaptureDevice.default(for: .audio),
            let input = try? AVCaptureDeviceInput(device: mic),
            session.canAddInput(input) {
            session.addInput(input)
        } else {
            microphoneGranted = false
        }

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
            videoOutput.setSampleBufferDelegate(self, queue: captureQueue)
            if let connection = videoOutput.connection(with: .video),
               connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
        } else {
            updateStatus("VIDEO OUTPUT UNAVAILABLE")
            return
        }

        if microphoneGranted, session.canAddOutput(audioOutput) {
            session.addOutput(audioOutput)
            audioOutput.setSampleBufferDelegate(self, queue: captureQueue)
        } else {
            microphoneGranted = false
        }

        guard session.canAddOutput(photoOutput) else {
            updateStatus("PHOTO OUTPUT UNAVAILABLE")
            return
        }
        session.addOutput(photoOutput)
        photoOutput.maxPhotoQualityPrioritization = .quality
        if let connection = photoOutput.connection(with: .video),
           connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }
        configured = true
        configureFrameRate()
    }

    private func configureFrameRate() {
        pendingField = nil
        samplingOrigin = .invalid
        lastSampleIndex = -1
        guard let camera else { return }

        // Use a 30 fps source for progressive modes; select presentation slots below.
        // 20p and 25p may be uneven when the sensor cannot deliver the requested rate.
        let desired = activeProfile.prefersTemporalFields ? 50.0 : Double(activeProfile.videoFPS)
        let supported = camera.activeFormat.videoSupportedFrameRateRanges.contains {
            $0.minFrameRate <= desired && $0.maxFrameRate >= desired
        }
        let rate = supported ? desired : 30.0
        let rateIsSupported = camera.activeFormat.videoSupportedFrameRateRanges.contains {
            $0.minFrameRate <= rate && $0.maxFrameRate >= rate
        }
        fiftyFPSActive = supported && desired == 50.0
        if rateIsSupported {
            do {
                try camera.lockForConfiguration()
                let duration = CMTime(value: 1, timescale: CMTimeScale(Int32(rate)))
                camera.activeVideoMinFrameDuration = duration
                camera.activeVideoMaxFrameDuration = duration
                camera.unlockForConfiguration()
            } catch {
                fiftyFPSActive = false
            }
        }
        let fields = fiftyFPSActive
        DispatchQueue.main.async { self.hasFiftyFPS = fields }
    }

    func select(_ profile: CameraProfile) {
        captureQueue.async {
            guard self.recorder == nil else { return }
            self.activeProfile = profile
            self.configureFrameRate()
            self.updateStatus("PROFILE: \(profile.name)")
        }
    }

    func setZoom(_ factor: Double) {
        captureQueue.async {
            guard let device = self.camera else { return }
            do {
                try device.lockForConfiguration()
                let maximum = min(device.activeFormat.videoMaxZoomFactor, 6.0)
                device.ramp(toVideoZoomFactor: CGFloat(max(1, min(factor, Double(maximum)))),
                            withRate: 5)
                device.unlockForConfiguration()
            } catch {
                self.updateStatus("ZOOM UNAVAILABLE")
            }
        }
    }

    func setFlash(_ enabled: Bool) {
        captureQueue.async { self.isFlashEnabled = enabled }
    }

    func shootPhoto() {
        captureQueue.async {
            guard self.configured, self.recorder == nil else { return }
            let settings = AVCapturePhotoSettings()
            settings.photoQualityPrioritization = .quality
            if self.camera?.hasFlash == true {
                settings.flashMode = self.isFlashEnabled ? .on : .off
            }
            self.photoProfile = self.activeProfile
            self.photoOutput.capturePhoto(with: settings, delegate: self)
            self.updateStatus("EXPOSING FRAME")
        }
    }

    func toggleRecording() {
        captureQueue.async {
            if self.recorder == nil {
                guard self.configured, self.session.isRunning else { return }
                guard let writer = VideoRecorder(
                    profile: self.activeProfile, microphone: self.microphoneGranted
                ) else {
                    self.updateStatus("ENCODER UNAVAILABLE")
                    return
                }
                self.pendingField = nil
                self.samplingOrigin = .invalid
                self.lastSampleIndex = -1
                self.recorder = writer
                let started = Date()
                DispatchQueue.main.async {
                    self.isRecording = true
                    self.recordingSince = started
                    self.status = "RECORDING"
                }
            } else {
                self.stopRecordingOnQueue()
            }
        }
    }

    private func stopRecordingOnQueue() {
        guard let writer = recorder else { return }
        recorder = nil
        pendingField = nil
        DispatchQueue.main.async {
            self.isRecording = false
            self.recordingSince = nil
            self.status = "FINALIZING FILE"
        }
        writer.finish { [weak self] result in
            switch result {
            case .success(let url):
                self?.saveVideo(url)
            case .failure(let error):
                self?.updateStatus("VIDEO ERROR: \(error.localizedDescription)")
            }
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if output === audioOutput {
            recorder?.appendAudio(sampleBuffer)
            return
        }
        guard output === videoOutput, let renderer,
              let current = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        let first: CVPixelBuffer
        let second: CVPixelBuffer?
        if activeProfile.prefersTemporalFields && fiftyFPSActive {
            guard let previous = pendingField else {
                pendingField = sampleBuffer
                return
            }
            pendingField = nil
            guard let oldImage = CMSampleBufferGetImageBuffer(previous) else { return }
            first = oldImage
            second = current
        } else {
            if !samplingOrigin.isValid { samplingOrigin = time }
            // Quantize to presentation slots so 30fps input can yield ~25fps,
            // rather than accidentally dropping every other frame (~15fps).
            let elapsed = max(0, CMTimeGetSeconds(time - samplingOrigin))
            let index = Int(elapsed * Double(activeProfile.videoFPS) + 0.001)
            if index <= lastSampleIndex { return }
            lastSampleIndex = index
            first = current
            second = nil
        }

        let profile = activeProfile
        guard let target = renderer.makePixelBuffer(
            width: profile.videoWidth, height: profile.videoHeight
        ), let frame = renderer.render(
            first: first, second: second, output: target,
            profile: profile, time: time
        ) else { return }
        preview.publish(frame)
        recorder?.appendVideo(frame.pixelBuffer, at: time)
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        guard error == nil, let data = photo.fileDataRepresentation(),
              let renderer else {
            updateStatus("STILL CAPTURE FAILED")
            return
        }
        let profile = photoProfile ?? activeProfile
        photoProfile = nil
        photoQueue.async {
            guard let jpeg = renderer.processStill(data, profile: profile) else {
                self.updateStatus("STILL PROCESSING FAILED")
                return
            }
            self.savePhoto(jpeg)
        }
    }

    private func savePhoto(_ data: Data) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                self.updateStatus("PHOTOS PERMISSION DENIED")
                return
            }
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
            } completionHandler: { saved, error in
                self.updateStatus(
                    saved ? "PHOTO SAVED TO PHOTOS" :
                        "SAVE FAILED: \(error?.localizedDescription ?? "Unknown")"
                )
            }
        }
    }

    private func saveVideo(_ url: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                try? FileManager.default.removeItem(at: url)
                self.updateStatus("PHOTOS PERMISSION DENIED")
                return
            }
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .video, fileURL: url, options: nil)
            } completionHandler: { saved, error in
                try? FileManager.default.removeItem(at: url)
                self.updateStatus(
                    saved ? "VIDEO SAVED TO PHOTOS" :
                        "SAVE FAILED: \(error?.localizedDescription ?? "Unknown")"
                )
            }
        }
    }

    private func updateStatus(_ value: String) {
        DispatchQueue.main.async { self.status = value }
    }
}

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

    @Published private(set) var zoomFactor = 1.0
    @Published private(set) var touchZoomLimit = 1.0
    @Published private(set) var flashAvailable = false
    @Published private(set) var torchAvailable = false
    @Published private(set) var flashOn = false
    @Published private(set) var torchOn = false
    @Published private(set) var controlsFullscreen = false

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
    private var wantsSession = false
    private var sideControlsEnabled = true
    private var deviceObservations: [NSKeyValueObservation] = []
    private var activeProfile = CameraProfile.startup
    private var orientation: AVCaptureVideoOrientation = .landscapeRight
    private var recorder: VideoRecorder?
    private var microphoneGranted = false
    private var fiftyFPSActive = false
    private var pendingField: CMSampleBuffer?
    private var samplingOrigin: CMTime = .invalid
    private var cadenceSampler = CadenceSampler()
    private var captureMode: CaptureMode = .photo
    private var isFlashEnabled = false
    private var photoProfile: CameraProfile?
    private var photoGain: Float = 1

    override init() {
        renderer = RenderEngine()
        super.init()
        if renderer == nil {
            updateStatus("METAL UNAVAILABLE")
        }
    }

    func start() {
        guard renderer != nil else { return }
        captureQueue.async { self.wantsSession = true }
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.updateStatus("CAMERA ACCESS DENIED")
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] micGranted in
                guard let self else { return }
                self.captureQueue.async {
                    guard self.wantsSession else { return }
                    self.microphoneGranted = micGranted
                    if !self.configured { self.configure() }
                    if self.configured && !self.session.isRunning {
                        self.session.startRunning()
                        self.publishLighting()
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
            self.wantsSession = false
            if self.recorder != nil { self.stopRecordingOnQueue() }
            self.setTorchOnQueue(false)
            self.pendingField = nil
            self.preview.clear()
            if self.session.isRunning { self.session.stopRunning() }
            DispatchQueue.main.async { self.isReady = false; self.controlsFullscreen = false }
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
                connection.videoOrientation = orientation
                if connection.isVideoStabilizationSupported { connection.preferredVideoStabilizationMode = .off }
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
        photoOutput.maxPhotoQualityPrioritization = .speed
        if let connection = photoOutput.connection(with: .video),
           connection.isVideoOrientationSupported {
            connection.videoOrientation = orientation
        }
        deviceObservations = [
            device.observe(\.videoZoomFactor, options: [.initial, .new]) { [weak self] _, change in
                guard let value = change.newValue else { return }
                DispatchQueue.main.async { self?.zoomFactor = Double(value) }
                if #available(iOS 18.0, *) {
                    self?.captureQueue.async { [weak self] in
                        guard let slider = self?.session.controls.first as? AVCaptureSlider else { return }
                        slider.value = Float(value)
                    }
                }
            },
            device.observe(\.isTorchAvailable, options: [.new]) { [weak self] _, _ in
                self?.refreshLighting()
            },
            device.observe(\.isTorchActive, options: [.new]) { [weak self] _, _ in
                self?.refreshLighting()
            },
            device.observe(\.isFlashAvailable, options: [.new]) { [weak self] _, _ in
                self?.refreshLighting()
            }
        ]
        if #available(iOS 18.0, *) { configureSideZoom(device) }
        let limit = Double(min(6, device.maxAvailableVideoZoomFactor))
        DispatchQueue.main.async { self.touchZoomLimit = max(1, limit) }
        configured = true
        configureFrameRate()
    }

    private func configureFrameRate() {
        pendingField = nil
        samplingOrigin = .invalid
        cadenceSampler.reset()
        guard let camera else { return }

        let desired = activeProfile.prefersTemporalFields ? 50.0 : Double(activeProfile.videoFPS)
        let ranges = camera.activeFormat.videoSupportedFrameRateRanges
        let rangeForRate: (Double) -> AVFrameRateRange? = { rate in
            ranges.filter { $0.minFrameRate <= rate && $0.maxFrameRate >= rate }
                .max { $0.maxFrameDuration < $1.maxFrameDuration }
        }
        let preferred = rangeForRate(desired)
        let rate = preferred == nil ? 30.0 : desired
        fiftyFPSActive = preferred != nil && desired == 50.0
        if let range = preferred ?? rangeForRate(rate) {
            do {
                try camera.lockForConfiguration()
                let duration = CMTime(value: 1, timescale: CMTimeScale(rate))
                let slowStill = captureMode == .photo && activeProfile.id == CameraProfile.ccd3MP.id
                let longest = slowStill ? max(duration, min(CMTime(value: 1, timescale: 8),
                                                            range.maxFrameDuration)) : duration
                camera.activeVideoMinFrameDuration = duration
                camera.activeVideoMaxFrameDuration = longest
                if camera.isExposureModeSupported(.continuousAutoExposure) {
                    camera.exposureMode = .continuousAutoExposure
                    camera.activeMaxExposureDuration = slowStill
                        ? max(camera.activeFormat.minExposureDuration,
                              min(longest, camera.activeFormat.maxExposureDuration)) : .invalid
                }
                if camera.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    camera.whiteBalanceMode = .continuousAutoWhiteBalance
                }
                camera.automaticallyAdjustsVideoHDREnabled = false
                if camera.activeFormat.isVideoHDRSupported { camera.isVideoHDREnabled = false }
                if camera.isFocusModeSupported(.autoFocus) { camera.focusMode = .autoFocus }
                camera.unlockForConfiguration()
            } catch {
                fiftyFPSActive = false
            }
        }
        let fields = fiftyFPSActive
        DispatchQueue.main.async { self.hasFiftyFPS = fields }
    }

    func orient(_ interface: UIInterfaceOrientation) {
        let next: AVCaptureVideoOrientation
        switch interface {
        case .landscapeLeft: next = .landscapeLeft
        case .landscapeRight: next = .landscapeRight
        case .portraitUpsideDown: next = .portraitUpsideDown
        default: next = .portrait
        }
        captureQueue.async {
            guard self.orientation != next else { return }
            self.orientation = next
            for output in [self.videoOutput as AVCaptureOutput, self.photoOutput] {
                if let connection = output.connection(with: .video), connection.isVideoOrientationSupported {
                    connection.videoOrientation = next
                }
            }
            self.pendingField = nil
            self.preview.clear()
        }
    }

    func select(_ profile: CameraProfile) {
        captureQueue.async {
            guard self.recorder == nil else { return }
            self.preview.clear()
            self.activeProfile = profile
            self.configureFrameRate()
            self.updateStatus("PROFILE: \(profile.name)")
        }
    }

    func setMode(_ mode: CaptureMode) {
        captureQueue.async {
            guard self.recorder == nil, self.captureMode != mode else { return }
            if mode == .photo { self.setTorchOnQueue(false) }
            self.captureMode = mode
            self.configureFrameRate()
        }
    }

    func setZoom(_ factor: Double) {
        captureQueue.async {
            guard let device = self.camera else { return }
            do {
                try device.lockForConfiguration()
                let maximum = min(device.maxAvailableVideoZoomFactor, max(6.0, device.videoZoomFactor))
                device.ramp(toVideoZoomFactor: CGFloat(max(1, min(factor, Double(maximum)))),
                            withRate: 5)
                device.unlockForConfiguration()
            } catch {
                self.updateStatus("ZOOM UNAVAILABLE")
            }
        }
    }

    func refocus() {
        captureQueue.async {
            guard let device = self.camera else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5)
                }
                if device.isFocusModeSupported(.autoFocus) { device.focusMode = .autoFocus }
                device.unlockForConfiguration()
                self.updateStatus("FOCUSING")
            } catch { self.updateStatus("FOCUS UNAVAILABLE") }
        }
    }

    @available(iOS 18.0, *)
    private func configureSideZoom(_ device: AVCaptureDevice) {
        guard session.supportsControls, device.maxAvailableVideoZoomFactor > 1 else { return }
        let zoomControl: AVCaptureControl
        if device.activeFormat.systemRecommendedVideoZoomRange != nil {
            zoomControl = AVCaptureSystemZoomSlider(device: device)
        } else {
            let limit = Float(min(6, device.maxAvailableVideoZoomFactor))
            let slider = AVCaptureSlider("Zoom", symbolName: "plus.magnifyingglass", in: 1...limit)
            slider.value = Float(device.videoZoomFactor)
            slider.setActionQueue(captureQueue) { [weak self] value in
                self?.setZoom(Double(value))
            }
            zoomControl = slider
        }
        guard session.canAddControl(zoomControl) else { return }
        zoomControl.isEnabled = sideControlsEnabled
        session.setControlsDelegate(self, queue: .main)
        session.addControl(zoomControl)
    }

    func enableSideControls(_ enabled: Bool) {
        if #available(iOS 18.0, *) {
            captureQueue.async {
                self.sideControlsEnabled = enabled
                for control in self.session.controls { control.isEnabled = enabled }
            }
        }
    }

    private func refreshLighting() {
        captureQueue.async { self.publishLighting() }
    }

    private func publishLighting() {
        let canFlash = camera?.isFlashAvailable == true && photoOutput.supportedFlashModes.contains(.on)
        let canLight = camera?.isTorchAvailable == true
        let selected = isFlashEnabled
        let lit = camera?.isTorchActive == true
        DispatchQueue.main.async {
            self.flashAvailable = canFlash
            self.torchAvailable = canLight
            self.flashOn = selected
            self.torchOn = lit
        }
    }

    func toggleLight() {
        captureQueue.async {
            if self.captureMode == .video {
                self.setTorchOnQueue(self.camera?.torchMode != .on)
            } else if self.camera?.isFlashAvailable == true && self.photoOutput.supportedFlashModes.contains(.on) {
                self.isFlashEnabled.toggle()
            }
            self.publishLighting()
        }
    }

    private func setTorchOnQueue(_ enabled: Bool) {
        guard let device = camera, device.hasTorch,
              device.isTorchModeSupported(enabled ? .on : .off),
              enabled ? device.isTorchAvailable : device.torchMode != .off else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if enabled {
                try device.setTorchModeOn(level: min(0.6, AVCaptureDevice.maxAvailableTorchLevel))
            } else {
                device.torchMode = .off
            }
        } catch { updateStatus("VIDEO LIGHT UNAVAILABLE") }
    }

    func shootPhoto() {
        captureQueue.async {
            guard self.configured, self.recorder == nil, self.photoProfile == nil else { return }
            // A camcorder frame grab uses the same optics, exposure and SD
            // sample as the finder. Physical flash needs a still exposure.
            if self.activeProfile.family == .camcorder, !self.isFlashEnabled,
               let frame = self.preview.current(), let renderer = self.renderer {
                let quality = self.activeProfile.jpegQuality
                self.photoQueue.async {
                    guard let jpeg = renderer.jpeg(frame.pixelBuffer, quality: quality) else {
                        self.updateStatus("STILL PROCESSING FAILED")
                        return
                    }
                    self.savePhoto(jpeg)
                }
                return
            }
            let settings = AVCapturePhotoSettings()
            settings.photoQualityPrioritization = .speed
            if self.isFlashEnabled, self.camera?.isFlashAvailable == true,
               self.photoOutput.supportedFlashModes.contains(.on) { settings.flashMode = .on }
            self.photoProfile = self.activeProfile
            self.photoGain = self.camera.map { Float($0.iso / max($0.activeFormat.minISO, 1)) } ?? 1
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
                self.cadenceSampler.reset()
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

        let profile = activeProfile
        let gain = camera.map { Float($0.iso / max($0.activeFormat.minISO, 1)) } ?? 1

        if profile.prefersTemporalFields && fiftyFPSActive {
            // Display each source instant separately. The recorder receives paired
            // instants woven into alternating lines; its H.264 is still progressive.
            if let target = renderer.makePixelBuffer(width: profile.videoWidth, height: profile.videoHeight),
               let live = renderer.render(first: current, second: nil, output: target,
                                          profile: profile, time: time, gain: gain) {
                preview.publish(live)
            }
            guard recorder != nil else {
                pendingField = nil
                return
            }
            guard let previous = pendingField else {
                pendingField = sampleBuffer
                return
            }
            pendingField = nil
            guard let oldImage = CMSampleBufferGetImageBuffer(previous),
                  let target = renderer.makePixelBuffer(width: profile.videoWidth, height: profile.videoHeight),
                  let woven = renderer.render(first: oldImage, second: current, output: target,
                                              profile: profile, time: time, gain: gain) else { return }
            recorder?.appendVideo(woven.pixelBuffer, at: CMSampleBufferGetPresentationTimeStamp(previous))
            return
        }

        if !samplingOrigin.isValid { samplingOrigin = time }
        let elapsed = max(0, CMTimeGetSeconds(time - samplingOrigin))
        guard cadenceSampler.accept(elapsed: elapsed, fps: profile.videoFPS) else { return }
        let fullPhotoFinder = captureMode == .photo && profile.id == CameraProfile.ccd3MP.id && recorder == nil
        let width = fullPhotoFinder ? 960 : profile.videoWidth
        let height = fullPhotoFinder ? 720 : profile.videoHeight
        guard let target = renderer.makePixelBuffer(width: width, height: height),
              let frame = renderer.render(first: current, second: nil, output: target,
                                          profile: profile, time: time, gain: gain) else { return }
        preview.publish(frame)
        recorder?.appendVideo(frame.pixelBuffer, at: time)
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // The capture output discarded a source frame before it reached our sampler.
        if output === videoOutput { recorder?.noteDroppedVideoFrame() }
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        guard error == nil, let data = photo.fileDataRepresentation(),
              let renderer else {
            captureQueue.async { self.photoProfile = nil }
            updateStatus("STILL CAPTURE FAILED")
            return
        }
        captureQueue.async {
            let profile = self.photoProfile ?? self.activeProfile
            let gain = self.photoGain
            self.photoProfile = nil
            self.photoQueue.async {
                guard let jpeg = renderer.processStill(data, profile: profile, gain: gain) else {
                    self.updateStatus("STILL PROCESSING FAILED")
                    return
                }
                self.savePhoto(jpeg)
            }
        }
    }

    func savePhoto(_ data: Data, completion: ((Bool, String) -> Void)? = nil) {
        func finish(_ success: Bool, _ message: String) {
            DispatchQueue.main.async {
                self.status = message
                completion?(success, message)
            }
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                finish(false, "PHOTOS PERMISSION DENIED")
                return
            }
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
            } completionHandler: { saved, error in
                finish(saved, saved ? "PHOTO SAVED TO PHOTOS" :
                           "SAVE FAILED: \(error?.localizedDescription ?? "Unknown")")
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


@available(iOS 18.0, *)
extension CaptureEngine: AVCaptureSessionControlsDelegate {
    func sessionControlsDidBecomeActive(_ session: AVCaptureSession) {}
    func sessionControlsWillEnterFullscreenAppearance(_ session: AVCaptureSession) { controlsFullscreen = true }
    func sessionControlsWillExitFullscreenAppearance(_ session: AVCaptureSession) { controlsFullscreen = false }
    func sessionControlsDidBecomeInactive(_ session: AVCaptureSession) { controlsFullscreen = false }
}

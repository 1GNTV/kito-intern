import SwiftUI
import AVKit

struct CameraScreen: View {
    @StateObject private var camera = CaptureEngine()
    @State private var profile = CameraProfile.startup
    @State private var mode: CaptureMode = .photo
    @Environment(\.scenePhase) private var scenePhase
    @State private var settingsOpen = false

    var body: some View {
        cameraBody
            .modifier(HardwareShutter(enabled: camera.isReady && !settingsOpen && scenePhase == .active,
                                      shutter: releaseShutter))
    }

    private var cameraBody: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let width = min(size.width, size.height * 4 / 3)
            ZStack {
                finder.frame(width: width, height: width * 3 / 4)
                HStack {
                    accessoryRail.frame(width: 56)
                    Spacer(minLength: 0)
                    grip.frame(width: 92)
                }
                .padding(.horizontal, 4)
                .opacity(camera.controlsFullscreen ? 0 : 1)
                .allowsHitTesting(!camera.controlsFullscreen)
                .accessibilityHidden(camera.controlsFullscreen)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea(.container, edges: .vertical)
        .statusBarHidden(true)
        .background(CameraBody().ignoresSafeArea())
        .foregroundStyle(ArchiveStyle.chalk)
        .onAppear { camera.select(profile); camera.start() }
        .onDisappear { camera.stop() }
        .onChange(of: mode) { _, value in camera.setMode(value) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { camera.stop() }
            if phase == .active && !camera.isReady { camera.start() }
        }
        .onChange(of: settingsOpen) { _, shown in camera.enableSideControls(!shown) }
        .task(id: camera.status) {
            statusVisible = true
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            statusVisible = false
        }
        .sheet(isPresented: $settingsOpen) { settings }
    }

    private var accessoryRail: some View {
        VStack(spacing: 16) {
            Button { settingsOpen = true } label: {
                Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44)
                    .modifier(CameraGlass(shape: Circle()))
            }
            .disabled(camera.isRecording)
            .accessibilityLabel("Camera settings")
            let isPhoto = mode == .photo
            let on = isPhoto ? camera.flashOn : camera.torchOn
            let available = isPhoto ? camera.flashAvailable : camera.torchAvailable
            Button { camera.toggleLight() } label: {
                VStack(spacing: 2) {
                    Image(systemName: isPhoto ? (on ? "bolt.fill" : "bolt.slash")
                                              : (on ? "flashlight.on.fill" : "flashlight.off.fill"))
                    Text(isPhoto ? "FLASH" : "LIGHT")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                }
                .foregroundStyle(on ? ArchiveStyle.signal : ArchiveStyle.chalk)
                .frame(width: 52, height: 48)
                .modifier(CameraGlass(shape: RoundedRectangle(cornerRadius: 13)))
            }
            .disabled(!camera.isReady || !available)
            .accessibilityLabel(isPhoto ? "Photo flash" : "Video light")
            .accessibilityValue(available ? (on ? "On" : "Off") : "Unavailable")
            if !isPhoto {
                Image(systemName: camera.hasMicrophone ? "mic.fill" : "mic.slash")
                    .font(.caption)
                    .accessibilityLabel(camera.hasMicrophone ? "Mono microphone on" : "Microphone unavailable")
            }
        }
        .buttonStyle(.plain)
    }

    private var grip: some View {
        VStack(spacing: 19) {
            HStack(spacing: 0) {
                ForEach(CaptureMode.allCases, id: \.self) { selection in
                    Button { mode = selection } label: {
                        Image(systemName: selection == .photo ? "camera.fill" : "video.fill")
                            .font(.system(size: 14)).frame(maxWidth: .infinity, minHeight: 42)
                            .foregroundStyle(selection == mode ? ArchiveStyle.chalk : ArchiveStyle.muted)
                            .background {
                                if selection == mode { Color.clear.modifier(CameraGlass(shape: Capsule())) }
                            }
                            .contentShape(Capsule())
                    }
                    .accessibilityLabel(selection == .photo ? "Photo" : "Video")
                    .accessibilityAddTraits(selection == mode ? [.isSelected] : [])
                }
            }
            .padding(2).background(.black.opacity(0.70), in: Capsule())
            .disabled(camera.isRecording)

            Button(action: releaseShutter) {
                ShutterCap(video: mode == .video, recording: camera.isRecording)
            }
            .buttonStyle(ShutterPress())
            .disabled(!camera.isReady)
            .accessibilityLabel(mode == .photo ? "Take photo" : (camera.isRecording ? "Stop recording" : "Record video"))

            HStack(spacing: 0) {
                rocker("W", step: -0.5)
                Rectangle().fill(ArchiveStyle.line).frame(width: 1, height: 16)
                rocker("T", step: 0.5)
            }
            .modifier(CameraGlass(shape: Capsule()))
        }
        .buttonStyle(.plain)
    }

    private func releaseShutter() {
        if mode == .photo { camera.shootPhoto() } else { camera.toggleRecording() }
    }

    private func rocker(_ label: String, step: Double) -> some View {
        Button { camera.setZoom(camera.zoomFactor + step) } label: {
            Text(label).font(.system(size: 12, weight: .bold, design: .monospaced))
                .frame(maxWidth: .infinity, minHeight: 42).contentShape(Rectangle())
        }
        .accessibilityLabel(step > 0 ? "Zoom in" : "Zoom out")
    }

    private var finder: some View {
        ZStack {
            Color.black
            if let renderer = camera.renderer {
                MetalPreview(renderer: renderer, store: camera.preview, orientationChanged: camera.orient)
            }
            VStack {
                HStack {
                    Text(profile.name)
                    Spacer()
                    if camera.isRecording {
                        TimelineView(.periodic(from: .now, by: 1)) { clock in
                            let seconds = max(0, Int(clock.date.timeIntervalSince(camera.recordingSince ?? clock.date)))
                            HStack(spacing: 5) {
                                Circle().fill(ArchiveStyle.recording).frame(width: 7, height: 7)
                                Text(String(format: "REC %02d:%02d", seconds / 60, seconds % 60))
                            }
                        }
                    } else { Text(camera.isReady ? "STBY" : "OFF") }
                }
                Spacer()
                HStack {
                    Text(String(format: "AF   %.1f×", camera.zoomFactor))
                    Spacer()
                    Text(mode == .photo ? "4:3" : cadenceTitle)
                }
            }
            .opacity(camera.controlsFullscreen ? 0 : 1)
            .padding(11)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white).shadow(color: .black, radius: 2)
            if showStatus {
                Text(camera.status)
                    .font(.system(size: 10, design: .monospaced)).multilineTextAlignment(.center)
                    .padding(8).background(.black.opacity(0.62), in: Capsule())
            }
        }
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture { camera.refocus() }
        .accessibilityLabel("Camera viewfinder. Tap to refocus.")
    }

    private var showStatus: Bool {
        !camera.isReady || (camera.status != "CAMERA READY" && camera.status != "RECORDING"
            && !camera.status.hasPrefix("PROFILE:") && statusVisible)
    }

    @State private var statusVisible = false
    private var cadenceTitle: String {
        profile.prefersTemporalFields ? (camera.hasFiftyFPS ? "50i" : "25p") : "\(profile.videoFPS)p"
    }

    private var settings: some View {
        NavigationStack {
            Form {
                Section("Camera") {
                    ForEach(CameraProfile.all) { device in
                        Button {
                            profile = device
                            camera.select(device)
                            camera.setZoom(1)
                            settingsOpen = false
                        } label: {
                            HStack {
                                Text(device.name)
                                Spacer()
                                if profile.id == device.id { Image(systemName: "checkmark") }
                            }
                        }
                    }
                }
                if mode == .video {
                    Section("Frame rate") {
                        ForEach([15, 20, 25], id: \.self) { fps in
                            Button("\(fps)p") { setCadence(fps, fields: false) }
                        }
                        if profile.family == .camcorder {
                            Button("PAL 50i") { setCadence(25, fields: true) }
                        }
                    }
                }
                if let renderer = camera.renderer {
                    Section {
                        NavigationLink("Import photo") {
                            PhotoImportView(renderer: renderer, profile: profile) { data, done in
                                camera.savePhoto(data, completion: done)
                            }
                        }
                    }
                }
                Section("Zoom") {
                    Slider(value: Binding(get: { camera.zoomFactor }, set: { camera.setZoom($0) }),
                           in: 1...max(1.1, camera.touchZoomLimit, camera.zoomFactor), step: 0.1)
                        .disabled(camera.touchZoomLimit <= 1)
                        .accessibilityLabel("Zoom")
                }
                Section {
                    Text("ArchiveCam 0.9 · \(profile.photoWidth)×\(profile.photoHeight) JPEG · \(profile.videoWidth)×\(profile.videoHeight) video")
                        .font(.footnote)
                }
            }
            .tint(ArchiveStyle.chalk)
            .navigationTitle("Camera settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { settingsOpen = false } } }
        }
    }

    private func setCadence(_ fps: Int, fields: Bool) {
        profile.videoFPS = fps
        profile.prefersTemporalFields = fields
        camera.select(profile)
        settingsOpen = false
    }
}


private struct HardwareShutter: ViewModifier {
    let enabled: Bool
    let shutter: () -> Void

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onCameraCaptureEvent(isEnabled: enabled) { event in
                if event.phase == .ended { shutter() }
            }
        } else {
            content
        }
    }
}

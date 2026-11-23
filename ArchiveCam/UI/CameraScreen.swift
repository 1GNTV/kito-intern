import SwiftUI

struct CameraScreen: View {
    @StateObject private var camera = CaptureEngine()
    @State private var profile = CameraProfile.startup
    @State private var mode: CaptureMode = .photo
    @State private var flash = false
    @State private var zoom = 1.0
    @State private var settingsOpen = false

    var body: some View {
        GeometryReader { geometry in
            let gutter: CGFloat = 8
            let available = geometry.size
            let rightWidth = min(112, available.width * 0.18)
            let leftWidth = min(66, available.width * 0.11)
            let width = min((available.height - 24) * 4 / 3,
                            available.width - leftWidth - rightWidth - 4 * gutter - 12)
            HStack(spacing: gutter) {
                accessoryRail.frame(width: leftWidth)
                Spacer(minLength: 0)
                finder.frame(width: max(1, width), height: max(1, width * 3 / 4))
                    .padding(5)
                    .background(.black, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.20), lineWidth: 1))
                Spacer(minLength: 0)
                grip.frame(width: rightWidth)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(CameraBody().ignoresSafeArea())
        .foregroundStyle(ArchiveStyle.chalk)
        .onAppear { camera.select(profile); camera.start() }
        .onDisappear { camera.stop() }
        .onChange(of: zoom) { _, value in camera.setZoom(value) }
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
            if mode == .photo {
                Button {
                    flash.toggle()
                    camera.setFlash(flash)
                } label: {
                    Image(systemName: flash ? "bolt.fill" : "bolt.slash")
                        .foregroundStyle(flash ? ArchiveStyle.signal : ArchiveStyle.chalk)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(flash ? "Turn flash off" : "Turn flash on")
            } else {
                Image(systemName: camera.hasMicrophone ? "mic.fill" : "mic.slash")
                    .frame(width: 44, height: 44)
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

            Button {
                if mode == .photo { camera.shootPhoto() } else { camera.toggleRecording() }
            } label: {
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

    private func rocker(_ label: String, step: Double) -> some View {
        Button { zoom = min(6, max(1, zoom + step)) } label: {
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
                    Text(String(format: "AF   %.1f×", zoom))
                    Spacer()
                    Text(mode == .photo ? "4:3" : cadenceTitle)
                }
            }
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
                            zoom = 1
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
                Section("Zoom") {
                    Slider(value: $zoom, in: 1...6, step: 0.1)
                        .accessibilityLabel("Zoom")
                }
                Section {
                    Text("ArchiveCam 0.7 · \(profile.photoWidth)×\(profile.photoHeight) JPEG · \(profile.videoWidth)×\(profile.videoHeight) video")
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

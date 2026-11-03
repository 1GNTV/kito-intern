import SwiftUI

private enum ArchiveStyle {
    static let background = Color(red: 0.052, green: 0.057, blue: 0.063)
    static let surface = Color(red: 0.088, green: 0.094, blue: 0.099)
    static let line = Color(red: 0.23, green: 0.25, blue: 0.26)
    static let chalk = Color(red: 0.91, green: 0.90, blue: 0.85)
    static let muted = Color(red: 0.54, green: 0.57, blue: 0.57)
    static let signal = Color(red: 0.76, green: 0.85, blue: 0.70)
    static let recording = Color(red: 0.91, green: 0.27, blue: 0.22)
}

struct CameraScreen: View {
    @StateObject private var camera = CaptureEngine()
    @State private var profile = CameraProfile.compact04
    @State private var mode: CaptureMode = .photo
    @State private var flash = false
    @State private var zoom: Double = 1.0
    @State private var showingDevices = false
    @State private var showingInfo = false

    var body: some View {
        GeometryReader { geo in
            let availableWidth = max(180, geo.size.width - 40)
            let finderHeight = min(availableWidth * 4.0 / 3.0, geo.size.height * 0.54)

            VStack(spacing: 0) {
                masthead
                deviceSelector
                    .padding(.top, 21)

                Spacer(minLength: 12)

                viewfinder
                    .frame(height: finderHeight)
                    .accessibilityLabel("Simulated live camera preview")

                Spacer(minLength: 13)

                controls
                footer
                    .padding(.top, 18)
                    .padding(.bottom, 8)
            }
            .padding(.horizontal, 20)
            .padding(.top, 7)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ArchiveStyle.background.ignoresSafeArea())
        }
        .onAppear {
            camera.select(profile)
            camera.start()
        }
        .onDisappear { camera.stop() }
        .sheet(isPresented: $showingDevices) { deviceSheet }
        .sheet(isPresented: $showingInfo) { infoSheet }
    }

    private var masthead: some View {
        HStack(alignment: .center) {
            HStack(spacing: 9) {
                Image(systemName: "circle.hexagongrid")
                    .font(.system(size: 15, weight: .light))
                    .foregroundStyle(ArchiveStyle.chalk)
                Text("ARCHIVE / CAMERA")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(ArchiveStyle.chalk)
            }
            Spacer()
            Text("BETA  01")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(ArchiveStyle.muted)
            Button { showingInfo = true } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 17, weight: .light))
                    .foregroundStyle(ArchiveStyle.muted)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("About accuracy and limitations")
        }
    }

    private var deviceSelector: some View {
        Button {
            if !camera.isRecording { showingDevices = true }
        } label: {
            HStack(spacing: 15) {
                Image(systemName: profile.family == .compact ? "camera" : "video")
                    .font(.system(size: 18, weight: .ultraLight))
                    .frame(width: 32, height: 32)
                    .foregroundStyle(ArchiveStyle.chalk)
                VStack(alignment: .leading, spacing: 5) {
                    Text(profile.name)
                        .font(.system(size: 19, weight: .medium, design: .monospaced))
                        .tracking(0.5)
                        .foregroundStyle(ArchiveStyle.chalk)
                    Text("\(profile.era)  ·  \(profile.family.rawValue)")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(ArchiveStyle.muted)
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(ArchiveStyle.muted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .background(ArchiveStyle.surface)
            .overlay(Rectangle().stroke(ArchiveStyle.line, lineWidth: 0.75))
        }
        .buttonStyle(.plain)
        .disabled(camera.isRecording)
        .accessibilityLabel("Choose historical camera profile")
    }

    private var viewfinder: some View {
        ZStack {
            Rectangle().fill(Color.black)
            if let renderer = camera.renderer {
                MetalPreview(renderer: renderer, store: camera.preview)
                    .clipped()
            }
            Rectangle()
                .stroke(ArchiveStyle.chalk.opacity(0.24), lineWidth: 0.7)
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("CAM  /  \(profile.id.uppercased())")
                        Text(mode == .video
                             ? "\(profile.videoWidth)×\(profile.videoHeight)  \(profile.videoFPS)P"
                             : "\(profile.photoWidth)×\(profile.photoHeight)  JPEG")
                    }
                    Spacer()
                    if camera.isRecording {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            let seconds = max(0, Int(Date().timeIntervalSince(
                                camera.recordingSince ?? Date()
                            )))
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(ArchiveStyle.recording)
                                    .frame(width: 7, height: 7)
                                Text(String(format: "%02d:%02d", seconds / 60, seconds % 60))
                            }
                            .foregroundStyle(ArchiveStyle.chalk)
                        }
                    } else {
                        Text(camera.isReady ? "STBY" : "OFF")
                    }
                }
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(ArchiveStyle.chalk)
                .shadow(color: .black, radius: 4)

                Spacer()

                if camera.isReady && !camera.isRecording {
                    Image(systemName: "viewfinder")
                        .font(.system(size: 49, weight: .ultraLight))
                        .foregroundStyle(ArchiveStyle.chalk.opacity(0.43))
                } else if !camera.isReady {
                    Text(camera.status)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(ArchiveStyle.chalk)
                        .padding(9)
                        .background(Color.black.opacity(0.62))
                }

                Spacer()

                HStack {
                    Text("AUTO / AF")
                    Spacer()
                    if profile.prefersTemporalFields && mode == .video {
                        Text(camera.hasFiftyFPS ? "50 FIELDS/S SOURCE" : "25P FALLBACK")
                    } else {
                        Text("4:3")
                    }
                }
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(ArchiveStyle.chalk)
                .shadow(color: .black, radius: 4)
            }
            .padding(13)
        }
        .aspectRatio(3.0 / 4.0, contentMode: .fit)
        .frame(maxWidth: .infinity)
    }

    private var controls: some View {
        VStack(spacing: 20) {
            HStack(spacing: 0) {
                ForEach(CaptureMode.allCases, id: \.self) { option in
                    Button {
                        guard !camera.isRecording else { return }
                        mode = option
                    } label: {
                        VStack(spacing: 9) {
                            Text(option.rawValue)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .tracking(2.0)
                                .foregroundStyle(
                                    mode == option ? ArchiveStyle.chalk : ArchiveStyle.muted
                                )
                            Rectangle()
                                .fill(mode == option ? ArchiveStyle.signal : .clear)
                                .frame(width: 70, height: 2)
                        }
                        .frame(width: 118)
                    }
                    .buttonStyle(.plain)
                    .disabled(camera.isRecording)
                }
            }

            if mode == .video {
                Menu {
                    ForEach([15, 20, 25], id: \.self) { fps in
                        Button("\(fps)P") {
                            profile.videoFPS = fps
                            profile.prefersTemporalFields = false
                            camera.select(profile)
                        }
                    }
                    if profile.family == .camcorder {
                        Button("PAL 50i (50 fields/s)") {
                            profile.videoFPS = 25
                            profile.prefersTemporalFields = true
                            camera.select(profile)
                        }
                    }
                } label: {
                    HStack {
                        Text("CADENCE")
                        Spacer()
                        Text(profile.prefersTemporalFields
                             ? (camera.hasFiftyFPS ? "PAL 50i SOURCE" : "25P FALLBACK")
                             : "\(profile.videoFPS)P")
                        Image(systemName: "chevron.up.chevron.down")
                    }
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(ArchiveStyle.chalk)
                }
                .disabled(camera.isRecording)
                .accessibilityLabel("Video cadence")
            }

            HStack(spacing: 16) {
                Text("W")
                    .foregroundStyle(ArchiveStyle.muted)
                Slider(value: $zoom, in: 1...6, step: 0.1)
                    .tint(ArchiveStyle.chalk)
                    .onChange(of: zoom) { _, value in camera.setZoom(value) }
                    .accessibilityLabel("Camera zoom")
                Text("T")
                    .foregroundStyle(ArchiveStyle.muted)
                Text(String(format: "%.1f×", zoom))
                    .foregroundStyle(ArchiveStyle.chalk)
                    .frame(width: 49, alignment: .trailing)
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced))

            HStack(spacing: 0) {
                VStack(spacing: 6) {
                    if mode == .photo {
                        Button {
                            flash.toggle()
                            camera.setFlash(flash)
                        } label: {
                            Image(systemName: flash ? "bolt.fill" : "bolt.slash")
                                .font(.system(size: 19, weight: .light))
                                .frame(width: 56, height: 43)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(flash ? "Disable flash" : "Enable flash")
                    } else {
                        Image(systemName: camera.hasMicrophone ? "mic" : "mic.slash")
                            .font(.system(size: 19, weight: .light))
                            .frame(width: 56, height: 43)
                    }
                    Text(mode == .photo ? (flash ? "FLASH ON" : "FLASH OFF")
                         : (camera.hasMicrophone ? "MIC ON" : "NO MIC"))
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundStyle(ArchiveStyle.muted)
                }
                .foregroundStyle(ArchiveStyle.chalk)
                .frame(maxWidth: .infinity)

                Button(action: primaryAction) {
                    ZStack {
                        Circle()
                            .stroke(ArchiveStyle.chalk, lineWidth: 2.5)
                            .frame(width: 77, height: 77)
                        if mode == .video {
                            RoundedRectangle(cornerRadius: camera.isRecording ? 4 : 29)
                                .fill(ArchiveStyle.recording)
                                .frame(
                                    width: camera.isRecording ? 27 : 58,
                                    height: camera.isRecording ? 27 : 58
                                )
                        } else {
                            Circle()
                                .fill(ArchiveStyle.chalk)
                                .frame(width: 61, height: 61)
                        }
                    }
                    .frame(width: 86, height: 86)
                }
                .buttonStyle(.plain)
                .disabled(!camera.isReady)
                .accessibilityLabel(mode == .photo ? "Take photograph" :
                                    (camera.isRecording ? "Stop video" : "Record video"))

                VStack(spacing: 8) {
                    Image(systemName: mode == .video ? "film.stack" : "photo")
                        .font(.system(size: 19, weight: .light))
                    Text(mode == .video ? "MP4 / AAC" : "JPEG")
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundStyle(ArchiveStyle.muted)
                }
                .frame(maxWidth: .infinity)
                .foregroundStyle(ArchiveStyle.chalk)
                .accessibilityLabel("Output format")
            }
        }
    }

    private func primaryAction() {
        switch mode {
        case .photo: camera.shootPhoto()
        case .video: camera.toggleRecording()
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            Rectangle().fill(ArchiveStyle.line).frame(height: 0.75)
            HStack(spacing: 7) {
                Circle()
                    .fill(camera.isReady ? ArchiveStyle.signal : ArchiveStyle.recording)
                    .frame(width: 5, height: 5)
                Text(camera.status)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                Text("LOCAL CAPTURE")
            }
            .font(.system(size: 8, weight: .medium, design: .monospaced))
            .tracking(0.3)
            .foregroundStyle(ArchiveStyle.muted)
        }
    }

    private var deviceSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ForEach(CameraProfile.all.indices, id: \.self) { index in
                    let device = CameraProfile.all[index]
                    Button {
                        profile = device
                        zoom = 1
                        camera.select(device)
                        camera.setZoom(1)
                        showingDevices = false
                    } label: {
                        HStack(alignment: .top, spacing: 16) {
                            Text(String(format: "%02d", index + 1))
                                .foregroundStyle(ArchiveStyle.muted)
                                .frame(width: 26, alignment: .leading)
                            VStack(alignment: .leading, spacing: 9) {
                                Text(device.name)
                                    .font(.system(size: 19, weight: .medium, design: .monospaced))
                                    .foregroundStyle(ArchiveStyle.chalk)
                                Text(device.era + " / " + device.family.rawValue)
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundStyle(ArchiveStyle.signal)
                                Text(device.descriptor)
                                    .font(.system(size: 12))
                                    .foregroundStyle(ArchiveStyle.muted)
                                    .multilineTextAlignment(.leading)
                            }
                            Spacer()
                            if device.id == profile.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(ArchiveStyle.signal)
                            }
                        }
                        .padding(.vertical, 23)
                        .padding(.horizontal, 20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(ArchiveStyle.line).frame(height: 0.5)
                        }
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Text("EXPERIMENTAL PROFILES / NOT YET CALIBRATED")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(ArchiveStyle.muted)
                    .padding(.bottom, 24)
            }
            .background(ArchiveStyle.background.ignoresSafeArea())
            .navigationTitle("CAMERA LIBRARY")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showingDevices = false }
                        .foregroundStyle(ArchiveStyle.chalk)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var infoSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("ENGINEERING, NOT A PRESET PACK.")
                        .font(.system(size: 22, weight: .medium, design: .monospaced))
                        .foregroundStyle(ArchiveStyle.chalk)
                    Text("Each historical profile changes optics, noise, color and capture cadence. The live preview is processed using Metal; photographs are exported as JPEG, videos as H.264/AAC MP4.")
                    Text("IMPORTANT: this is a physical-model prototype, not a measured replica. The coefficients have not yet been fitted to real 2000s camera reference captures. The iPhone flash, imaging pipeline and microphone remain limitations.")
                    Text("PAL 50i uses two camera instants when 50fps capture is supported. The live preview shows the individual source instants; the recorded H.264 weaves them into progressive frames. Otherwise 25p fallback is shown. This is not DV25.")
                    Text("Everything is captured locally. Saving requires Photos add-only access.")
                }
                .font(.system(size: 14))
                .foregroundStyle(ArchiveStyle.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            .background(ArchiveStyle.background.ignoresSafeArea())
            .navigationTitle("ABOUT THE SIMULATION")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showingInfo = false }
                        .foregroundStyle(ArchiveStyle.chalk)
                }
            }
        }
    }
}

import SwiftUI

struct CameraScreen: View {
    @StateObject private var camera = CaptureEngine()
    @State private var profile = CameraProfile.miniDV03
    @State private var mode: CaptureMode = .photo
    @State private var flash = false
    @State private var zoom: Double = 1.0
    @State private var showingDevices = false
    @State private var showingInfo = false

    var body: some View {
        GeometryReader { geo in
            Group {
                if geo.size.width > geo.size.height {
                    HStack(spacing: 18) {
                        finder
                        ScrollView {
                            VStack(spacing: 14) {
                                masthead
                                deviceSelector
                                controls
                                footer
                            }
                        }
                        .frame(width: min(280, geo.size.width * 0.38))
                    }
                } else {
                    VStack(spacing: 0) {
                        masthead
                        deviceSelector.padding(.top, 10)
                        Spacer(minLength: 12)
                        finder.frame(maxHeight: geo.size.height * 0.48)
                        Spacer(minLength: 13)
                        controls
                        footer.padding(.top, 10).padding(.bottom, 8)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 7)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(CameraBody().ignoresSafeArea())
        }
        .onAppear {
            camera.select(profile)
            camera.start()
        }
        .onDisappear { camera.stop() }
        .sheet(isPresented: $showingDevices) { deviceSheet }
        .sheet(isPresented: $showingInfo) { infoSheet }
    }

    private var finder: some View {
        viewfinder
            .aspectRatio(4.0 / 3.0, contentMode: .fit)
            .padding(6)
            .background(.black, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.linearGradient(
                colors: [.black, .white.opacity(0.29)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
            .accessibilityLabel("Simulated live camera preview")
            .onTapGesture { camera.refocus() }
    }

    private var masthead: some View {
        HStack(spacing: 10) {
            Text("ArchiveCam")
                .font(.system(size: 24, weight: .heavy).width(.condensed).italic())
                .tracking(-0.8)
            Spacer()
            Button { showingInfo = true } label: {
                Image(systemName: "info.circle")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Camera information")
        }
        .foregroundStyle(Color(white: 0.12))
        .padding(.horizontal, 13)
        .background(LinearGradient(colors: [
            Color(red: 0.82, green: 0.80, blue: 0.74), Color(white: 0.67),
            Color(red: 0.79, green: 0.78, blue: 0.73)
        ], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.white.opacity(0.4), lineWidth: 1).allowsHitTesting(false))
    }

    private var deviceSelector: some View {
        Button {
            if !camera.isRecording { showingDevices = true }
        } label: {
            HStack(spacing: 15) {
                Image(systemName: profile.family == .compact ? "camera" : "video")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .foregroundStyle(ArchiveStyle.signal)
                    .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
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
            .padding(.vertical, 9)
            .modifier(CameraGlass(shape: RoundedRectangle(cornerRadius: 13)))
        }
        .buttonStyle(.plain)
        .disabled(camera.isRecording)
        .accessibilityLabel("Choose historical camera profile")
    }

    private var viewfinder: some View {
        ZStack {
            Rectangle().fill(Color.black)
            if let renderer = camera.renderer {
                MetalPreview(renderer: renderer, store: camera.preview, orientationChanged: camera.orient)
                    .clipped()
            }
            Rectangle()
                .stroke(ArchiveStyle.chalk.opacity(0.24), lineWidth: 0.7)
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(profile.family == .camcorder ? "▸ DV" : "CCD")
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
                    Text("AF  ·  \(String(format: "%.1f", zoom))×")
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
    }

    private var controls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 3) {
                ForEach(CaptureMode.allCases, id: \.self) { option in
                    Button { mode = option } label: {
                        HStack(spacing: 7) {
                            Image(systemName: option == .photo ? "camera.fill" : "video.fill")
                            Text(option.rawValue)
                        }
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(mode == option ? ArchiveStyle.chalk : ArchiveStyle.muted)
                        .frame(maxWidth: .infinity, minHeight: 39)
                        .background {
                            if mode == option {
                                Color.clear.modifier(CameraGlass(shape: Capsule()))
                            }
                        }
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(camera.isRecording)
                    .accessibilityAddTraits(mode == option ? [.isSelected] : [])
                }
            }
            .padding(3)
            .background(.black.opacity(0.60), in: Capsule())

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
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        ForEach(0..<21, id: \.self) { mark in
                            Rectangle().fill(ArchiveStyle.muted.opacity(0.68))
                                .frame(width: 1, height: mark.isMultiple(of: 4) ? 5 : 2)
                            if mark < 20 { Spacer(minLength: 0) }
                        }
                    }
                    .padding(.horizontal, 12)
                    .accessibilityHidden(true)
                    Slider(value: $zoom, in: 1...6, step: 0.1)
                    .tint(ArchiveStyle.chalk)
                    .onChange(of: zoom) { _, value in camera.setZoom(value) }
                    .accessibilityLabel("Camera zoom")
                }
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
                    ShutterCap(video: mode == .video, recording: camera.isRecording)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!camera.isReady)
                .accessibilityLabel(mode == .photo ? "Take photograph" :
                                    (camera.isRecording ? "Stop video" : "Record video"))

                VStack(spacing: 8) {
                    Image(systemName: mode == .video ? "film.stack" : "photo")
                        .font(.system(size: 19, weight: .light))
                    Text(mode == .video ? "MONO / AAC" : "JPEG")
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
                Text("4:3")
            }
            .font(.system(size: 8, weight: .medium, design: .monospaced))
            .tracking(0.3)
            .foregroundStyle(ArchiveStyle.muted)
        }
    }

    private var deviceSheet: some View {
        NavigationStack {
            ScrollView {
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
                }
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
                    Text("ArchiveCam 0.5")
                        .font(.title2.bold())
                        .foregroundStyle(ArchiveStyle.chalk)
                    Text("Frame in 4:3. Tap the finder to refocus. Select the camera name to change the sensor, image size and microphone response.")
                    Text("MiniDV saves a frame from the finder when the flash is off. The video microphone softens highs, trims rumble and rounds loud sounds before recording in mono.")
                    Text("PAL pairs two fields when the camera supports 50 frames per second. Otherwise it records at 25p. Photos and videos are saved to Photos on this iPhone.")
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

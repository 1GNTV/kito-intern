import ImageIO
import PhotosUI
import SwiftUI

struct PhotoImportView: View {
    let renderer: RenderEngine
    let profile: CameraProfile
    let save: (Data, @escaping (Bool, String) -> Void) -> Void
    @State private var selection: PhotosPickerItem?
    @State private var source: Data?
    @State private var thumbnail: UIImage?
    @State private var anchor = StillFraming.importAnchor
    @State private var startAnchor: CGPoint?
    @State private var jpeg: Data?
    @State private var developed: UIImage?
    @State private var busy = false
    @State private var saved = false
    @State private var message = ""

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 16) {
                let width = max(1, min(geometry.size.width - 180, (geometry.size.height - 12) * 4 / 3))
                ZStack {
                    Color.black
                    if let developed {
                        Image(uiImage: developed).resizable()
                    } else if let thumbnail {
                        editor(thumbnail, width: width)
                    } else {
                        Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary)
                    }
                }
                .frame(width: width, height: width * 3 / 4)
                .clipped()
                VStack(spacing: 10) {
                    PhotosPicker(selection: $selection, matching: .images) {
                        Label("Choose photo", systemImage: "photo")
                    }
                    if let jpeg {
                        Button(saved ? "Saved" : "Save to Photos") {
                            busy = true
                            save(jpeg) { success, result in
                                saved = success
                                busy = false
                                message = success ? "" : result
                            }
                        }
                        .disabled(saved)
                        Button("Reframe") { self.jpeg = nil; developed = nil; message = "" }
                    } else if source != nil {
                        Text("Drag to frame in 4:3").font(.caption)
                        Button("Develop photo") { develop() }
                    }
                    if busy { ProgressView() }
                    if !message.isEmpty { Text(message).font(.caption).multilineTextAlignment(.center) }
                }
                .buttonStyle(.bordered).disabled(busy)
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(profile.name).navigationBarTitleDisplayMode(.inline)
        .task(id: selection) {
            guard let selection else { return }
            busy = true
            source = nil; thumbnail = nil; jpeg = nil; developed = nil; saved = false; message = ""
            do {
                let data = try await selection.loadTransferable(type: Data.self)
                guard !Task.isCancelled else { return }
                guard let data, let preview = Self.thumbnail(for: data) else {
                    busy = false; message = "Couldn’t open this image."; return
                }
                source = data; thumbnail = preview; anchor = StillFraming.importAnchor
            } catch {
                guard !Task.isCancelled else { return }
                message = error.localizedDescription
            }
            busy = false
        }
    }

    private func editor(_ image: UIImage, width: CGFloat) -> some View {
        let scale = max(width / image.size.width, width * 0.75 / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let extraX = max(0, size.width - width), extraY = max(0, size.height - width * 0.75)
        return Image(uiImage: image).resizable().frame(width: size.width, height: size.height)
            .offset(x: (0.5 - anchor.x) * extraX, y: (0.5 - anchor.y) * extraY)
            .frame(width: width, height: width * 0.75).clipped()
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1).onChanged { drag in
                let origin = startAnchor ?? anchor
                startAnchor = origin
                if extraX > 1 { anchor.x = min(1, max(0, origin.x - drag.translation.width / extraX)) }
                if extraY > 1 { anchor.y = min(1, max(0, origin.y - drag.translation.height / extraY)) }
            }.onEnded { _ in startAnchor = nil })
            .allowsHitTesting(!busy)
    }

    private static func thumbnail(for data: Data) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1000
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    private func develop() {
        guard let source else { return }
        let crop = anchor
        busy = true; saved = false; message = ""
        Task {
            let result = await Task.detached(priority: .userInitiated) { [renderer, profile] in
                renderer.processStill(source, profile: profile, cropAnchor: crop)
            }.value
            busy = false
            guard let result, let preview = Self.thumbnail(for: result) else {
                message = "Couldn’t develop this image."; return
            }
            jpeg = result; developed = preview
        }
    }
}

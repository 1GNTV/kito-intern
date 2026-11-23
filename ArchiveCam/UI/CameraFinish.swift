import SwiftUI

enum ArchiveStyle {
    static let background = Color(red: 0.08, green: 0.085, blue: 0.085)
    static let surface = Color(white: 0.14)
    static let line = Color(white: 0.32)
    static let chalk = Color(red: 0.96, green: 0.94, blue: 0.87)
    static let muted = Color(red: 0.72, green: 0.72, blue: 0.67)
    static let signal = Color(red: 0.93, green: 0.71, blue: 0.37)
    static let recording = Color(red: 0.94, green: 0.25, blue: 0.19)
}

// A stamped faceplate above a ribbed charcoal grip.
struct CameraBody: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.22), Color(white: 0.10), Color(white: 0.15)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Canvas { context, size in
                var grooves = Path()
                for y in stride(from: CGFloat.zero, through: size.height, by: 4) {
                    grooves.move(to: CGPoint(x: 0, y: y))
                    grooves.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(grooves, with: .color(.black.opacity(0.16)), lineWidth: 1)
            }
        }
        .accessibilityHidden(true)
    }
}

struct CameraGlass<S: Shape>: ViewModifier {
    let shape: S
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(ArchiveStyle.surface, in: shape)
                .overlay(shape.stroke(.white.opacity(0.35), lineWidth: 1).allowsHitTesting(false))
        } else if #available(iOS 26, *) {
            content.glassEffect(.regular.interactive(), in: shape)
        } else {
            content.background(.thinMaterial, in: shape)
                .overlay(shape.stroke(.white.opacity(0.24), lineWidth: 0.8).allowsHitTesting(false))
        }
    }
}

struct ShutterCap: View {
    let video: Bool
    let recording: Bool
    var body: some View {
        ZStack {
            Circle().fill(.linearGradient(colors: [.black, Color(white: 0.34), .black],
                                          startPoint: .topLeading, endPoint: .bottomTrailing))
            Circle().strokeBorder(ArchiveStyle.muted.opacity(0.65),
                                  style: StrokeStyle(lineWidth: 3, dash: [1, 3])).padding(3)
            Circle().fill(.linearGradient(colors: [Color(white: 0.82), Color(white: 0.40), Color(white: 0.67)],
                                          startPoint: .topLeading, endPoint: .bottomTrailing)).padding(8)
            Circle().strokeBorder(.black.opacity(0.58), lineWidth: 1).padding(9)
            if video {
                RoundedRectangle(cornerRadius: recording ? 3 : 14)
                    .fill(ArchiveStyle.recording).frame(width: recording ? 19 : 26, height: recording ? 19 : 26)
            } else {
                Circle().strokeBorder(.black.opacity(0.16), lineWidth: 1).padding(15)
            }
        }
        .frame(width: 76, height: 76)
        .shadow(color: .black.opacity(0.55), radius: 3, y: 3)
        .accessibilityHidden(true)
    }
}

struct ShutterPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .offset(y: configuration.isPressed ? 2 : 0)
            .brightness(configuration.isPressed ? -0.05 : 0)
    }
}

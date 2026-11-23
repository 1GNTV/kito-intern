import MetalKit
import SwiftUI

// The window scene supplies the actual interface orientation, including when
// the user holds the phone upright under the iOS rotation lock.
final class FinderView: MTKView {
    var orientationChanged: ((UIInterfaceOrientation) -> Void)?
    private var lastOrientation: UIInterfaceOrientation = .unknown

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let angle = window?.windowScene?.interfaceOrientation,
              angle != .unknown, angle != lastOrientation else { return }
        lastOrientation = angle
        orientationChanged?(angle)
    }
}

struct MetalPreview: UIViewRepresentable {
    let renderer: RenderEngine
    let store: PreviewStore

    let orientationChanged: (UIInterfaceOrientation) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(renderer: renderer, store: store)
    }

    func makeUIView(context: Context) -> MTKView {
        let view = FinderView(frame: .zero, device: renderer.device)
        view.orientationChanged = orientationChanged
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0.018, 0.020, 0.022, 1)
        view.framebufferOnly = true
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 60
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {}

    final class Coordinator: NSObject, MTKViewDelegate {
        private let renderer: RenderEngine
        private let store: PreviewStore

        init(renderer: RenderEngine, store: PreviewStore) {
            self.renderer = renderer
            self.store = store
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let frame = store.current(),
                  let texture = frame.texture,
                  let pass = view.currentRenderPassDescriptor,
                  let drawable = view.currentDrawable,
                  let command = renderer.queue.makeCommandBuffer(),
                  let encoder = command.makeRenderCommandEncoder(descriptor: pass)
            else { return }

            encoder.setRenderPipelineState(renderer.screenPipeline)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            encoder.endEncoding()
            // Retain CVMetalTexture and its pixel buffer until the GPU is done sampling.
            command.addCompletedHandler { _ in
                withExtendedLifetime(frame) {}
            }
            command.present(drawable)
            command.commit()
        }
    }
}

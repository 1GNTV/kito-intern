import AVFoundation
import CoreImage
import CoreVideo
import ImageIO
import Metal
import MetalKit
import UIKit

struct SimulatedFrame {
    let pixelBuffer: CVPixelBuffer
    let metalTexture: CVMetalTexture

    var texture: MTLTexture? { CVMetalTextureGetTexture(metalTexture) }
}

final class PreviewStore {
    private let lock = NSLock()
    private var lastFrame: SimulatedFrame?

    func publish(_ frame: SimulatedFrame) {
        lock.lock()
        lastFrame = frame
        lock.unlock()
    }

    func clear() {
        lock.lock()
        lastFrame = nil
        lock.unlock()
    }

    func current() -> SimulatedFrame? {
        lock.lock()
        defer { lock.unlock() }
        return lastFrame
    }
}

final class RenderEngine {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let screenPipeline: MTLRenderPipelineState
    let ciContext: CIContext
    private let filterPipeline: MTLComputePipelineState
    private let meterPipeline: MTLComputePipelineState
    private var textureCache: CVMetalTextureCache?

    init?() {
        guard let gpu = MTLCreateSystemDefaultDevice(),
              let queue = gpu.makeCommandQueue(),
              let library = gpu.makeDefaultLibrary(),
              let computeFunction = library.makeFunction(name: "retroKernel"),
              let vertex = library.makeFunction(name: "fullscreenVertex"),
              let fragment = library.makeFunction(name: "fullscreenFragment"),
              let meterFunction = library.makeFunction(name: "compactMeter"),
              let meter = try? gpu.makeComputePipelineState(function: meterFunction),
              let compute = try? gpu.makeComputePipelineState(function: computeFunction) else {
            return nil
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let screen = try? gpu.makeRenderPipelineState(descriptor: descriptor) else {
            return nil
        }

        self.device = gpu
        self.queue = queue
        self.screenPipeline = screen
        self.filterPipeline = compute
        self.meterPipeline = meter
        self.ciContext = CIContext(mtlDevice: gpu, options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])

        var cache: CVMetalTextureCache?
        let result = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, gpu, nil, &cache)
        guard result == kCVReturnSuccess, cache != nil else { return nil }
        self.textureCache = cache
    }

    func makePixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let properties: [String: Any] = [
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferCGImageCompatibilityKey as String: true
        ]
        let result = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA,
            properties as CFDictionary, &buffer
        )
        return result == kCVReturnSuccess ? buffer : nil
    }

    private func texture(for pixelBuffer: CVPixelBuffer) -> CVMetalTexture? {
        guard let cache = textureCache else { return nil }
        var reference: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil,
            .bgra8Unorm,
            CVPixelBufferGetWidth(pixelBuffer),
            CVPixelBufferGetHeight(pixelBuffer), 0, &reference
        )
        return result == kCVReturnSuccess ? reference : nil
    }

    func render(
        first: CVPixelBuffer,
        second: CVPixelBuffer?,
        output: CVPixelBuffer,
        profile: CameraProfile,
        time: CMTime,
        gain: Float = 1
    ) -> SimulatedFrame? {
        guard let inputRef = texture(for: first),
              let firstTexture = CVMetalTextureGetTexture(inputRef),
              let outputRef = texture(for: output),
              let outputTexture = CVMetalTextureGetTexture(outputRef) else { return nil }
        let secondRef = second.flatMap { texture(for: $0) }
        let secondTexture = secondRef.flatMap { CVMetalTextureGetTexture($0) } ?? firstTexture

        var uniforms = profile.recipe
        uniforms.sensor.x = Float(CVPixelBufferGetWidth(output))
        uniforms.sensor.y = Float(CVPixelBufferGetHeight(output))
        let seconds = CMTimeGetSeconds(time)
        uniforms.timing = SIMD4(
            seconds.isFinite ? Float(Int(seconds * 1000) % 65536) : 0,
            min(max(gain, 1), 16),
            second != nil && profile.prefersTemporalFields ? 1 : 0,
            profile.family == .camcorder ? 1 : 0)
        guard let command = queue.makeCommandBuffer() else { return nil }
        var meter: MTLBuffer?
        if profile.id == CameraProfile.ccd3MP.id {
            guard let buffer = CompactMeter.encode(input: firstTexture, command: command,
                                                  pipeline: meterPipeline) else { return nil }
            meter = buffer
        }
        guard let encoder = command.makeComputeCommandEncoder() else { return nil }
        CompactMeter.bind(meter, to: encoder)
        encoder.setComputePipelineState(filterPipeline)
        encoder.setTexture(firstTexture, index: 0)
        encoder.setTexture(secondTexture, index: 1)
        encoder.setTexture(outputTexture, index: 2)
        encoder.setBytes(&uniforms, length: MemoryLayout<ImagingRecipe>.stride, index: 0)
        encoder.dispatchThreadgroups(
            MTLSize(width: (outputTexture.width + 7) / 8, height: (outputTexture.height + 7) / 8, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1)
        )
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { return nil }
        return SimulatedFrame(pixelBuffer: output, metalTexture: outputRef)
    }

    func processStill(_ data: Data, profile: CameraProfile, gain: Float = 1,
                      cropAnchor: CGPoint? = nil) -> Data? {
        guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
            return nil
        }
        let bounds = image.extent.integral
        let extent = cropAnchor.map { anchor in
            let topDown = StillFraming.rect(in: bounds.size, anchor: anchor)
            return CGRect(x: bounds.minX + topDown.minX, y: bounds.maxY - topDown.maxY,
                          width: topDown.width, height: topDown.height)
        } ?? bounds
        let width = Int(extent.width)
        let height = Int(extent.height)
        guard width > 0, height > 0,
              let source = makePixelBuffer(width: width, height: height),
              let destination = makePixelBuffer(width: profile.photoWidth, height: profile.photoHeight) else {
            return nil
        }
        let shifted = image.cropped(to: extent).transformed(
            by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
        )
        ciContext.render(
            shifted, to: source,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
        )
        guard let result = render(
            first: source, second: nil, output: destination,
            profile: profile, time: .zero, gain: gain
        ) else { return nil }
        return jpeg(result.pixelBuffer, quality: profile.jpegQuality)
    }

    func jpeg(_ buffer: CVPixelBuffer, quality: CGFloat) -> Data? {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let image = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: space])
        return ciContext.jpegRepresentation(of: image, colorSpace: space,
                                           options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality])
    }
}

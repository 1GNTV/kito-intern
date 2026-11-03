import AVFoundation
import CoreImage
import CoreVideo
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

    func current() -> SimulatedFrame? {
        lock.lock()
        defer { lock.unlock() }
        return lastFrame
    }
}

struct FilterParameters {
    var saturation: Float
    var contrast: Float
    var warmth: Float
    var sensorNoise: Float
    var opticalSoftness: Float
    var highlightBloom: Float
    var chromaMisregistration: Float
    var cornerFalloff: Float
    var timeSeconds: Float
    var seed: Float
    var useTemporalFields: UInt32
    var reserved: UInt32 = 0

    init(profile: CameraProfile, time: CMTime, fields: Bool) {
        saturation = profile.saturation
        contrast = profile.contrast
        warmth = profile.warmth
        sensorNoise = profile.sensorNoise
        opticalSoftness = profile.opticalSoftness
        highlightBloom = profile.highlightBloom
        chromaMisregistration = profile.chromaMisregistration
        cornerFalloff = profile.cornerFalloff
        let seconds = CMTimeGetSeconds(time)
        timeSeconds = seconds.isFinite ? Float(seconds.truncatingRemainder(dividingBy: 10_000)) : 0
        seed = Float.random(in: 0...1024)
        useTemporalFields = fields ? 1 : 0
    }
}

final class RenderEngine {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let screenPipeline: MTLRenderPipelineState
    let ciContext: CIContext
    private let filterPipeline: MTLComputePipelineState
    private var textureCache: CVMetalTextureCache?

    init?() {
        guard let gpu = MTLCreateSystemDefaultDevice(),
              let queue = gpu.makeCommandQueue(),
              let library = gpu.makeDefaultLibrary(),
              let computeFunction = library.makeFunction(name: "retroKernel"),
              let vertex = library.makeFunction(name: "fullscreenVertex"),
              let fragment = library.makeFunction(name: "fullscreenFragment"),
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
        self.ciContext = CIContext(mtlDevice: gpu)

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
        time: CMTime
    ) -> SimulatedFrame? {
        guard let inputRef = texture(for: first),
              let firstTexture = CVMetalTextureGetTexture(inputRef),
              let outputRef = texture(for: output),
              let outputTexture = CVMetalTextureGetTexture(outputRef) else { return nil }
        let secondRef = second.flatMap { texture(for: $0) }
        let secondTexture = secondRef.flatMap { CVMetalTextureGetTexture($0) } ?? firstTexture

        var uniforms = FilterParameters(
            profile: profile, time: time,
            fields: second != nil && profile.prefersTemporalFields
        )
        guard let command = queue.makeCommandBuffer(),
              let encoder = command.makeComputeCommandEncoder() else { return nil }
        encoder.setComputePipelineState(filterPipeline)
        encoder.setTexture(firstTexture, index: 0)
        encoder.setTexture(secondTexture, index: 1)
        encoder.setTexture(outputTexture, index: 2)
        encoder.setBytes(&uniforms, length: MemoryLayout<FilterParameters>.stride, index: 0)
        let w = filterPipeline.threadExecutionWidth
        let h = max(1, filterPipeline.maxTotalThreadsPerThreadgroup / w)
        encoder.dispatchThreads(
            MTLSize(width: outputTexture.width, height: outputTexture.height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1)
        )
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { return nil }
        return SimulatedFrame(pixelBuffer: output, metalTexture: outputRef)
    }

    func processStill(_ data: Data, profile: CameraProfile) -> Data? {
        guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
            return nil
        }
        let extent = image.extent.integral
        let width = Int(extent.width)
        let height = Int(extent.height)
        guard width > 0, height > 0,
              let source = makePixelBuffer(width: width, height: height),
              let destination = makePixelBuffer(width: profile.photoWidth, height: profile.photoHeight) else {
            return nil
        }
        let shifted = image.transformed(
            by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
        )
        ciContext.render(
            shifted, to: source,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        guard let result = render(
            first: source, second: nil, output: destination,
            profile: profile, time: .zero
        ) else { return nil }
        let outputImage = CIImage(cvPixelBuffer: result.pixelBuffer)
        guard let cg = ciContext.createCGImage(
            outputImage,
            from: CGRect(x: 0, y: 0, width: profile.photoWidth, height: profile.photoHeight)
        ) else { return nil }
        return UIImage(cgImage: cg).jpegData(compressionQuality: profile.jpegQuality)
    }
}

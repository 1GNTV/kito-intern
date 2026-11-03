import Foundation
import Metal

@main
struct RenderChecks {
    static func main() throws {
        precondition(MemoryLayout<ImagingRecipe>.stride == 128)
        precondition(CameraProfile.all.count == 3)
        precondition(CameraProfile.compact02.videoFPS == 15)
        precondition(CameraProfile.compact02.videoWidth == 240)
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("GPU runtime tests SKIPPED: runner exposes no Metal device")
            return
        }
        let library = try device.makeLibrary(URL: URL(fileURLWithPath: "/tmp/archivecam-test.metallib"))
        let pipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "retroKernel")!)
        let queue = device.makeCommandQueue()!
        let width = 240, height = 320
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        desc.storageMode = .shared
        desc.usage = [.shaderRead, .shaderWrite]
        let input = device.makeTexture(descriptor: desc)!
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y*width+x)*4
                pixels[i] = UInt8(x*255/width)
                pixels[i+1] = UInt8(y*255/height)
                pixels[i+2] = UInt8((x/8 % 2)*160+40)
            }
        }
        pixels.withUnsafeBytes {
            input.replace(region: MTLRegionMake2D(0,0,width,height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width*4)
        }
        func run(_ profile: CameraProfile, gain: Float) throws -> [UInt8] {
            let output = device.makeTexture(descriptor: desc)!
            var recipe = profile.recipe
            recipe.sensor.x = Float(width)
            recipe.sensor.y = Float(height)
            recipe.timing = SIMD4(42,gain,0,0)
            let command = queue.makeCommandBuffer()!
            let encoder = command.makeComputeCommandEncoder()!
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(input,index:0)
            encoder.setTexture(input,index:1)
            encoder.setTexture(output,index:2)
            encoder.setBytes(&recipe,length:128,index:0)
            encoder.dispatchThreads(MTLSize(width:width,height:height,depth:1), threadsPerThreadgroup:MTLSize(width:8,height:8,depth:1))
            encoder.endEncoding()
            command.commit()
            command.waitUntilCompleted()
            if let error = command.error { throw error }
            precondition(command.status == .completed)
            var bytes = [UInt8](repeating:0,count:width*height*4)
            bytes.withUnsafeMutableBytes { output.getBytes($0.baseAddress!,bytesPerRow:width*4,from:MTLRegionMake2D(0,0,width,height),mipmapLevel:0) }
            return bytes
        }
        let start = Date()
        let pocket = try run(.compact02,gain:1)
        let compact = try run(.compact04,gain:1)
        let dv = try run(.miniDV03,gain:1)
        let noisy = try run(.compact02,gain:9)
        func distance(_ a:[UInt8],_ b:[UInt8]) -> Double {
            var sum = 0.0
            for i in a.indices where i % 4 != 3 { sum += abs(Double(a[i])-Double(b[i])) }
            return sum/Double(width*height*3)
        }
        precondition(distance(pocket,compact)>2)
        precondition(distance(pocket,dv)>2)
        precondition(distance(pocket,noisy)>1)
        precondition(pocket.enumerated().allSatisfy { $0.offset % 4 != 3 || $0.element == 255 })
        print("GPU tests passed; pocket/compact MAE \(distance(pocket,compact)), pocket/DV MAE \(distance(pocket,dv)); four renders wall ms \(Date().timeIntervalSince(start)*1000)")
        for _ in 0..<10 { _ = try run(.compact02,gain:1) }
        print("Synthetic GPU workload complete. Not an iPhone realtime performance measurement.")
    }
}

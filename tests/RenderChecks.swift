import Foundation
import Metal

@main
struct RenderChecks {
    static func main() throws {
        precondition(MemoryLayout<ImagingRecipe>.stride == 128)
        precondition(CameraProfile.all.count == 4)
        precondition(CameraProfile.startup.family == .compact && CameraProfile.startup.photoWidth == 2048)
        precondition(CameraProfile.compact02.videoFPS == 15)
        for p in CameraProfile.all {
            precondition(p.photoWidth * 3 == p.photoHeight * 4)
            precondition(p.videoWidth * 3 == p.videoHeight * 4)
        }
        precondition(CameraProfile.miniDV03.photoWidth == 768 && CameraProfile.miniDV03.photoHeight == 576)
        precondition(CameraProfile.compact02.videoWidth == 320)
        let portraitSize = CGSize(width: 1536, height: 2048)
        precondition(StillFraming.rect(in: portraitSize, anchor: StillFraming.importAnchor)
                     == CGRect(x: 0, y: 224, width: 1536, height: 1152))
        precondition(StillFraming.rect(in: portraitSize, anchor: CGPoint(x: 1, y: 1)).maxY == 2048)
        precondition(StillFraming.rect(in: CGSize(width: 2000, height: 1200),
                                      anchor: .zero).size == CGSize(width: 1600, height: 1200))
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("GPU runtime tests SKIPPED: runner exposes no Metal device")
            return
        }
        let library = try device.makeLibrary(URL: URL(fileURLWithPath: "/tmp/archivecam-test.metallib"))
        let pipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "retroKernel")!)
        let meterPipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "compactMeter")!)
        let queue = device.makeCommandQueue()!
        let width = 320, height = 240
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
        func run(_ profile: CameraProfile, gain: Float, source: MTLTexture? = nil, aperture: Bool = true, quantisation: Float? = nil, metering: Bool = true) throws -> [UInt8] {
            let output = device.makeTexture(descriptor: desc)!
            var recipe = profile.recipe
            if !aperture { recipe.optics.y = 0 }
            if let quantisation { recipe.red.w = quantisation }
            recipe.sensor.x = Float(width)
            recipe.sensor.y = Float(height)
            recipe.timing = SIMD4(42,gain,0,profile.family == .camcorder ? 1 : 0)
            let command = queue.makeCommandBuffer()!
            var meter: MTLBuffer?
            if metering && profile.id == CameraProfile.ccd3MP.id {
                meter = CompactMeter.encode(input: source ?? input, command: command, pipeline: meterPipeline)
                precondition(meter != nil)
            }
            let encoder = command.makeComputeCommandEncoder()!
            CompactMeter.bind(meter, to: encoder)
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(source ?? input,index:0)
            encoder.setTexture(source ?? input,index:1)
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
        let portraitDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 320, height: 480, mipmapped: false)
        portraitDesc.storageMode = .shared
        let portrait = device.makeTexture(descriptor: portraitDesc)!
        var chart = [UInt8](repeating: 255, count: 320*480*4)
        for y in 0..<480 {
            for x in 0..<320 {
                let value: UInt8 = (120..<360).contains(y) ? (x < 160 ? 65 : 165) : 255
                let i = (320*y+x)*4
                for c in 0..<3 { chart[i+c] = value }
            }
        }
        chart.withUnsafeBytes {
            portrait.replace(region: MTLRegionMake2D(0,0,320,480), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 320*4)
        }
        let cropped = try run(.miniDV03, gain: 1, source: portrait)
        for y in [8,120,231] {
            let left = Int(cropped[(y*width+80)*4])
            let right = Int(cropped[(y*width+240)*4])
            precondition(left < 120 && right > left+60 && right < 240, "portrait crop, scale or orientation")
        }
        let uncorrected = try run(.miniDV03, gain: 1, source: portrait, aperture: false)
        func stepContrast(_ image: [UInt8]) -> Double {
            let total = (16..<224).reduce(0) { sum, row in
                let offset = (row * width + 159) * 4
                return sum + Int(image[offset+4]) - Int(image[offset])
            }
            return Double(total) / 208
        }
        precondition(stepContrast(cropped) > stepContrast(uncorrected) + 6,
                     "the SD luma contour must retain an edge across the chroma footprint")
        // Bright buildings and shaded foliage should separate in daylight. Cb/Cr
        // remain near zero on a grey target. Compare the same quantiser and seed.
        let measured = try run(.startup, gain: 1, source: portrait)
        let unmetered = try run(.startup, gain: 1, source: portrait, metering: false)
        func mean(_ image: [UInt8], x: Int, channel: Int = 0) -> Double {
            var sum = 0
            for row in 80..<160 {
                for col in x..<(x+32) { sum += Int(image[(row*width+col)*4+channel]) }
            }
            return Double(sum) / (80*32)
        }
        precondition(mean(measured, x: 40) < mean(unmetered, x: 40) - 1)
        precondition(mean(measured, x: 200) > mean(unmetered, x: 200) + 3)
        precondition(abs(mean(measured, x: 200) - mean(measured, x: 200, channel: 2)) < 2)
        // A grey reference must remain neutral while a blue sky and a warm lamp
        // remain distinct. Average patches to exclude the simulated sensor noise.
        let patches: [[UInt8]] = [[140,140,140], [55,85,220], [215,140,60]]
        for y in 0..<480 {
            for x in 0..<320 {
                let colour = patches[min(2, x / 107)]
                for c in 0..<3 { chart[(y*320+x)*4+c] = colour[c] }
            }
        }
        chart.withUnsafeBytes {
            portrait.replace(region: MTLRegionMake2D(0,0,320,480), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 320*4)
        }
        let colours = try run(.miniDV03, gain: 1, source: portrait)
        func patch(_ x: Int, _ c: Int) -> Int {
            var sum = 0
            for row in 90..<110 {
                for col in x..<(x+20) { sum += Int(colours[(row*width+col)*4+c]) }
            }
            return sum / 400
        }
        precondition(abs(patch(40,0)-patch(40,2)) < 3 && abs(patch(40,1)-patch(40,2)) < 3)
        precondition(patch(145,2) > patch(145,1)+70 && patch(250,0) > patch(250,2)+80)
        // A gentle gradient should show stronger jumps at codec boundaries
        // than inside blocks. Turning quantisation down removes the steps.
        for y in 0..<height {
            for x in 0..<width {
                let grey = UInt8(75 + x / 3)
                for c in 0..<3 { pixels[(y*width+x)*4+c] = grey }
            }
        }
        pixels.withUnsafeBytes {
            input.replace(region: MTLRegionMake2D(0,0,width,height), mipmapLevel: 0,
                          withBytes: $0.baseAddress!, bytesPerRow: width*4)
        }
        func blockContrast(_ data: [UInt8]) -> Double {
            var border = 0, interior = 0
            for y in 32..<208 {
                for x in stride(from: 32, through: 280, by: 8) {
                    let i = (width*y+x)*4
                    border += abs(Int(data[i])-Int(data[i-4]))
                    interior += abs(Int(data[i+16])-Int(data[i+12]))
                }
            }
            return Double(border - interior) / Double(176*32)
        }
        let compressed = try run(.miniDV03, gain: 1)
        let fine = try run(.miniDV03, gain: 1, quantisation: 0.005)
        precondition(blockContrast(compressed) > blockContrast(fine) + 1)
        let compactGradient = try run(.startup, gain: 1)
        precondition(blockContrast(compactGradient) < blockContrast(compressed))
        print("GPU tests passed; pocket/compact MAE \(distance(pocket,compact)), pocket/DV MAE \(distance(pocket,dv)); four renders wall ms \(Date().timeIntervalSince(start)*1000)")
        for _ in 0..<10 { _ = try run(.compact02,gain:1) }
        print("Synthetic GPU workload complete. Not an iPhone realtime performance measurement.")
    }
}

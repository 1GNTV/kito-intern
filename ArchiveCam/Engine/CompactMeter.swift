import Metal

enum CompactMeter {
    static func encode(input: MTLTexture, command: MTLCommandBuffer,
                       pipeline: MTLComputePipelineState) -> MTLBuffer? {
        guard let meter = input.device.makeBuffer(length: MemoryLayout<SIMD2<Float>>.stride,
                                                  options: .storageModePrivate),
              let encoder = command.makeComputeCommandEncoder() else { return nil }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(input, index: 0)
        encoder.setBuffer(meter, offset: 0, index: 0)
        encoder.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        encoder.endEncoding()
        return meter
    }

    static func bind(_ meter: MTLBuffer?, to encoder: MTLComputeCommandEncoder) {
        if let meter {
            encoder.setBuffer(meter, offset: 0, index: 1)
        } else {
            var zero = SIMD2<Float>.zero
            encoder.setBytes(&zero, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        }
    }
}

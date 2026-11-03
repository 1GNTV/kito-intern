import Foundation

/// Eight aligned float4 vectors, mirrored exactly in LegacyCamera.metal.
struct ImagingRecipe {
    var sensor: SIMD4<Float>   // native sampling width/height, luminance/chroma noise
    var optics: SIMD4<Float>   // softness, aperture correction, lateral CA, falloff
    var tone: SIMD4<Float>     // black pedestal, exposure scale, gamma, clipping threshold
    var red: SIMD4<Float>
    var green: SIMD4<Float>
    var blue: SIMD4<Float>
    var encoding: SIMD4<Float> // chroma block width/height, quantisation levels, highlight spread
    var timing: SIMD4<Float>   // deterministic noise seed, gain, field flag, reserved
}

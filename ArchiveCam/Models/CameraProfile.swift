import Foundation
import CoreGraphics

enum CaptureMode: String, CaseIterable {
    case photo = "PHOTO"
    case video = "VIDEO"
}

struct CameraProfile: Identifiable, Equatable {
    enum Family: String {
        case compact = "DIGITAL STILL"
        case camcorder = "DIGITAL VIDEO"
    }

    let id: String
    let name: String
    let era: String
    let family: Family
    let descriptor: String
    let photoWidth: Int
    let photoHeight: Int
    let videoWidth: Int
    let videoHeight: Int
    var videoFPS: Int
    var prefersTemporalFields: Bool
    let jpegQuality: CGFloat

    // Experimental coefficients, intentionally NOT represented as measured calibration.
    let saturation: Float
    let contrast: Float
    let warmth: Float
    let sensorNoise: Float
    let opticalSoftness: Float
    let highlightBloom: Float
    let chromaMisregistration: Float
    let cornerFalloff: Float

    static let compact04 = CameraProfile(
        id: "compact04",
        name: "COMPACT 04",
        era: "2004 / CCD",
        family: .compact,
        descriptor: "5 MP CCD-era compact / experimental optical and JPEG response",
        photoWidth: 1944, photoHeight: 2592,
        videoWidth: 480, videoHeight: 640,
        videoFPS: 15,
        prefersTemporalFields: false,
        jpegQuality: 0.77,
        saturation: 1.06, contrast: 1.09, warmth: 0.015,
        sensorNoise: 0.014, opticalSoftness: 0.26,
        highlightBloom: 0.12, chromaMisregistration: 0.32, cornerFalloff: 0.14
    )

    static let miniDV03 = CameraProfile(
        id: "minidv03",
        name: "MINIDV 03",
        era: "2003 / PAL",
        family: .camcorder,
        descriptor: "PAL 50-field/s sampling when supported / square-pixel 4:3 output",
        photoWidth: 576, photoHeight: 768,
        videoWidth: 576, videoHeight: 768,
        videoFPS: 25,
        prefersTemporalFields: true,
        jpegQuality: 0.84,
        saturation: 0.92, contrast: 1.12, warmth: -0.013,
        sensorNoise: 0.023, opticalSoftness: 0.45,
        highlightBloom: 0.21, chromaMisregistration: 0.48, cornerFalloff: 0.08
    )

    // Artist-tuned starting points; optical/sensor coefficients are unmeasured.
    static let compact02 = CameraProfile(
        id: "compact02", name: "POCKET CCD 02", era: "2002 / 2 MP",
        family: .compact,
        descriptor: "2 MP JPEG / QVGA 15p / coarse colour, clipped highlights, compact optics",
        photoWidth: 1200, photoHeight: 1600,
        videoWidth: 240, videoHeight: 320, videoFPS: 15,
        prefersTemporalFields: false, jpegQuality: 0.61,
        saturation: 1.18, contrast: 1.22, warmth: 0.018,
        sensorNoise: 0.030, opticalSoftness: 0.7,
        highlightBloom: 0.22, chromaMisregistration: 0.45, cornerFalloff: 0.12
    )

    var recipe: ImagingRecipe {
        if id == "compact02" {
            return ImagingRecipe(
                sensor: SIMD4(0, 0, 0.022, 0.024),
                optics: SIMD4(0.65, 0.48, 0.6, 0.11),
                tone: SIMD4(0.035, 1.22, 0.94, 0.88),
                red: SIMD4(1.13, -0.09, -0.04, 0),
                green: SIMD4(-0.04, 1.08, -0.04, 0),
                blue: SIMD4(-0.035, -0.105, 1.14, 0),
                encoding: SIMD4(2, 2, 112, 0.16),
                timing: .zero)
        } else if family == .compact {
            return ImagingRecipe(
                sensor: SIMD4(0, 0, 0.012, 0.013),
                optics: SIMD4(0.32, 0.70, 0.25, 0.06),
                tone: SIMD4(0.020, 1.13, 1.02, 0.95),
                red: SIMD4(1.07, -0.05, -0.02, 0),
                green: SIMD4(-0.025, 1.05, -0.025, 0),
                blue: SIMD4(-0.025, -0.04, 1.065, 0),
                encoding: SIMD4(2, 2, 192, 0.07),
                timing: .zero)
        }
        return ImagingRecipe(
            sensor: SIMD4(0, 0, 0.025, 0.034),
            optics: SIMD4(0.85, 0.18, 0.20, 0.025),
            tone: SIMD4(0.055, 1.08, 0.88, 0.92),
            red: SIMD4(0.92, 0.06, 0.02, 0),
            green: SIMD4(0.02, 0.97, 0.01, 0),
            blue: SIMD4(0.02, 0.055, 0.925, 0),
            encoding: SIMD4(2, 2, 160, 0.23),
            timing: .zero)
    }

    static let all: [CameraProfile] = [.compact02, .compact04, .miniDV03]
}

import Foundation

enum StillFraming {
    static let importAnchor = CGPoint(x: 0.5, y: 0.25)

    /// Pixel-aligned, top-left coordinates shared by the editor and the renderer.
    static func rect(in size: CGSize, anchor: CGPoint) -> CGRect {
        let width = min(size.width, (size.height * 4 / 3).rounded())
        let height = min(size.height, (size.width * 3 / 4).rounded())
        let x = ((size.width - width) * min(1, max(0, anchor.x))).rounded()
        let y = ((size.height - height) * min(1, max(0, anchor.y))).rounded()
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

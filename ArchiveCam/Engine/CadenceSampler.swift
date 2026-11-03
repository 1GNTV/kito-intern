import Foundation

/// Selects distinct presentation slots without altering capture timestamps.
/// A slow source can skip slots; it cannot manufacture missing sensor frames.
struct CadenceSampler {
    private var lastIndex = -1

    mutating func reset() { lastIndex = -1 }

    mutating func accept(elapsed: Double, fps: Int) -> Bool {
        guard elapsed.isFinite, elapsed >= 0, fps > 0 else { return false }
        let scaled = elapsed * Double(fps) + 0.001
        guard scaled < Double(Int.max) else { return false }
        let index = Int(scaled)
        guard index > lastIndex else { return false }
        lastIndex = index
        return true
    }
}

import Foundation

@main
struct CadenceChecks {
    static func main() {
        for fps in [15, 20, 25] {
            var sampler = CadenceSampler()
            let accepted = (0...300).filter { sampler.accept(elapsed: Double($0) / 30, fps: fps) }
            precondition(accepted.count == fps * 10 + 1)
            precondition(!sampler.accept(elapsed: 1, fps: fps))
            sampler.reset()
            precondition(sampler.accept(elapsed: 0, fps: fps))
            precondition(!sampler.accept(elapsed: 0, fps: fps))
            precondition(!sampler.accept(elapsed: .nan, fps: fps))
            precondition(!sampler.accept(elapsed: 1, fps: 0))
        }
        print("Cadence slot tests passed")
    }
}

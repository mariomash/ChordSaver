import Foundation

struct RecordingTake: Identifiable, Hashable {
    let id: UUID
    let chordId: String
    let displayName: String
    let takeIndex: Int
    let fileURL: URL
    let duration: TimeInterval
    /// Sample peak linear 0...1 (max abs across channels).
    let peakLinear: Float
    /// Simple RMS linear 0...1 for last segment or whole file.
    let rmsLinear: Float
    /// Downsampled min/max pairs for silhouette (flattened: min0,max0,min1,max1,...).
    let waveformEnvelope: [Float]

    var peakDBFS: Float {
        guard peakLinear > 0 else { return -96 }
        return 20 * log10(peakLinear)
    }
}

/// Per-chord take counter for export naming and session bookkeeping.
struct TakeIndexBook {
    private var next: [String: Int] = [:]

    mutating func registerTake(chordId: String) -> Int {
        let n = (next[chordId] ?? 0) + 1
        next[chordId] = n
        return n
    }

    func currentIndex(for chordId: String) -> Int {
        next[chordId] ?? 0
    }
}

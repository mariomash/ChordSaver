import Foundation

struct RecordingTake: Identifiable, Hashable {
    let id: UUID
    let chordId: String
    let displayName: String
    let takeIndex: Int
    /// First saved capture on disk; unchanged when saving trimmed copies.
    let originalFileURL: URL
    /// Active audio file (trimmed copy after trim, else same as `originalFileURL`).
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

/// Per-visible-chord take counter for export naming and session bookkeeping.
struct TakeIndexBook {
    private var next: [String: Int] = [:]

    mutating func registerTake(displayName: String) -> Int {
        let key = normalizedKey(for: displayName)
        let n = (next[key] ?? 0) + 1
        next[key] = n
        return n
    }

    func currentIndex(for displayName: String) -> Int {
        next[normalizedKey(for: displayName)] ?? 0
    }

    /// Seeds counters from takes already on disk so new recordings continue after `takeIndex`.
    mutating func seedFromExistingTakes(_ takes: [RecordingTake]) {
        for t in takes {
            let key = normalizedKey(for: t.displayName)
            next[key] = max(next[key] ?? 0, t.takeIndex)
        }
    }

    private func normalizedKey(for displayName: String) -> String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Chord" : trimmed
    }
}

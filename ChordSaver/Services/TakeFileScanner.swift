import AVFoundation
import Foundation

/// Discovers `SanitizedDisplayName_takeNN.wav` files in a workspace folder and maps them to bundled chords.
enum TakeFileScanner {
    /// Parses `Stem_takeNN` from a filename **without** the `.wav` extension.
    static func parseStemAndTakeIndex(filenameStem: String) -> (sanitizedStem: String, takeIndex: Int)? {
        let marker = "_take"
        guard let range = filenameStem.range(of: marker, options: .backwards) else { return nil }
        let sanitized = String(filenameStem[..<range.lowerBound])
        let numPart = String(filenameStem[range.upperBound...])
        guard let n = Int(numPart), n >= 1, !sanitized.isEmpty else { return nil }
        return (sanitized, n)
    }

    static func chord(forSanitizedStem stem: String, in chords: [Chord]) -> Chord? {
        for c in chords where FilenameSanitizer.sanitizeChordName(c.displayName) == stem {
            return c
        }
        return nil
    }

    private static func quickDurationSeconds(url: URL) -> TimeInterval {
        guard let f = try? AVAudioFile(forReading: url) else { return 0 }
        let fr = f.length
        let sr = f.processingFormat.sampleRate
        guard fr > 0, sr > 0 else { return 0 }
        return Double(fr) / sr
    }

    /// Top-level `.wav` files only; sorted by chord list order then take index.
    static func scan(directory: URL, chords: [Chord]) -> [RecordingTake] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let chordOrder = Dictionary(uniqueKeysWithValues: chords.enumerated().map { ($0.element.id, $0.offset) })

        var loaded: [RecordingTake] = []
        for url in urls {
            guard url.pathExtension.lowercased() == "wav" else { continue }
            let stem = url.deletingPathExtension().lastPathComponent
            guard let parsed = parseStemAndTakeIndex(filenameStem: stem) else { continue }
            guard let chord = chord(forSanitizedStem: parsed.sanitizedStem, in: chords) else { continue }

            let id = UUID()
            let d = quickDurationSeconds(url: url)
            let take = RecordingTake(
                id: id,
                chordId: chord.id,
                displayName: chord.displayName,
                takeIndex: parsed.takeIndex,
                originalFileURL: url,
                fileURL: url,
                duration: d,
                peakLinear: 0,
                rmsLinear: 0,
                waveformEnvelope: []
            )
            loaded.append(take)
        }

        loaded.sort {
            let oa = chordOrder[$0.chordId] ?? Int.max
            let ob = chordOrder[$1.chordId] ?? Int.max
            if oa != ob { return oa < ob }
            return $0.takeIndex < $1.takeIndex
        }

        return loaded
    }
}

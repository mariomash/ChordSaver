import Foundation

enum FilenameSanitizer {
    /// Produces a filesystem-safe token for flat export names (no path separators).
    static func sanitizeChordName(_ name: String) -> String {
        var s = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { s = "Chord" }
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>#")
        s = s.components(separatedBy: invalid).joined(separator: "_")
        s = s.replacingOccurrences(of: " ", with: "_")
        while s.contains("__") {
            s = s.replacingOccurrences(of: "__", with: "_")
        }
        return s
    }

    /// Next free filename in `directory` matching `base_takeNN.wav`.
    static func uniqueExportURL(directory: URL, sanitizedChord: String, preferredTakeIndex: Int) -> URL {
        var n = max(1, preferredTakeIndex)
        while true {
            let name = String(format: "%@_take%02d.wav", sanitizedChord, n)
            let url = directory.appendingPathComponent(name, isDirectory: false)
            if !FileManager.default.fileExists(atPath: url.path) {
                return url
            }
            n += 1
        }
    }
}

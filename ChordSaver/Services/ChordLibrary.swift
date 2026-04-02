import Foundation

enum ChordLibrary {
    static func loadBundled() throws -> [Chord] {
        guard let url = Bundle.main.url(forResource: "chords", withExtension: "json") else {
            throw NSError(domain: "ChordSaver", code: 20, userInfo: [NSLocalizedDescriptionKey: "Missing chords.json in bundle"])
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        return try decoder.decode([Chord].self, from: data).map { chord in
            var resolved = chord
            resolved.displayName = ChordDisplayNameFormatter.resolvedDisplayName(for: chord)
            return resolved
        }
    }
}

enum ChordDisplayNameFormatter {
    static func resolvedDisplayName(for chord: Chord) -> String {
        let parts = chord.id.split(separator: "_")
        guard parts.count >= 5 else { return chord.displayName }

        let shapeToken = String(parts[2]).lowercased()
        let shapeLabel: String
        switch shapeToken {
        case "e":
            shapeLabel = "E-shape"
        case "a":
            shapeLabel = "A-shape"
        default:
            return chord.displayName
        }

        guard let positionPart = parts.first(where: { $0.hasPrefix("p") }),
              let shift = Int(positionPart.dropFirst())
        else {
            return chord.displayName
        }

        let positionLabel: String
        switch shift {
        case 0:
            positionLabel = "1"
        case 5:
            positionLabel = "2"
        case 10:
            positionLabel = "3"
        default:
            positionLabel = "+\(shift)"
        }

        return "\(chord.displayName) - \(shapeLabel) \(positionLabel)"
    }
}

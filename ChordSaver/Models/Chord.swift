import Foundation

/// One guitar voicing loaded from `chords.json`.
struct Chord: Identifiable, Codable, Hashable {
    var id: String
    /// Display name, e.g. `Cmaj7`.
    var displayName: String
    var category: String
    /// Fret per string from low E (index 0) to high e (index 5). `-1` = muted/unplayed.
    var strings: [Int]
    /// Leftmost fret shown on the diagram (1 = nut).
    var baseFret: Int
    /// Optional suggested finger per string; `0` = none in JSON.
    var fingers: [Int]?

    enum CodingKeys: String, CodingKey {
        case id, displayName, category, strings, baseFret, fingers
    }
}

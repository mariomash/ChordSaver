import Foundation

enum ChordLibrary {
    static func loadBundled() throws -> [Chord] {
        guard let url = Bundle.main.url(forResource: "chords", withExtension: "json") else {
            throw NSError(domain: "ChordSaver", code: 20, userInfo: [NSLocalizedDescriptionKey: "Missing chords.json in bundle"])
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        return try decoder.decode([Chord].self, from: data)
    }
}

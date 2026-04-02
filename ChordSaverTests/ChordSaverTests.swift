import XCTest
@testable import ChordSaver

final class ChordSaverTests: XCTestCase {
    func testSanitizeChordName() {
        XCTAssertEqual(FilenameSanitizer.sanitizeChordName("C#maj7"), "C_maj7")
        XCTAssertEqual(FilenameSanitizer.sanitizeChordName("A/B"), "A_B")
        XCTAssertEqual(FilenameSanitizer.sanitizeChordName("  "), "Chord")
    }

    func testTakeIndexBook() {
        var book = TakeIndexBook()
        XCTAssertEqual(book.registerTake(chordId: "a"), 1)
        XCTAssertEqual(book.registerTake(chordId: "a"), 2)
        XCTAssertEqual(book.registerTake(chordId: "b"), 1)
        XCTAssertEqual(book.currentIndex(for: "a"), 2)
    }

    func testUniqueExportURL() {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let u1 = FilenameSanitizer.uniqueExportURL(directory: tmp, sanitizedChord: "Cmaj7", preferredTakeIndex: 1)
        try! Data().write(to: u1)
        let u2 = FilenameSanitizer.uniqueExportURL(directory: tmp, sanitizedChord: "Cmaj7", preferredTakeIndex: 1)
        XCTAssertNotEqual(u1.lastPathComponent, u2.lastPathComponent)
        XCTAssertTrue(u2.lastPathComponent.contains("02"))
        try? FileManager.default.removeItem(at: tmp)
    }
}

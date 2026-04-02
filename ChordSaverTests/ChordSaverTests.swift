import AVFoundation
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
        XCTAssertEqual(book.registerTake(displayName: "C"), 1)
        XCTAssertEqual(book.registerTake(displayName: "C"), 2)
        XCTAssertEqual(book.registerTake(displayName: "G"), 1)
        XCTAssertEqual(book.currentIndex(for: "C"), 2)
    }

    func testTakeIndexBookNormalizesDisplayName() {
        var book = TakeIndexBook()
        XCTAssertEqual(book.registerTake(displayName: "C"), 1)
        XCTAssertEqual(book.registerTake(displayName: "  C  "), 2)
        XCTAssertEqual(book.currentIndex(for: "C"), 2)
    }

    func testTakeIndexBookSeedsFromExistingTakes() {
        let u = URL(fileURLWithPath: "/tmp/t.wav")
        let t = RecordingTake(
            id: UUID(),
            chordId: "x",
            displayName: " C ",
            takeIndex: 5,
            originalFileURL: u,
            fileURL: u,
            duration: 1,
            peakLinear: 0.1,
            rmsLinear: 0.1,
            waveformEnvelope: []
        )
        var book = TakeIndexBook()
        book.seedFromExistingTakes([t])
        XCTAssertEqual(book.registerTake(displayName: "C"), 6)
    }

    func testParseTakeFilenameStem() {
        XCTAssertEqual(TakeFileScanner.parseStemAndTakeIndex(filenameStem: "C_take01")?.sanitizedStem, "C")
        XCTAssertEqual(TakeFileScanner.parseStemAndTakeIndex(filenameStem: "C_take01")?.takeIndex, 1)
        XCTAssertEqual(TakeFileScanner.parseStemAndTakeIndex(filenameStem: "C_-_E-shape_2_take12")?.takeIndex, 12)
        XCTAssertNil(TakeFileScanner.parseStemAndTakeIndex(filenameStem: "orphan"))
    }

    func testChordDisplayNameFormatterAddsVoicingName() {
        let chord = Chord(
            id: "c_maj_e_1_p5_2",
            displayName: "C",
            category: "major",
            strings: [13, 15, 15, 14, 13, 13],
            baseFret: 13,
            fingers: nil
        )

        XCTAssertEqual(ChordDisplayNameFormatter.resolvedDisplayName(for: chord), "C - E-shape 2")
    }

    func testChordDisplayNameFormatterFallsBackForUnknownIDs() {
        let chord = Chord(
            id: "custom_c_variant",
            displayName: "C",
            category: "major",
            strings: [0, 3, 2, 0, 1, 0],
            baseFret: 1,
            fingers: nil
        )

        XCTAssertEqual(ChordDisplayNameFormatter.resolvedDisplayName(for: chord), "C")
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

    func testFinalizeExactChunkBoundaryCAF() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let cafURL = tmp.appendingPathComponent("exact_boundary_float.caf")
        let wavURL = tmp.appendingPathComponent("exact_boundary.wav")
        let totalFrames = 42 * 4096
        let chunkFrames: AVAudioFrameCount = 4096
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]

        let file = try AVAudioFile(forWriting: cafURL, settings: settings)
        let format = file.processingFormat
        XCTAssertEqual(format.channelCount, 2)

        var writtenFrames = 0
        while writtenFrames < totalFrames {
            let framesThisChunk = min(Int(chunkFrames), totalFrames - writtenFrames)
            let buffer = try XCTUnwrap(
                AVAudioPCMBuffer(
                    pcmFormat: format,
                    frameCapacity: AVAudioFrameCount(framesThisChunk)
                )
            )
            buffer.frameLength = AVAudioFrameCount(framesThisChunk)
            try fillTestStereoBuffer(buffer, startingFrame: writtenFrames)
            try file.write(from: buffer)
            writtenFrames += framesThisChunk
        }

        try AudioCaptureEngine.copyFloatPCMToWAV(
            source: cafURL,
            destination: wavURL,
            recordingDuration: Double(totalFrames) / 48_000
        )

        let wav = try AVAudioFile(forReading: wavURL)
        XCTAssertEqual(wav.length, AVAudioFramePosition(totalFrames))

        let wavBytes = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: wavURL.path)[.size] as? NSNumber
        ).intValue
        XCTAssertEqual(wavBytes, 44 + totalFrames * 2 * 3)

        let analysis = try ChordSaver.WaveformEnvelopeBuilder.analyze(url: wavURL)
        XCTAssertEqual(analysis.envelope.count, ChordSaver.WaveformEnvelopeBuilder.defaultBinCount * 2)
        XCTAssertGreaterThan(analysis.peakLinear, 0.1)
        XCTAssertEqual(analysis.duration, Double(totalFrames) / 48_000, accuracy: 0.001)
    }

    private func fillTestStereoBuffer(_ buffer: AVAudioPCMBuffer, startingFrame: Int) throws {
        guard let channels = buffer.floatChannelData else {
            throw XCTSkip("Float channel data unavailable for test buffer.")
        }

        let frames = Int(buffer.frameLength)
        if buffer.format.isInterleaved {
            let samples = channels[0]
            for i in 0..<frames {
                let sample = Float(((startingFrame + i) % 31) - 15) / 16
                samples[2 * i] = sample
                samples[2 * i + 1] = -sample
            }
            return
        }

        let left = channels[0]
        let right = channels[1]
        for i in 0..<frames {
            let sample = Float(((startingFrame + i) % 31) - 15) / 16
            left[i] = sample
            right[i] = -sample
        }
    }
}

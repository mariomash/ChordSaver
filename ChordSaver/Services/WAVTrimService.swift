import AVFoundation
import Foundation

enum WAVTrimService {
    /// Copies `[startSeconds, endSeconds]` into a new 24-bit PCM stereo WAV at `destination`.
    static func trim(source: URL, startSeconds: TimeInterval, endSeconds: TimeInterval, destination: URL) throws {
        let inFile = try AVAudioFile(forReading: source)
        let sr = inFile.processingFormat.sampleRate
        let len = inFile.length
        guard len > 0 else {
            throw NSError(domain: "ChordSaver", code: 48, userInfo: [NSLocalizedDescriptionKey: "Source file is empty."])
        }
        let t0 = max(0, min(startSeconds, endSeconds))
        let t1 = max(t0, max(startSeconds, endSeconds))
        let startF = AVAudioFramePosition(min(Double(len), max(0, t0 * sr)))
        let endF = AVAudioFramePosition(min(Double(len), max(Double(startF), t1 * sr)))
        try AudioCaptureEngine.trimInt24WAV(source: source, startFrame: startF, endFrame: endF, destination: destination)
    }
}

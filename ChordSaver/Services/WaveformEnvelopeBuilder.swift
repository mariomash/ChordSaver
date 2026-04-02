import AVFoundation
import Foundation

/// Builds a min/max envelope and level stats from an audio file (e.g. session WAV).
enum WaveformEnvelopeBuilder {
    static let defaultBinCount = 2048

    struct Analysis: Sendable {
        let duration: TimeInterval
        let peakLinear: Float
        let rmsLinear: Float
        /// Flattened min0, max0, min1, max1, … (mid-channel sample per frame bin).
        let envelope: [Float]
    }

    /// Reads the file on the caller's thread; call from a background task for large files.
    static func analyze(url: URL, binCount: Int = defaultBinCount) throws -> Analysis {
        let inFile = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let fmt = inFile.processingFormat
        let totalFrames = inFile.length
        guard totalFrames > 0 else {
            throw NSError(
                domain: "ChordSaver",
                code: 42,
                userInfo: [NSLocalizedDescriptionKey: "Audio file has zero length."]
            )
        }
        let sr = fmt.sampleRate
        let bins = min(max(binCount, 32), 8192)
        var binMin = [Float](repeating: 0, count: bins)
        var binMax = [Float](repeating: 0, count: bins)
        var binAny = [Bool](repeating: false, count: bins)

        var peakLinear: Float = 0
        var sumSqMid: Double = 0
        var midSamples: Int64 = 0

        let chunkCap: AVAudioFrameCount = 4096
        guard let readBuf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunkCap) else {
            throw NSError(domain: "ChordSaver", code: 44, userInfo: [NSLocalizedDescriptionKey: "Buffer alloc failed."])
        }

        inFile.framePosition = 0
        var global: AVAudioFramePosition = 0
        var remaining = totalFrames

        while remaining > 0 {
            readBuf.frameLength = 0
            let toRead = AVAudioFrameCount(min(AVAudioFramePosition(chunkCap), remaining))
            try inFile.read(into: readBuf, frameCount: toRead)
            let n = Int(readBuf.frameLength)
            if n == 0 { break }
            for i in 0..<n {
                let (pk, mid) = peakAndMid(buffer: readBuf, frame: i)
                if pk > peakLinear { peakLinear = pk }
                let m = Double(mid)
                sumSqMid += m * m
                midSamples += 1

                let f = global + AVAudioFramePosition(i)
                let bi = Int(Double(f) * Double(bins) / Double(totalFrames))
                let b = min(max(bi, 0), bins - 1)
                if !binAny[b] {
                    binMin[b] = mid
                    binMax[b] = mid
                    binAny[b] = true
                } else {
                    binMin[b] = min(binMin[b], mid)
                    binMax[b] = max(binMax[b], mid)
                }
            }
            global += AVAudioFramePosition(n)
            remaining -= AVAudioFramePosition(n)
        }

        var env: [Float] = []
        env.reserveCapacity(bins * 2)
        for b in 0..<bins {
            if binAny[b] {
                let mn = max(-1, min(1, binMin[b]))
                let mx = max(-1, min(1, binMax[b]))
                env.append(mn.isFinite ? mn : 0)
                env.append(mx.isFinite ? mx : 0)
            } else {
                env.append(0)
                env.append(0)
            }
        }

        let rmsLinear: Float = midSamples > 0 ? sqrt(Float(sumSqMid / Double(midSamples))) : 0
        let duration = Double(totalFrames) / sr

        return Analysis(
            duration: duration,
            peakLinear: peakLinear,
            rmsLinear: rmsLinear,
            envelope: env
        )
    }

    private static func peakAndMid(buffer: AVAudioPCMBuffer, frame i: Int) -> (peak: Float, mid: Float) {
        guard let floatData = buffer.floatChannelData else { return (0, 0) }
        let ch = Int(buffer.format.channelCount)
        if buffer.format.isInterleaved {
            let p = floatData[0]
            if ch >= 2 {
                let left = p[2 * i]
                let right = p[2 * i + 1]
                return (max(abs(left), abs(right)), (left + right) * 0.5)
            }
            let s = p[i]
            return (abs(s), s)
        }
        if ch == 1 {
            let s = floatData[0][i]
            return (abs(s), s)
        }
        let left = floatData[0][i]
        let right = floatData[1][i]
        return (max(abs(left), abs(right)), (left + right) * 0.5)
    }
}

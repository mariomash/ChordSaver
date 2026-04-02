import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// Captures from the selected input device. Records **48 kHz stereo** float PCM, then finalizes to **24-bit linear PCM WAV** on stop.
final class AudioCaptureEngine: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var peakDB: Float = -80
    @Published private(set) var rmsDB: Float = -80
    @Published private(set) var clipped = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var lastError: String?

    @Published private(set) var inputFormatDescription: String = "—"

    private let engine = AVAudioEngine()
    private let processQueue = DispatchQueue(label: "com.chordsaver.audio.process", qos: .userInitiated)
    private let meterLock = NSLock()

    private var audioFile: AVAudioFile?
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?

    private var selectedDeviceID: AudioDeviceID = AudioInputDevice.defaultDeviceID
    private var recordStart: Date?
    private var meterTimer: Timer?

    private var scratchOutput: AVAudioPCMBuffer?

    private var peakHold: Float = 0
    private var rmsAccum: Float = 0
    private var rmsTicks: Int = 0

    private var envelopeBins: [(min: Float, max: Float)] = []
    private let maxEnvelopeBins = 256
    private var envelopeFrameCounter: Int = 0
    private let envelopeStride = 2048

    static let targetSampleRate: Double = 48_000
    static let targetChannels: AVAudioChannelCount = 2

    init() {
        DispatchQueue.main.async { [weak self] in
            self?.updateInputFormatDescription()
        }
    }

    func applyInputDevice(_ device: AudioInputDevice) {
        selectedDeviceID = device.deviceID
        do {
            try configureEngineInputDevice(device.deviceID)
            updateInputFormatDescription()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func configureEngineInputDevice(_ deviceID: AudioDeviceID) throws {
        let wasRunning = engine.isRunning
        if wasRunning { engine.stop() }
        engine.reset()

        if deviceID != AudioInputDevice.defaultDeviceID {
            try engine.inputNode.auAudioUnit.setDeviceID(deviceID)
        }

        if wasRunning {
            try engine.start()
        }
    }

    private func updateInputFormatDescription() {
        let f = engine.inputNode.outputFormat(forBus: 0)
        inputFormatDescription = String(
            format: "%.0f Hz · %d ch",
            f.sampleRate,
            f.channelCount
        )
    }

    func warmUp() {
        do {
            if selectedDeviceID != AudioInputDevice.defaultDeviceID {
                try configureEngineInputDevice(selectedDeviceID)
            }
            updateInputFormatDescription()
            if !engine.isRunning {
                try engine.start()
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stopEngineIfIdle() {
        guard !isRecording else { return }
        if engine.isRunning {
            engine.stop()
        }
    }

    /// Writes **48 kHz stereo float** to `url` during capture; replaces existing file.
    func startRecording(to url: URL) throws {
        lastError = nil
        try configureEngineInputDevice(selectedDeviceID)

        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        updateInputFormatDescription()

        guard let outFmt = Self.makeFloatTargetFormat() else {
            throw NSError(domain: "ChordSaver", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot build 48kHz float stereo format"])
        }
        outputFormat = outFmt

        guard let conv = AVAudioConverter(from: inputFormat, to: outFmt) else {
            throw NSError(domain: "ChordSaver", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot create audio converter"])
        }
        Self.applyChannelMap(converter: conv, inputChannels: inputFormat.channelCount)
        converter = conv

        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        audioFile = try AVAudioFile(forWriting: url, settings: outFmt.settings, commonFormat: outFmt.commonFormat, interleaved: outFmt.isInterleaved)

        let cap: AVAudioFrameCount = 4096
        scratchOutput = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: max(cap, 8192))

        meterLock.lock()
        peakHold = 0
        rmsAccum = 0
        rmsTicks = 0
        envelopeBins = []
        envelopeFrameCounter = 0
        meterLock.unlock()

        clipped = false

        engine.inputNode.removeTap(onBus: 0)
        engine.inputNode.installTap(onBus: 0, bufferSize: cap, format: inputFormat) { [weak self] buffer, _ in
            self?.processQueue.async {
                self?.handleTap(buffer: buffer)
            }
        }

        if !engine.isRunning {
            try engine.start()
        }

        recordStart = Date()
        isRecording = true
        elapsed = 0
        startMeterTimer()
    }

    /// Stops capture. If `finalizeTo24BitURL` is set, rewrites float temp at `floatURL` to 24-bit WAV at that URL (replacing if present).
    func stopRecording(floatURL: URL, finalizeTo24BitURL: URL?) throws -> RecordingStats {
        guard isRecording else {
            throw NSError(domain: "ChordSaver", code: 3, userInfo: [NSLocalizedDescriptionKey: "Not recording"])
        }

        engine.inputNode.removeTap(onBus: 0)
        isRecording = false
        stopMeterTimer()

        converter = nil
        audioFile = nil
        scratchOutput = nil

        let duration = recordStart.map { Date().timeIntervalSince($0) } ?? 0
        recordStart = nil

        meterLock.lock()
        let ph = peakHold
        let ra = rmsAccum
        let rt = rmsTicks
        let env = envelopeBins
        meterLock.unlock()

        let rmsLinear: Float = rt > 0 ? sqrt(ra / Float(rt)) : 0
        let envFlat: [Float] = env.flatMap { [$0.min, $0.max] }

        if let finalURL = finalizeTo24BitURL {
            try Self.convertFloatWAVToInt24WAV(source: floatURL, destination: finalURL)
            try? FileManager.default.removeItem(at: floatURL)
        }

        if !engine.isRunning {
            try? engine.start()
        }

        peakDB = -80
        rmsDB = -80
        elapsed = 0

        return RecordingStats(
            duration: duration,
            peakLinear: ph,
            rmsLinear: rmsLinear,
            waveformEnvelope: envFlat
        )
    }

    struct RecordingStats {
        let duration: TimeInterval
        let peakLinear: Float
        let rmsLinear: Float
        let waveformEnvelope: [Float]
    }

    private func startMeterTimer() {
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.tickMeterUI()
        }
        RunLoop.main.add(meterTimer!, forMode: .common)
    }

    private func stopMeterTimer() {
        meterTimer?.invalidate()
        meterTimer = nil
    }

    private func tickMeterUI() {
        guard isRecording, let start = recordStart else { return }
        elapsed = Date().timeIntervalSince(start)

        meterLock.lock()
        let p = peakHold
        let ra = rmsAccum
        let rt = rmsTicks
        peakHold *= 0.90
        rmsAccum = 0
        rmsTicks = 0
        meterLock.unlock()

        peakDB = p > 0 ? 20 * log10(p) : -96
        let r = rt > 0 ? sqrt(ra / Float(rt)) : 0
        rmsDB = r > 0 ? 20 * log10(r) : -96
        if p >= 0.999 {
            clipped = true
        }
    }

    private func handleTap(buffer: AVAudioPCMBuffer) {
        analyzeInputForMeters(buffer: buffer)

        guard let converter, let outFmt = outputFormat, let file = audioFile else { return }

        var outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * (outFmt.sampleRate / buffer.format.sampleRate) + 64)
        if outCapacity < 1024 { outCapacity = 1024 }

        if scratchOutput == nil || scratchOutput!.frameCapacity < outCapacity {
            scratchOutput = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: outCapacity)
        }
        guard let outScratch = scratchOutput else { return }

        var supplied = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if !supplied {
                supplied = true
                outStatus.pointee = .haveData
                return buffer
            }
            outStatus.pointee = .noDataNow
            return nil
        }
        while true {
            outScratch.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: outScratch, error: &error, withInputFrom: inputBlock)
            if let error {
                DispatchQueue.main.async { [weak self] in
                    self?.lastError = error.localizedDescription
                }
                break
            }
            if outScratch.frameLength > 0 {
                do {
                    try file.write(from: outScratch)
                } catch {
                    DispatchQueue.main.async { [weak self] in
                        self?.lastError = error.localizedDescription
                    }
                    break
                }
            }
            if status == .endOfStream || status == .inputRanDry {
                break
            }
        }
    }

    private func analyzeInputForMeters(buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        let ch = Int(buffer.format.channelCount)

        var peak: Float = 0
        var sumSq: Float = 0

        if let fd = buffer.floatChannelData {
            for i in 0..<frames {
                var m: Float = 0
                for c in 0..<ch {
                    let v = abs(fd[c][i])
                    if v > m { m = v }
                }
                if m > peak { peak = m }
                sumSq += m * m
            }

            meterLock.lock()
            if peak > peakHold { peakHold = peak }
            rmsAccum += sumSq / Float(frames)
            rmsTicks += 1

            envelopeFrameCounter += frames
            if envelopeFrameCounter >= envelopeStride, envelopeBins.count < maxEnvelopeBins {
                envelopeFrameCounter = 0
                var mn: Float = 0
                var mx: Float = 0
                for i in 0..<frames {
                    var s: Float = fd[0][i]
                    if ch > 1 {
                        s = (s + fd[1][i]) * 0.5
                    }
                    mn = min(mn, s)
                    mx = max(mx, s)
                }
                envelopeBins.append((min: mn, max: mx))
            }
            meterLock.unlock()
        } else if let id = buffer.int32ChannelData {
            let scale: Float = 1.0 / 32_768.0
            for i in 0..<frames {
                var m: Float = 0
                for c in 0..<ch {
                    let v = abs(Float(id[c][i]) * scale)
                    if v > m { m = v }
                }
                if m > peak { peak = m }
                sumSq += m * m
            }
            meterLock.lock()
            if peak > peakHold { peakHold = peak }
            rmsAccum += sumSq / Float(frames)
            rmsTicks += 1
            meterLock.unlock()
        }
    }

    private static func makeFloatTargetFormat() -> AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: targetChannels,
            interleaved: false
        )
    }

    private static func makeInt24TargetFormat() -> AVAudioFormat? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: targetSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: UInt32(kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved),
            mBytesPerPacket: 3,
            mFramesPerPacket: 1,
            mBytesPerFrame: 3,
            mChannelsPerFrame: UInt32(targetChannels),
            mBitsPerChannel: 24,
            mReserved: 0
        )
        return AVAudioFormat(streamDescription: &asbd)
    }

    private static func applyChannelMap(converter: AVAudioConverter, inputChannels: AVAudioChannelCount) {
        let ic = Int(inputChannels)
        if ic == 1 {
            converter.channelMap = [0, 0]
        } else if ic >= 2 {
            converter.channelMap = [0, 1]
        } else {
            converter.channelMap = []
        }
    }

    /// Reads float 48k stereo WAV and writes 24-bit 48k stereo WAV.
    static func convertFloatWAVToInt24WAV(source: URL, destination: URL) throws {
        let inFile = try AVAudioFile(forReading: source)
        let inFormat = inFile.processingFormat

        guard let outFormat = makeInt24TargetFormat() else {
            throw NSError(domain: "ChordSaver", code: 10, userInfo: [NSLocalizedDescriptionKey: "Missing int24 format"])
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        let outFile = try AVAudioFile(forWriting: destination, settings: outFormat.settings, commonFormat: outFormat.commonFormat, interleaved: outFormat.isInterleaved)

        let chunk: AVAudioFrameCount = 4096
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: chunk) else {
            throw NSError(domain: "ChordSaver", code: 12, userInfo: [NSLocalizedDescriptionKey: "Buffer alloc failed"])
        }

        inFile.framePosition = 0
        while true {
            inBuf.frameLength = 0
            try inFile.read(into: inBuf, frameCount: chunk)
            if inBuf.frameLength == 0 { break }

            guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
                throw NSError(domain: "ChordSaver", code: 11, userInfo: [NSLocalizedDescriptionKey: "Cannot create finalize converter"])
            }

            let outCap = max(chunk, inBuf.frameLength + 512)
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCap) else {
                throw NSError(domain: "ChordSaver", code: 12, userInfo: [NSLocalizedDescriptionKey: "Buffer alloc failed"])
            }

            var supplied = false
            let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                if !supplied {
                    supplied = true
                    outStatus.pointee = .haveData
                    return inBuf
                }
                outStatus.pointee = .noDataNow
                return nil
            }

            while true {
                outBuf.frameLength = 0
                var error: NSError?
                let status = converter.convert(to: outBuf, error: &error, withInputFrom: inputBlock)
                if let error { throw error }
                if outBuf.frameLength > 0 {
                    try outFile.write(from: outBuf)
                }
                if status == .endOfStream || status == .inputRanDry {
                    break
                }
            }
        }
    }
}

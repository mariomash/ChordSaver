import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// Captures from the selected input device. Records **48 kHz stereo float** to CAF, then finalizes to **lossless float WAV** (no conversion — avoids AVAudioConverter int24 Obj‑C failures).
final class AudioCaptureEngine: ObservableObject {
    /// Set from the app (e.g. `AppViewModel`) to capture a rolling technical log in the UI.
    var debugLogHandler: ((String) -> Void)?

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

    private static let debugTimestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private func logDebug(_ message: String) {
        let line = "[\(Self.debugTimestampFormatter.string(from: Date()))] \(message)"
        DispatchQueue.main.async { [weak self] in
            self?.debugLogHandler?(line)
        }
        #if DEBUG
        print(line)
        #endif
    }

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
            logDebug("applyInputDevice OK deviceID=\(device.deviceID)")
        } catch {
            logDebug("applyInputDevice FAILED \(Self.technicalErrorDescription(error))")
            lastError = Self.describeError(error)
        }
    }

    /// - Parameter resumeEngine: If `true`, restarts the engine when it was running before this call. Set `false` before `installTap` / `removeTap` on the input node (required by AVAudioEngine).
    private func configureEngineInputDevice(_ deviceID: AudioDeviceID, resumeEngine: Bool = true) throws {
        let wasRunning = engine.isRunning
        if wasRunning { engine.stop() }
        engine.reset()

        if deviceID != AudioInputDevice.defaultDeviceID {
            try engine.inputNode.auAudioUnit.setDeviceID(deviceID)
        }

        if resumeEngine, wasRunning {
            engine.prepare()
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
                try configureEngineInputDevice(selectedDeviceID, resumeEngine: true)
            }
            updateInputFormatDescription()
            if !engine.isRunning {
                logDebug("warmUp prepare+start")
                engine.prepare()
                try engine.start()
            }
            lastError = nil
            logDebug("warmUp OK running=\(engine.isRunning) \(inputFormatDescription)")
        } catch {
            logDebug("warmUp FAILED \(Self.technicalErrorDescription(error))")
            lastError = Self.describeError(error)
        }
    }

    func stopEngineIfIdle() {
        guard !isRecording else { return }
        if engine.isRunning {
            engine.stop()
        }
    }

    /// Writes **48 kHz stereo float** to `url` during capture (use a **.caf** URL for reliable creation). Replaces existing file.
    func startRecording(to url: URL) throws {
        logDebug("startRecording begin \(url.path)")
        lastError = nil

        // Do **not** call `engine.reset()` here — it tears down the graph and often leads to GenericObjCError / error 0 on the next tap/start.
        if engine.isRunning {
            logDebug("startRecording engine.stop()")
            engine.stop()
        }
        engine.inputNode.removeTap(onBus: 0)

        if selectedDeviceID != AudioInputDevice.defaultDeviceID {
            logDebug("startRecording setDeviceID(\(selectedDeviceID))")
            do {
                try engine.inputNode.auAudioUnit.setDeviceID(selectedDeviceID)
            } catch {
                logDebug("setDeviceID FAILED \(Self.technicalErrorDescription(error))")
                throw error
            }
        } else {
            logDebug("startRecording system default input (no setDeviceID)")
        }

        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        logDebug(
            "inputFormat sampleRate=\(inputFormat.sampleRate) channels=\(inputFormat.channelCount) interleaved=\(inputFormat.isInterleaved) commonFormat.raw=\(inputFormat.commonFormat.rawValue)"
        )

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            let err = NSError(
                domain: "ChordSaver",
                code: 20,
                userInfo: [NSLocalizedDescriptionKey: "Microphone input is not ready (0 Hz or 0 channels). Try “Refresh devices”, pick another input, or grant microphone access in System Settings."]
            )
            logDebug("INVALID inputFormat — \(Self.technicalErrorDescription(err))")
            throw err
        }

        updateInputFormatDescription()

        guard let outFmt = Self.makeFloatTargetFormat() else {
            logDebug("makeFloatTargetFormat returned nil")
            throw NSError(domain: "ChordSaver", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot build 48kHz float stereo format"])
        }
        outputFormat = outFmt

        if Self.needsAVAudioConverter(from: inputFormat, to: outFmt) {
            guard let conv = AVAudioConverter(from: inputFormat, to: outFmt) else {
                logDebug("AVAudioConverter init returned nil")
                throw NSError(domain: "ChordSaver", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot create audio converter"])
            }
            Self.applyChannelMap(converter: conv, inputChannels: inputFormat.channelCount)
            converter = conv
            logDebug("using AVAudioConverter (resample or >2ch)")
        } else {
            converter = nil
            logDebug("no AVAudioConverter (same rate, ≤2 ch)")
        }

        let parent = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            logDebug("ensure directory OK \(parent.path)")
        } catch {
            logDebug("createDirectory FAILED \(Self.technicalErrorDescription(error))")
            throw error
        }

        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
            logDebug("removed existing temp file")
        }

        do {
            audioFile = try AVAudioFile(forWriting: url, settings: Self.cafFloatStereoCaptureSettings)
            logDebug("AVAudioFile forWriting OK (.caf)")
        } catch {
            logDebug("AVAudioFile forWriting FAILED \(Self.technicalErrorDescription(error))")
            throw error
        }

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

        logDebug("installTap bufferSize=\(cap)")
        engine.inputNode.installTap(onBus: 0, bufferSize: cap, format: inputFormat) { [weak self] buffer, _ in
            self?.processQueue.async {
                self?.handleTap(buffer: buffer)
            }
        }

        logDebug("engine.prepare()")
        engine.prepare()
        do {
            logDebug("engine.start()")
            try engine.start()
            logDebug("engine.start() OK")
        } catch {
            logDebug("engine.start() FAILED \(Self.technicalErrorDescription(error))")
            engine.inputNode.removeTap(onBus: 0)
            audioFile = nil
            converter = nil
            scratchOutput = nil
            throw error
        }

        recordStart = Date()
        isRecording = true
        elapsed = 0
        startMeterTimer()
    }

    /// Stops capture. If `finalizeToWAVURL` is set, copies float PCM from `floatURL` (.caf) to a **float WAV** at that URL (same layout as capture — no `AVAudioConverter`).
    func stopRecording(floatURL: URL, finalizeToWAVURL: URL?) throws -> RecordingStats {
        logDebug("stopRecording begin float=\(floatURL.lastPathComponent)")
        guard isRecording else {
            throw NSError(domain: "ChordSaver", code: 3, userInfo: [NSLocalizedDescriptionKey: "Not recording"])
        }

        if engine.isRunning {
            engine.stop()
        }
        engine.inputNode.removeTap(onBus: 0)
        logDebug("tap removed, engine stopped=\(!engine.isRunning)")
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

        if let finalURL = finalizeToWAVURL {
            logDebug("finalize → \(finalURL.lastPathComponent) (float PCM copy)")
            do {
                try Self.copyFloatPCMToWAV(source: floatURL, destination: finalURL)
                logDebug("finalize OK")
            } catch {
                logDebug("finalize FAILED \(Self.technicalErrorDescription(error))")
                throw error
            }
            try? FileManager.default.removeItem(at: floatURL)
        }

        if !engine.isRunning {
            engine.prepare()
            do {
                try engine.start()
                logDebug("idle engine restarted OK running=\(engine.isRunning)")
            } catch {
                logDebug("idle engine restart FAILED \(Self.technicalErrorDescription(error))")
            }
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

        guard let outFmt = outputFormat, let file = audioFile else { return }
        guard buffer.frameLength > 0 else { return }

        let inFmt = buffer.format

        // Same rate: avoid AVAudioConverter for common cases (fixes paramErr -50 from WAV / channel-map edge cases).
        if converter == nil, abs(inFmt.sampleRate - outFmt.sampleRate) < 0.5 {
            let n = Int(buffer.frameLength)
            if inFmt.channelCount == 1, outFmt.channelCount == 2,
               let inFD = buffer.floatChannelData, let outScratch = ensureScratchStereoFloat(frames: n, format: outFmt),
               let outP = outScratch.floatChannelData?[0]
            {
                let s0 = inFD[0]
                outScratch.frameLength = AVAudioFrameCount(n)
                for i in 0..<n {
                    let s = s0[i]
                    outP[2 * i] = s
                    outP[2 * i + 1] = s
                }
                writeOutScratch(outScratch, to: file)
                return
            }
            if inFmt.channelCount == 2, outFmt.channelCount == 2,
               let inFD = buffer.floatChannelData, let outScratch = ensureScratchStereoFloat(frames: n, format: outFmt),
               let outP = outScratch.floatChannelData?[0]
            {
                outScratch.frameLength = AVAudioFrameCount(n)
                if inFmt.isInterleaved {
                    let p = inFD[0]
                    for i in 0..<n {
                        outP[2 * i] = p[2 * i]
                        outP[2 * i + 1] = p[2 * i + 1]
                    }
                } else {
                    let a = inFD[0]
                    let b = inFD[1]
                    for i in 0..<n {
                        outP[2 * i] = a[i]
                        outP[2 * i + 1] = b[i]
                    }
                }
                writeOutScratch(outScratch, to: file)
                return
            }
        }

        guard let converter else {
            DispatchQueue.main.async { [weak self] in
                self?.lastError = "Unsupported input format for recording (channels=\(inFmt.channelCount), rate=\(inFmt.sampleRate))."
            }
            return
        }

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
                writeOutScratch(outScratch, to: file)
            }
            if status == .endOfStream || status == .inputRanDry {
                break
            }
        }
    }

    private func ensureScratchStereoFloat(frames: Int, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let need = AVAudioFrameCount(max(frames, 64))
        if scratchOutput == nil || scratchOutput!.frameCapacity < need {
            scratchOutput = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(need, 8192))
        }
        return scratchOutput
    }

    private func writeOutScratch(_ outScratch: AVAudioPCMBuffer, to file: AVAudioFile) {
        do {
            try file.write(from: outScratch)
            DispatchQueue.main.async { [weak self] in
                self?.lastError = nil
            }
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.lastError = error.localizedDescription
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

    /// Linear PCM float stereo interleaved at 48 kHz — matches `cafFloatStereoCaptureSettings`.
    private static let cafFloatStereoCaptureSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: targetSampleRate,
        AVNumberOfChannelsKey: targetChannels,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]

    static func describeError(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain.contains("GenericObjCError") || (ns.domain == NSCocoaErrorDomain && ns.code == 0) {
            return "Audio or file setup failed (internal error 0). Open **Debug log** below for the technical line, or try another input / restart the app."
        }
        if !ns.localizedDescription.isEmpty, ns.localizedDescription != "The operation couldn’t be completed." {
            return ns.localizedDescription
        }
        return "\(ns.domain) (\(ns.code))"
    }

    /// Full bridge details for the debug panel (domain, code, userInfo, underlying error).
    static func technicalErrorDescription(_ error: Error) -> String {
        func format(_ e: NSError, depth: Int) -> String {
            guard depth < 4 else { return "…" }
            let infoPairs = e.userInfo
                .map { "\($0.key)=\($0.value)" }
                .sorted()
                .joined(separator: "; ")
            var s = "domain=\(e.domain) code=\(e.code) desc=\(e.localizedDescription)"
            if !infoPairs.isEmpty {
                s += " userInfo=[\(infoPairs)]"
            }
            if let u = e.userInfo[NSUnderlyingErrorKey] as? NSError {
                s += " underlying=(\(format(u, depth: depth + 1)))"
            }
            return s
        }
        return format(error as NSError, depth: 0)
    }

    private static func makeFloatTargetFormat() -> AVAudioFormat? {
        // Interleaved stereo: required for reliable RIFF/WAV writes via AVAudioFile (non-interleaved often yields paramErr -50).
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: targetChannels,
            interleaved: true
        )
    }

    private static func needsAVAudioConverter(from input: AVAudioFormat, to output: AVAudioFormat) -> Bool {
        if abs(input.sampleRate - output.sampleRate) > 0.5 { return true }
        if input.channelCount > 2 { return true }
        return false
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

    /// Copies float 48 kHz interleaved stereo PCM from CAF (or any readable file with the same processing format) to WAV — **no** `AVAudioConverter` (int24 conversion was triggering `GenericObjCError`).
    static func copyFloatPCMToWAV(source: URL, destination: URL) throws {
        let inFile = try AVAudioFile(forReading: source)
        let inFormat = inFile.processingFormat

        guard inFormat.commonFormat == .pcmFormatFloat32,
              abs(inFormat.sampleRate - targetSampleRate) < 0.5,
              inFormat.channelCount == targetChannels,
              inFormat.isInterleaved
        else {
            throw NSError(
                domain: "ChordSaver",
                code: 30,
                userInfo: [NSLocalizedDescriptionKey: "Temp file format mismatch (need 48 kHz, stereo, interleaved float)."]
            )
        }

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }

        let outFile: AVAudioFile
        do {
            outFile = try AVAudioFile(
                forWriting: destination,
                settings: Self.cafFloatStereoCaptureSettings,
                commonFormat: .pcmFormatFloat32,
                interleaved: true
            )
        } catch {
            outFile = try AVAudioFile(forWriting: destination, settings: Self.cafFloatStereoCaptureSettings)
        }

        let chunk: AVAudioFrameCount = 4096
        guard let buffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: chunk) else {
            throw NSError(domain: "ChordSaver", code: 12, userInfo: [NSLocalizedDescriptionKey: "Buffer alloc failed"])
        }

        inFile.framePosition = 0
        while true {
            buffer.frameLength = 0
            try inFile.read(into: buffer, frameCount: chunk)
            if buffer.frameLength == 0 { break }
            try outFile.write(from: buffer)
        }
    }
}

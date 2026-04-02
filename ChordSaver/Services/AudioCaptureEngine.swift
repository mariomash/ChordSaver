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
            logDebug("no AVAudioConverter (same rate/channels/layout, ≤2 ch, float)")
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
        // Drain tap callbacks so the last buffer is written before we close `audioFile` (avoids truncated CAF / finalize Obj‑C error 0).
        processQueue.sync {}
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
                try Self.copyFloatPCMToWAV(source: floatURL, destination: finalURL, log: { self.logDebug($0) })
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
            logDebug("writeOutScratch FAILED \(Self.technicalErrorDescription(error))")
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
            if e.domain == NSOSStatusErrorDomain {
                s += " (OSStatus \(e.code) = '\(Self.fourCC(UInt32(bitPattern: Int32(e.code))))')"
            }
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

    private static func fourCC(_ value: UInt32) -> String {
        let b0 = UInt8((value >> 24) & 0xff)
        let b1 = UInt8((value >> 16) & 0xff)
        let b2 = UInt8((value >> 8) & 0xff)
        let b3 = UInt8(value & 0xff)
        let chars = [b0, b1, b2, b3].map { c -> Character in
            (32...126).contains(c) ? Character(UnicodeScalar(c)) : "?"
        }
        return String(chars)
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
        // Mono→stereo (or any ch mismatch): the no-converter tap path requires `floatChannelData`;
        // macOS often delivers mono as non-interleaved float with nil/misaligned views so **no samples**
        // are written and the CAF stays at 0 frames (`read` then fails at finalize).
        if input.channelCount != output.channelCount { return true }
        if input.commonFormat != output.commonFormat { return true }
        if input.isInterleaved != output.isInterleaved { return true }
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

    /// Copies float 48 kHz mono or stereo PCM from CAF to **IEEE float stereo** WAV.
    /// WAV bytes are written manually (RIFF + `WAVE_FORMAT_IEEE_FLOAT`); `AVAudioFile` output to `.wav` often raises `Foundation._GenericObjCError` (0) on some macOS versions.
    static func copyFloatPCMToWAV(source: URL, destination: URL, log: (String) -> Void = { _ in }) throws {
        let srcBytes: Int64 = (try? FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int64) ?? -1
        log("finalize: src on disk bytes=\(srcBytes) path=\(source.lastPathComponent)")

        log("finalize: open CAF forReading…")
        let inFile: AVAudioFile
        do {
            inFile = try AVAudioFile(forReading: source)
        } catch {
            log("finalize: open CAF FAILED \(technicalErrorDescription(error))")
            throw error
        }

        let srcFormat = inFile.processingFormat
        log(
            "finalize: CAF processingFormat sr=\(srcFormat.sampleRate) ch=\(srcFormat.channelCount) interleaved=\(srcFormat.isInterleaved) commonFormat.raw=\(srcFormat.commonFormat.rawValue) fileFrames=\(inFile.length)"
        )

        guard srcFormat.commonFormat == .pcmFormatFloat32,
              abs(srcFormat.sampleRate - targetSampleRate) < 0.5,
              srcFormat.channelCount >= 1, srcFormat.channelCount <= targetChannels
        else {
            let err = NSError(
                domain: "ChordSaver",
                code: 30,
                userInfo: [NSLocalizedDescriptionKey: "Temp file format mismatch (need 48 kHz, 1–2 ch, float32)."]
            )
            log("finalize: format guard FAILED (see ChordSaver code 30)")
            throw err
        }

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }

        guard let interleavedStereo = makeFloatTargetFormat() else {
            log("finalize: makeFloatTargetFormat nil")
            throw NSError(domain: "ChordSaver", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot build 48kHz float stereo format"])
        }

        let chunk: AVAudioFrameCount = 4096
        guard let readBuf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: chunk),
              let writeBuf = AVAudioPCMBuffer(pcmFormat: interleavedStereo, frameCapacity: chunk)
        else {
            log("finalize: buffer alloc FAILED")
            throw NSError(domain: "ChordSaver", code: 12, userInfo: [NSLocalizedDescriptionKey: "Buffer alloc failed"])
        }

        log("finalize: open WAV for raw IEEE float write…")
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            log("finalize: createFile FAILED \(destination.path)")
            throw NSError(domain: "ChordSaver", code: 35, userInfo: [NSLocalizedDescriptionKey: "Could not create WAV file."])
        }
        let outHandle = try FileHandle(forWritingTo: destination)
        defer {
            try? outHandle.close()
        }

        // Placeholder header; patch RIFF size (offset 4) and data size (offset 40) after streaming PCM.
        try outHandle.write(contentsOf: Self.placeholderFloatStereoWAVHeader())
        var totalPCMBytes: UInt64 = 0
        var chunkIndex = 0
        inFile.framePosition = 0

        // Empty CAF: `AVAudioFile.read` can throw GenericObjCError (0) instead of returning 0 frames.
        if inFile.length == 0 {
            log("finalize: CAF has 0 audio frames (nothing was written during capture); writing empty WAV")
        } else {
            while true {
                readBuf.frameLength = 0
                do {
                    try inFile.read(into: readBuf, frameCount: chunk)
                } catch {
                    log("finalize: read chunk \(chunkIndex) FAILED \(technicalErrorDescription(error))")
                    throw error
                }
                let n = Int(readBuf.frameLength)
                if n == 0 { break }
                writeBuf.frameLength = readBuf.frameLength
                do {
                    try packFloatStereoForWAV(from: readBuf, to: writeBuf, frames: n)
                } catch {
                    log("finalize: pack chunk \(chunkIndex) frames=\(n) FAILED \(technicalErrorDescription(error))")
                    throw error
                }
                guard let interleavedPtr = writeBuf.floatChannelData?[0] else {
                    log("finalize: missing floatChannelData after pack chunk \(chunkIndex)")
                    throw NSError(domain: "ChordSaver", code: 31, userInfo: [NSLocalizedDescriptionKey: "Missing float channel data for finalize."])
                }
                let floatCount = n * Int(targetChannels)
                let byteCount = floatCount * MemoryLayout<Float>.size
                let chunkData = Data(buffer: UnsafeBufferPointer(start: interleavedPtr, count: floatCount))
                do {
                    try outHandle.write(contentsOf: chunkData)
                } catch {
                    log("finalize: FileHandle write chunk \(chunkIndex) bytes=\(byteCount) FAILED \(technicalErrorDescription(error))")
                    throw error
                }
                totalPCMBytes += UInt64(byteCount)
                chunkIndex += 1
            }
        }

        let fileSize = UInt64(44) + totalPCMBytes
        let riffChunkSize = UInt32(truncatingIfNeeded: fileSize - 8)
        let dataChunkSize = UInt32(truncatingIfNeeded: totalPCMBytes)
        try outHandle.seek(toOffset: 4)
        try outHandle.write(contentsOf: riffChunkSize.littleEndianBytes)
        try outHandle.seek(toOffset: 40)
        try outHandle.write(contentsOf: dataChunkSize.littleEndianBytes)

        log("finalize: WAV done chunks=\(chunkIndex) pcmBytes=\(totalPCMBytes) fileSize=\(fileSize)")
    }

    /// 44-byte canonical PCM WAV header: IEEE float stereo 48 kHz; RIFF + data sizes are zero until patched.
    private static func placeholderFloatStereoWAVHeader() -> Data {
        var d = Data()
        d.append(contentsOf: "RIFF".utf8)
        d.append(UInt32(0).littleEndianBytes)
        d.append(contentsOf: "WAVE".utf8)
        d.append(contentsOf: "fmt ".utf8)
        d.append(UInt32(16).littleEndianBytes)
        d.append(UInt16(3).littleEndianBytes) // WAVE_FORMAT_IEEE_FLOAT
        d.append(UInt16(truncatingIfNeeded: targetChannels).littleEndianBytes)
        d.append(UInt32(targetSampleRate).littleEndianBytes)
        let byteRate = UInt32(targetSampleRate * Double(targetChannels) * Double(MemoryLayout<Float>.size))
        d.append(byteRate.littleEndianBytes)
        let blockAlign = UInt16(targetChannels) * UInt16(MemoryLayout<Float>.size)
        d.append(blockAlign.littleEndianBytes)
        d.append(UInt16(32).littleEndianBytes)
        d.append(contentsOf: "data".utf8)
        d.append(UInt32(0).littleEndianBytes)
        return d
    }

    /// Copies float samples from `from` (1–2 ch, any interleaving) into `to`, matching `to.format` (48 kHz stereo float).
    private static func packFloatStereoForWAV(from src: AVAudioPCMBuffer, to dst: AVAudioPCMBuffer, frames: Int) throws {
        guard let srcFD = src.floatChannelData, let dstFD = dst.floatChannelData else {
            throw NSError(domain: "ChordSaver", code: 31, userInfo: [NSLocalizedDescriptionKey: "Missing float channel data for finalize."])
        }
        let sch = Int(src.format.channelCount)
        let dch = Int(dst.format.channelCount)
        guard dch == 2, frames > 0 else {
            throw NSError(domain: "ChordSaver", code: 33, userInfo: [NSLocalizedDescriptionKey: "Unsupported finalize channel layout."])
        }

        if dst.format.isInterleaved {
            let d0 = dstFD[0]
            if sch == 1 {
                let s = srcFD[0]
                for i in 0..<frames {
                    let v = s[i]
                    d0[2 * i] = v
                    d0[2 * i + 1] = v
                }
                return
            }
            if sch == 2, src.format.isInterleaved {
                let s = srcFD[0]
                let byteCount = frames * 2 * MemoryLayout<Float>.size
                memcpy(d0, s, byteCount)
                return
            }
            if sch == 2 {
                let l = srcFD[0]
                let r = srcFD[1]
                for i in 0..<frames {
                    d0[2 * i] = l[i]
                    d0[2 * i + 1] = r[i]
                }
                return
            }
        } else {
            let dl = dstFD[0]
            let dr = dstFD[1]
            if sch == 1 {
                let s = srcFD[0]
                for i in 0..<frames {
                    let v = s[i]
                    dl[i] = v
                    dr[i] = v
                }
                return
            }
            if sch == 2, src.format.isInterleaved {
                let s = srcFD[0]
                for i in 0..<frames {
                    dl[i] = s[2 * i]
                    dr[i] = s[2 * i + 1]
                }
                return
            }
            if sch == 2 {
                let l = srcFD[0]
                let r = srcFD[1]
                memcpy(dl, l, frames * MemoryLayout<Float>.size)
                memcpy(dr, r, frames * MemoryLayout<Float>.size)
                return
            }
        }

        throw NSError(domain: "ChordSaver", code: 34, userInfo: [NSLocalizedDescriptionKey: "Cannot pack source layout for WAV."])
    }
}

private extension UInt16 {
    var littleEndianBytes: Data {
        var v = littleEndian
        return Swift.withUnsafeBytes(of: &v) { Data($0) }
    }
}

private extension UInt32 {
    var littleEndianBytes: Data {
        var v = littleEndian
        return Swift.withUnsafeBytes(of: &v) { Data($0) }
    }
}

import AppKit
import Foundation
import SwiftUI

@MainActor
final class AppViewModel: ObservableObject {
    @Published var chords: [Chord] = []
    @Published var currentIndex: Int = 0
    @Published var search: String = ""

    @Published var devices: [AudioInputDevice] = []
    @Published var selectedDevice: AudioInputDevice = .defaultEntry()

    @Published var takes: [RecordingTake] = []
    @Published var lastTake: RecordingTake?

    /// User-selected folder (security-scoped). `nil` until a folder is chosen or bookmark fails.
    @Published private(set) var workspaceFolderURL: URL?
    private var workspaceSecurityScoped = false

    /// Bumped when recording starts so the last-take preview player can stop.
    @Published private(set) var lastTakePreviewStopToken: UInt64 = 0

    @Published var isFinalizingAudio = false
    @Published var statusMessage: String = ""

    @Published var debugLogExpanded = false
    @Published private(set) var debugLogLines: [String] = []

    let audio = AudioCaptureEngine()
    private let maxDebugLogLines = 400
    private var takeBook = TakeIndexBook()

    private static let debugTimestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private var pendingFloatURL: URL?
    private var pendingFinalURL: URL?
    private var pendingChord: Chord?
    private var pendingTakeIndex: Int = 0

    init() {
        do {
            chords = try ChordLibrary.loadBundled()
        } catch {
            statusMessage = error.localizedDescription
        }

        if let url = try? WorkspaceFolderAccess.resolveBookmarkedFolder() {
            if url.startAccessingSecurityScopedResource() {
                workspaceFolderURL = url
                workspaceSecurityScoped = true
                rescanWorkspaceTakesFromDisk()
                appendDebugLog("[workspace] restored \(url.path)")
            } else {
                WorkspaceFolderAccess.clearBookmark()
                appendDebugLog("[workspace] bookmark could not be accessed — choose a folder")
            }
        } else {
            appendDebugLog("[workspace] choose a folder to store recordings")
        }

        refreshDevices()

        audio.debugLogHandler = { [weak self] line in
            Task { @MainActor in
                self?.appendDebugLog(line)
            }
        }
    }

    func appendDebugLog(_ line: String) {
        debugLogLines.append(line)
        if debugLogLines.count > maxDebugLogLines {
            debugLogLines.removeFirst(debugLogLines.count - maxDebugLogLines)
        }
    }

    private func appendDebugLogStamped(_ line: String) {
        let ts = Self.debugTimestampFormatter.string(from: Date())
        appendDebugLog("[\(ts)] \(line)")
    }

    func clearDebugLog() {
        debugLogLines.removeAll()
    }

    func copyDebugLogToPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(debugLogLines.joined(separator: "\n"), forType: .string)
    }

    /// Call from the main window `onAppear` so unit-test hosts do not start `AVAudioEngine` at launch.
    func startAudioSessionIfNeeded() {
        guard workspaceFolderURL != nil else { return }
        audio.applyInputDevice(selectedDevice)
        audio.warmUp()
    }

    /// Presents the open panel and adopts the chosen directory as the workspace.
    func chooseWorkspaceFolder() {
        guard let url = WorkspaceFolderAccess.pickWorkspaceFolder() else { return }
        adoptWorkspaceFolder(url)
    }

    func adoptWorkspaceFolder(_ url: URL) {
        releaseWorkspaceFolderAccess()
        guard url.startAccessingSecurityScopedResource() else {
            statusMessage = "Could not access the chosen folder."
            WorkspaceFolderAccess.clearBookmark()
            return
        }
        workspaceSecurityScoped = true
        workspaceFolderURL = url
        do {
            try WorkspaceFolderAccess.saveBookmark(for: url)
        } catch {
            appendDebugLogStamped("[bookmark save failed] \(error.localizedDescription)")
        }
        rescanWorkspaceTakesFromDisk()
        statusMessage = "Workspace: \(url.lastPathComponent)"
        appendDebugLog("[workspace] \(url.path)")
        audio.applyInputDevice(selectedDevice)
        audio.warmUp()
    }

    private func releaseWorkspaceFolderAccess() {
        if !audio.isRecording {
            audio.stopEngineIfIdle()
        }
        if workspaceSecurityScoped, let u = workspaceFolderURL {
            u.stopAccessingSecurityScopedResource()
        }
        workspaceSecurityScoped = false
        workspaceFolderURL = nil
        takes = []
        takeBook = TakeIndexBook()
        lastTake = nil
    }

    /// Reloads `takes` from `*_takeNN.wav` files in the workspace (top level only).
    func rescanWorkspaceTakesFromDisk() {
        guard let root = workspaceFolderURL else {
            takes = []
            takeBook = TakeIndexBook()
            lastTake = nil
            return
        }
        let loaded = TakeFileScanner.scan(directory: root, chords: chords)
        takes = loaded
        var book = TakeIndexBook()
        book.seedFromExistingTakes(loaded)
        takeBook = book
        lastTake = loaded.last
        for t in loaded {
            enqueueEnvelopeAnalysis(forTakeID: t.id, url: t.fileURL)
        }
    }

    private func enqueueEnvelopeAnalysis(forTakeID id: UUID, url: URL) {
        Task.detached { [id] in
            do {
                let analysis = try WaveformEnvelopeBuilder.analyze(url: url)
                await MainActor.run { [weak self] in
                    self?.applyEnvelopeAnalysis(takeID: id, analysis: analysis, url: url)
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.appendDebugLogStamped("[waveform analyze failed] \(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
    }

    private func sortTakesInChordOrder() {
        let order = Dictionary(uniqueKeysWithValues: chords.enumerated().map { ($0.element.id, $0.offset) })
        takes.sort {
            let oa = order[$0.chordId] ?? Int.max
            let ob = order[$1.chordId] ?? Int.max
            if oa != ob { return oa < ob }
            return $0.takeIndex < $1.takeIndex
        }
    }

    private func applyEnvelopeAnalysis(takeID: UUID, analysis: WaveformEnvelopeBuilder.Analysis, url: URL) {
        guard let i = takes.firstIndex(where: { $0.id == takeID }) else { return }
        let t = takes[i]
        let updated = RecordingTake(
            id: t.id,
            chordId: t.chordId,
            displayName: t.displayName,
            takeIndex: t.takeIndex,
            originalFileURL: t.originalFileURL,
            fileURL: url,
            duration: analysis.duration,
            peakLinear: analysis.peakLinear,
            rmsLinear: analysis.rmsLinear,
            waveformEnvelope: analysis.envelope
        )
        takes[i] = updated
        if lastTake?.id == takeID {
            lastTake = updated
        }
    }

    var filteredChords: [Chord] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return chords }
        return chords.filter {
            $0.displayName.lowercased().contains(q) || $0.category.lowercased().contains(q) || $0.id.lowercased().contains(q)
        }
    }

    var currentChord: Chord? {
        guard currentIndex >= 0, currentIndex < chords.count else { return nil }
        return chords[currentIndex]
    }

    var chordIdsWithRecordedTakes: Set<String> {
        Set(takes.map(\.chordId))
    }

    var takesForCurrentChord: [RecordingTake] {
        guard let id = currentChord?.id else { return [] }
        return takes.filter { $0.chordId == id }
    }

    /// Last appended take for the selected chord (same order as global `takes`).
    var mostRecentTakeForCurrentChord: RecordingTake? {
        takesForCurrentChord.last
    }

    func refreshDevices() {
        devices = AudioDeviceEnumerator.refreshInputDevices()
        if !devices.contains(where: { $0.deviceID == selectedDevice.deviceID }) {
            selectedDevice = devices.first ?? .defaultEntry()
            audio.applyInputDevice(selectedDevice)
            if workspaceFolderURL != nil {
                audio.warmUp()
            }
        }
    }

    func selectDevice(_ device: AudioInputDevice) {
        selectedDevice = device
        audio.applyInputDevice(device)
        if workspaceFolderURL != nil {
            audio.warmUp()
        }
    }

    func jumpToChord(id: String) {
        if let i = chords.firstIndex(where: { $0.id == id }) {
            currentIndex = i
        }
    }

    func replaceTake(id: UUID, with newTake: RecordingTake) {
        guard newTake.id == id else { return }
        if let i = takes.firstIndex(where: { $0.id == id }) {
            takes[i] = newTake
        }
        if lastTake?.id == id {
            lastTake = newTake
        }
    }

    func toggleRecord() {
        if audio.isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        guard let chord = currentChord else { return }
        guard let workspaceURL = workspaceFolderURL else {
            statusMessage = "Choose a workspace folder first."
            return
        }

        lastTakePreviewStopToken &+= 1
        let takeN = takeBook.registerTake(displayName: chord.displayName)
        let sanitized = FilenameSanitizer.sanitizeChordName(chord.displayName)
        let finalURL = FilenameSanitizer.uniqueExportURL(
            directory: workspaceURL,
            sanitizedChord: sanitized,
            preferredTakeIndex: takeN
        )
        let floatURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChordSaver_\(UUID().uuidString).caf", isDirectory: false)

        do {
            try audio.startRecording(to: floatURL)
            pendingFloatURL = floatURL
            pendingFinalURL = finalURL
            pendingChord = chord
            pendingTakeIndex = takeN
            statusMessage = "Recording: \(chord.displayName) (take \(takeN))"
        } catch {
            let tech = AudioCaptureEngine.technicalErrorDescription(error)
            appendDebugLogStamped("[record failed] \(tech)")
            statusMessage = AudioCaptureEngine.describeError(error)
            debugLogExpanded = true
        }
    }

    private func stopRecording() {
        guard let floatURL = pendingFloatURL, let finalURL = pendingFinalURL, let chord = pendingChord else {
            statusMessage = "Internal: missing recording state"
            return
        }
        let takeN = pendingTakeIndex

        isFinalizingAudio = true
        statusMessage = "Finalizing 24-bit WAV…"

        do {
            let stats = try audio.stopRecording(floatURL: floatURL, finalizeToWAVURL: finalURL)
            pendingFloatURL = nil
            pendingFinalURL = nil
            pendingChord = nil
            pendingTakeIndex = 0
            try? FileManager.default.removeItem(at: floatURL)

            let takeId = UUID()
            let take = RecordingTake(
                id: takeId,
                chordId: chord.id,
                displayName: chord.displayName,
                takeIndex: takeN,
                originalFileURL: finalURL,
                fileURL: finalURL,
                duration: stats.duration,
                peakLinear: stats.peakLinear,
                rmsLinear: stats.rmsLinear,
                waveformEnvelope: []
            )
            takes.append(take)
            sortTakesInChordOrder()
            lastTake = take
            let peakDb = stats.peakLinear > 0 ? 20 * log10(stats.peakLinear) : -96
            statusMessage = String(format: "Saved · %.2f s · peak %.1f dBFS · %@", stats.duration, peakDb, finalURL.lastPathComponent)

            let chordCaptured = chord
            let takeNCaptured = takeN
            let urlCaptured = finalURL
            Task.detached { [takeId] in
                do {
                    let analysis = try WaveformEnvelopeBuilder.analyze(url: urlCaptured)
                    let updated = RecordingTake(
                        id: takeId,
                        chordId: chordCaptured.id,
                        displayName: chordCaptured.displayName,
                        takeIndex: takeNCaptured,
                        originalFileURL: urlCaptured,
                        fileURL: urlCaptured,
                        duration: analysis.duration,
                        peakLinear: analysis.peakLinear,
                        rmsLinear: analysis.rmsLinear,
                        waveformEnvelope: analysis.envelope
                    )
                    await MainActor.run { [weak self] in
                        self?.replaceTake(id: takeId, with: updated)
                    }
                } catch {
                    await MainActor.run { [weak self] in
                        self?.appendDebugLogStamped("[waveform analyze failed] \(error.localizedDescription)")
                    }
                }
            }

            if currentIndex + 1 < chords.count {
                currentIndex += 1
            } else {
                statusMessage += " · End of chord list"
            }
        } catch {
            let tech = AudioCaptureEngine.technicalErrorDescription(error)
            appendDebugLogStamped("[finalize failed] \(tech)")
            statusMessage = AudioCaptureEngine.describeError(error)
            debugLogExpanded = true
            pendingFloatURL = nil
            pendingFinalURL = nil
            pendingChord = nil
            pendingTakeIndex = 0
            try? FileManager.default.removeItem(at: floatURL)
        }

        isFinalizingAudio = false
        if workspaceFolderURL != nil {
            audio.warmUp()
        }
    }
}

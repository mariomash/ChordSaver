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

    @Published var isFinalizingAudio = false
    @Published var statusMessage: String = ""

    let audio = AudioCaptureEngine()
    private var takeBook = TakeIndexBook()
    private var sessionFolder: URL!

    private var pendingFloatURL: URL?
    private var pendingFinalURL: URL?
    private var pendingChord: Chord?
    private var pendingTakeIndex: Int = 0

    init() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        sessionFolder = base.appendingPathComponent("ChordSaver", isDirectory: true)
            .appendingPathComponent("Sessions", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? fm.createDirectory(at: sessionFolder, withIntermediateDirectories: true)

        do {
            chords = try ChordLibrary.loadBundled()
        } catch {
            statusMessage = error.localizedDescription
        }

        refreshDevices()
    }

    /// Call from the main window `onAppear` so unit-test hosts do not start `AVAudioEngine` at launch.
    func startAudioSessionIfNeeded() {
        audio.applyInputDevice(selectedDevice)
        audio.warmUp()
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

    func refreshDevices() {
        devices = AudioDeviceEnumerator.refreshInputDevices()
        if !devices.contains(where: { $0.deviceID == selectedDevice.deviceID }) {
            selectedDevice = devices.first ?? .defaultEntry()
            audio.applyInputDevice(selectedDevice)
            audio.warmUp()
        }
    }

    func selectDevice(_ device: AudioInputDevice) {
        selectedDevice = device
        audio.applyInputDevice(device)
        audio.warmUp()
    }

    func jumpToChord(id: String) {
        if let i = chords.firstIndex(where: { $0.id == id }) {
            currentIndex = i
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
        let baseName = "\(chord.id)_\(UUID().uuidString.prefix(8))"
        let floatURL = sessionFolder.appendingPathComponent("\(baseName)_float.wav")
        let finalURL = sessionFolder.appendingPathComponent("\(baseName).wav")

        do {
            try audio.startRecording(to: floatURL)
            let takeN = takeBook.registerTake(chordId: chord.id)
            pendingFloatURL = floatURL
            pendingFinalURL = finalURL
            pendingChord = chord
            pendingTakeIndex = takeN
            statusMessage = "Recording: \(chord.displayName) (take \(takeN))"
        } catch {
            statusMessage = error.localizedDescription
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
            let stats = try audio.stopRecording(floatURL: floatURL, finalizeTo24BitURL: finalURL)
            pendingFloatURL = nil
            pendingFinalURL = nil
            pendingChord = nil
            pendingTakeIndex = 0
            let take = RecordingTake(
                id: UUID(),
                chordId: chord.id,
                displayName: chord.displayName,
                takeIndex: takeN,
                fileURL: finalURL,
                duration: stats.duration,
                peakLinear: stats.peakLinear,
                rmsLinear: stats.rmsLinear,
                waveformEnvelope: stats.waveformEnvelope
            )
            takes.append(take)
            lastTake = take
            let peakDb = stats.peakLinear > 0 ? 20 * log10(stats.peakLinear) : -96
            statusMessage = String(format: "Saved · %.2f s · peak %.1f dBFS · %@", stats.duration, peakDb, finalURL.lastPathComponent)

            if currentIndex + 1 < chords.count {
                currentIndex += 1
            } else {
                statusMessage += " · End of chord list"
            }
        } catch {
            statusMessage = error.localizedDescription
            pendingFloatURL = nil
            pendingFinalURL = nil
            pendingChord = nil
            pendingTakeIndex = 0
            try? FileManager.default.removeItem(at: floatURL)
        }

        isFinalizingAudio = false
        audio.warmUp()
    }

    func exportSession() {
        guard let folder = ExportService.pickFolder() else { return }
        do {
            let n = try ExportService.export(takes: takes, to: folder)
            statusMessage = "Exported \(n) file(s) to \(folder.path)"
        } catch {
            statusMessage = exportErrorMessage(error, folder: folder)
        }
    }

    private func exportErrorMessage(_ error: Error, folder: URL) -> String {
        let msg = error.localizedDescription
        if msg.contains("Operation not permitted") || (error as NSError).code == 513 {
            return "Export failed: enable folder access. Re-open the folder in the panel or add ChordSaver to Full Disk Access if needed. (\(folder.lastPathComponent))"
        }
        return "Export failed: \(msg)"
    }
}

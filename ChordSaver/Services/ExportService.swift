import AppKit
import Foundation

enum ExportService {
    static func pickFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose a folder for exported WAV files."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url
    }

    /// Copies each take to `folder` using flat sanitized names. Returns count exported or throws.
    static func export(takes: [RecordingTake], to folder: URL) throws -> Int {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                folder.stopAccessingSecurityScopedResource()
            }
        }
        var count = 0
        for take in takes {
            let base = FilenameSanitizer.sanitizeChordName(take.displayName)
            let dest = FilenameSanitizer.uniqueExportURL(
                directory: folder,
                sanitizedChord: base,
                preferredTakeIndex: take.takeIndex
            )
            try FileManager.default.copyItem(at: take.fileURL, to: dest)
            count += 1
        }
        return count
    }
}

import AppKit
import Foundation

/// Security-scoped bookmark persistence and folder picker for the recording workspace.
enum WorkspaceFolderAccess {
    private static let bookmarkKey = "ChordSaver.workspaceBookmark.v1"

    static func clearBookmark() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
    }

    static func saveBookmark(for url: URL) throws {
        let data = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(data, forKey: bookmarkKey)
    }

    /// Resolves a stored workspace URL, or `nil` if none / invalid.
    static func resolveBookmarkedFolder() throws -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey), !data.isEmpty else {
            return nil
        }
        var stale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        if stale {
            if url.startAccessingSecurityScopedResource() {
                try? saveBookmark(for: url)
                url.stopAccessingSecurityScopedResource()
            }
        }
        return url
    }

    /// Modal open panel; returns a directory URL the user chose (not yet security-scoped until `startAccessing`).
    static func pickWorkspaceFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose a folder for ChordSaver recordings (24-bit stereo WAV files)."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url
    }
}

import Foundation

/// Files picked from iCloud Drive may not be on the device yet. Reading one
/// through file coordination downloads it first, which can take a while for
/// big files such as comics, so the importer says it's downloading.
public enum CloudFiles {
    /// Whether the file lives in iCloud and isn't fully downloaded.
    public static func needsDownload(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
              values.isUbiquitousItem == true else { return false }
        return values.ubiquitousItemDownloadingStatus != .current
    }

    /// Starts downloading the file in the background if it's in iCloud and
    /// not on the device yet. Returns at once.
    public static func requestDownload(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard needsDownload(url) else { return }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
    }

    /// Downloads the file if needed, returning once it's readable. Runs the
    /// blocking coordinated read off the caller's thread.
    public static func download(_ url: URL) async throws {
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        try await Task.detached(priority: .userInitiated) {
            var coordinationError: NSError?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { _ in }
            if let coordinationError { throw coordinationError }
        }.value
    }
}

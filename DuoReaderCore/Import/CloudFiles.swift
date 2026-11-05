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

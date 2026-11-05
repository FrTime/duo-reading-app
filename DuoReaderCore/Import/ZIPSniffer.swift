import Foundation
import ReadiumZIPFoundation

/// Works out which book format a plain `.zip` holds, since books are often
/// shared zipped: FictionBook as `name.fb2.zip`, comics as a `.zip` of pages.
enum ZIPSniffer {
    /// `.fb2` when the archive holds a FictionBook, `.cbz` when it holds only
    /// images (plus comic metadata), otherwise nil.
    static func bookFormat(ofZIP url: URL) async -> BookFormat? {
        guard let archive = try? await Archive(url: url, accessMode: .read),
              let entries = try? await archive.entries() else { return nil }
        let files = visibleFiles(entries)
        if files.contains(where: { $0.path.lowercased().hasSuffix(".fb2") }) { return .fb2 }
        let pages = ComicConverter.pageEntries(entries)
        let extras = files.count - pages.count
        let allowedExtras = files.filter { ["xml", "txt", "nfo", "sfv"].contains(($0.path as NSString).pathExtension.lowercased()) }.count
        return !pages.isEmpty && extras == allowedExtras ? .cbz : nil
    }

    /// The first FictionBook in the archive, by name order.
    static func fb2Entry(in archive: Archive) async throws -> Entry? {
        try await visibleFiles(archive.entries())
            .filter { $0.path.lowercased().hasSuffix(".fb2") }
            .min { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Files, leaving out folders, hidden files and macOS metadata.
    static func visibleFiles(_ entries: [Entry]) -> [Entry] {
        entries.filter { entry in
            entry.type == .file
                && !entry.path.split(separator: "/").contains(where: { $0.hasPrefix(".") || $0 == "__MACOSX" })
        }
    }
}

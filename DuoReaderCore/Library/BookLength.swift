import CoreGraphics
import Foundation
import ReadiumZIPFoundation

/// How long a book is, in printed pages, for sizing its spine on the shelf.
///
/// PDFs and fixed-layout EPUBs (comics) have real pages. Reflowable EPUBs are
/// measured by the words in their spine documents, at about 275 a page.
/// Every other format is converted to EPUB on import, so these two cover the
/// whole library. Measuring reads the book once; the result is cached.
public enum BookLength {
    /// Words on a printed paperback page.
    public static let wordsPerPage = 275
    /// Text read per book, so a huge or crafted file can't take long to measure.
    static let maxTextBytes: Int64 = 40 * 1024 * 1024

    /// The book's page count, or nil when it can't be told.
    public static func pageCount(of url: URL, format: BookFormat) async -> Int? {
        switch format {
        case .pdf:
            guard let document = CGPDFDocument(url as CFURL) else { return nil }
            let pages = document.numberOfPages
            return pages > 0 ? pages : nil
        case .epub:
            return await epubPageCount(of: url)
        default:
            return nil
        }
    }

    /// The page count from the cache file, measuring the book (and writing the
    /// cache) the first time. A book whose length can't be told is cached as 0
    /// so it isn't read again every launch.
    /// The cache is keyed by the file's size and modification date, so a
    /// replaced file is measured again.
    public static func cachedPageCount(of url: URL, format: BookFormat, cache: URL) async -> Int? {
        // Only measure and cache a file that's actually there: a book still
        // downloading would otherwise be stuck at "unknown".
        guard let stamp = fileStamp(of: url) else { return nil }
        if let text = try? String(contentsOf: cache, encoding: .utf8), let value = parseCache(text, stamp: stamp) {
            return value > 0 ? value : nil
        }
        let pages = await pageCount(of: url, format: format)
        try? FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("\(cacheVersion):\(stamp):\(pages ?? 0)".utf8).write(to: cache, options: .atomic)
        return pages
    }

    /// Raised when the measuring changes, so cached lengths are taken again.
    static let cacheVersion = 1

    /// "<bytes>-<modified seconds>", or nil when the file isn't there.
    static func fileStamp(of url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize else { return nil }
        let modified = Int(values.contentModificationDate?.timeIntervalSince1970 ?? 0)
        return "\(size)-\(modified)"
    }

    static func parseCache(_ text: String, stamp: String) -> Int? {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
        guard parts.count == 3, Int(parts[0]) == cacheVersion, parts[1] == stamp,
              let value = Int(parts[2]), value >= 0 else { return nil }
        return value
    }

    // MARK: - EPUB

    static func epubPageCount(of url: URL) async -> Int? {
        guard let archive = try? await Archive(url: url, accessMode: .read),
              let containerData = try? await EPUBMetadataReader.data(at: "META-INF/container.xml", in: archive),
              let opfPath = ContainerParser.rootfilePath(in: containerData),
              let opfData = try? await EPUBMetadataReader.data(at: opfPath, in: archive)
        else { return nil }

        let package = OPFParser.parse(opfData)
        guard !package.spineHrefs.isEmpty else { return nil }
        if package.isFixedLayout {
            return package.spineHrefs.count
        }

        let base = (opfPath as NSString).deletingLastPathComponent
        var counts = TextCount()
        var budget = maxTextBytes
        for href in package.spineHrefs.uniqued() {
            let path = EPUBMetadataReader.resolve(href, relativeTo: base)
            guard let entry = try? await archive.get(path) else { continue }
            // A crafted zip64 header can claim more than Int64 holds.
            let size = Int64(clamping: entry.uncompressedSize)
            if size > EPUBMetadataReader.maxDocumentBytes || size > budget {
                // Too big to read, or past the read budget: estimate from its
                // size (markup is about a quarter of a typical chapter file,
                // words about 6 bytes), capped so a lying header can't make
                // the book absurdly long.
                counts.words += Int(Double(min(size, maxTextBytes)) * 0.75 / 6)
                continue
            }
            guard let data = try? await EPUBMetadataReader.data(at: path, in: archive) else { continue }
            budget -= Int64(data.count)
            counts.add(markup: data)
        }
        return counts.pageCount
    }

    /// Words and text bytes outside markup tags.
    struct TextCount {
        var words = 0
        var textBytes = 0

        /// Counts words in XHTML without building a DOM: anything between
        /// `<` and `>` is skipped, and a word starts wherever text follows
        /// whitespace. Script and style contents are rare in books and only
        /// nudge the count.
        mutating func add(markup data: Data) {
            var inTag = false
            var inWord = false
            for byte in data {
                if inTag {
                    if byte == UInt8(ascii: ">") { inTag = false }
                    continue
                }
                switch byte {
                case UInt8(ascii: "<"):
                    inTag = true
                    inWord = false
                case UInt8(ascii: " "), UInt8(ascii: "\n"), UInt8(ascii: "\r"), UInt8(ascii: "\t"):
                    inWord = false
                default:
                    textBytes += 1
                    if !inWord {
                        words += 1
                        inWord = true
                    }
                }
            }
        }

        /// Pages from the word count, or from the amount of text for scripts
        /// written without spaces (about 1,500 UTF-8 bytes a page in CJK).
        var pageCount: Int? {
            let byWords = words / BookLength.wordsPerPage
            let byText = textBytes / 3000
            let pages = max(byWords, byText)
            return words == 0 ? nil : max(pages, 1)
        }
    }
}

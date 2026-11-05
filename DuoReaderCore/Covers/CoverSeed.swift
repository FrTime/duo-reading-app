import Foundation

/// A snapshot of what a cover is built from. `Book` is a SwiftData model tied
/// to its context, so cover work off the main actor uses this instead.
public struct CoverSeed: Hashable, Sendable {
    public var bookID: UUID
    public var title: String
    public var authors: [String]
    public var series: String?
    public var seriesIndex: Double?
    public var summary: String?
    public var wordCount: Int?
    /// The cover image bytes from the file, if it had one.
    public var embeddedCoverData: Data?

    public init(
        bookID: UUID,
        title: String,
        authors: [String] = [],
        series: String? = nil,
        seriesIndex: Double? = nil,
        summary: String? = nil,
        wordCount: Int? = nil,
        embeddedCoverData: Data? = nil
    ) {
        self.bookID = bookID
        self.title = title
        self.authors = authors
        self.series = series
        self.seriesIndex = seriesIndex
        self.summary = summary
        self.wordCount = wordCount
        self.embeddedCoverData = embeddedCoverData
    }

    /// Authors as one line, or empty when there are none.
    public var authorLine: String {
        authors.formatted(.list(type: .and))
    }

    /// "Series, book 2", or nil.
    public var seriesLine: String? {
        guard let series, !series.isEmpty else { return nil }
        guard let seriesIndex else { return series }
        let number = seriesIndex.rounded() == seriesIndex
            ? String(Int(seriesIndex))
            : seriesIndex.formatted(.number.precision(.fractionLength(0...2)))
        return String(localized: "\(series), book \(number)")
    }

    /// Changes whenever anything a default cover is built from changes.
    public var fingerprint: String {
        var parts = [title, authors.joined(separator: "\u{1F}"), series ?? "", seriesIndex.map { String($0) } ?? ""]
        parts.append(summary ?? "")
        parts.append(wordCount.map(String.init) ?? "")
        parts.append(embeddedCoverData.map { "\($0.count)-\($0.prefix(64).base64EncodedString())-\($0.suffix(64).base64EncodedString())" } ?? "")
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in parts.joined(separator: "\u{1E}").utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    /// A rough page count for sizing the spine: about 275 words a page, and a
    /// typical novel when we can't tell.
    public var estimatedPageCount: Int {
        guard let wordCount, wordCount > 0 else { return 300 }
        return max(wordCount / 275, 8)
    }

    /// The summary trimmed to fit on the back of the jacket.
    public var blurb: String? {
        guard let summary = summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty else {
            return nil
        }
        let limit = 700
        guard summary.count > limit else { return summary }
        let cut = summary.prefix(limit)
        let end = cut.lastIndex(where: { $0 == " " }) ?? cut.endIndex
        return String(cut[..<end]) + "…"
    }
}

extension Book {
    /// The values a cover is built from, safe to hand to background work.
    public var coverSeed: CoverSeed {
        CoverSeed(
            bookID: id,
            title: title,
            authors: authors,
            series: series,
            seriesIndex: seriesIndex,
            summary: summary,
            wordCount: ao3?.wordCount,
            embeddedCoverData: coverImageData
        )
    }
}

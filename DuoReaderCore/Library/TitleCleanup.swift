import Foundation

/// Tidying titles that were made from file names, for books already in the
/// library and from the Edit Details sheet.
///
/// Comics imported before the importer read file names (and any book whose
/// file had no title) can carry a release name as their title:
/// "Claymore v15 (2009) (Digital) (LostNerevarine-Empire)". A cleanup turns
/// that into "Claymore, Vol. 15" and fills in the series when the book has none.
public struct TitleCleanup: Equatable, Sendable {
    public var title: String
    public var series: String?
    public var seriesIndex: Double?

    public init(title: String, series: String? = nil, seriesIndex: Double? = nil) {
        self.title = title
        self.series = series
        self.seriesIndex = seriesIndex
    }
}

extension Book {
    /// The name the book's title would be made from: the imported file's
    /// name, or for books imported before names were kept, the title itself.
    public var titleSourceName: String {
        originalFileName ?? title
    }

    /// The title from the file name as it was, with only the extension and
    /// underscores removed. What "Use File Name" puts back.
    public var plainFileNameTitle: String {
        let name = FileNameTitleParser.stripExtension(titleSourceName)
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? String(localized: "Untitled") : name
    }

    /// The cleaned-up title, series and number for this book's file name,
    /// whether or not they differ from what the book has now.
    public var cleanedTitle: TitleCleanup {
        let parsed = FileNameTitle(fileName: titleSourceName)
        return TitleCleanup(title: parsed.title, series: parsed.series, seriesIndex: parsed.seriesIndex)
    }

    /// A cleanup worth offering in the library-wide list, or nil.
    ///
    /// Only for titles that still look like they came from the file name: a
    /// title from the file's metadata, or one the user typed, is left alone.
    public var suggestedTitleCleanup: TitleCleanup? {
        if originalFileName != nil, title != plainFileNameTitle { return nil }
        let cleanup = cleanedTitle
        let addsSeries = series == nil && cleanup.series != nil
        guard cleanup.title != title || addsSeries else { return nil }
        return cleanup
    }

    /// Applies a cleanup. The series and number are only filled in when the
    /// book has no series, so ones from the file's metadata are kept.
    public func apply(_ cleanup: TitleCleanup) {
        // Books imported before file names were kept: remember the title we
        // started from, so "Use File Name" can still put it back.
        if originalFileName == nil { originalFileName = title }
        title = cleanup.title
        if series == nil, let newSeries = cleanup.series {
            series = newSeries
            seriesIndex = cleanup.seriesIndex
        }
    }
}

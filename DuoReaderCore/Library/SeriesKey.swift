import Foundation

/// A key that's the same for every book in a series, so the shelf can give
/// them one size, like a real boxed set.
///
/// The series from the book's metadata comes first. Without one, a series is
/// read off titles that end in a volume number ("Claymore v15",
/// "Claymore, Vol. 15", "Claymore 03 (Digital) [Group]").
public enum SeriesKey {
    public static func key(series: String?, title: String) -> String? {
        if let series, let key = normalize(series) { return key }
        return fromTitle(title)
    }

    /// The part of the title before a trailing volume number, normalised, or
    /// nil when the title doesn't end in one.
    public static func fromTitle(_ title: String) -> String? {
        // Bracketed tags (year, scan group, "Digital") say nothing about the series.
        let stripped = title
            .replacing(/\([^)]*\)|\[[^\]]*\]|\{[^}]*\}/, with: " ")
            .replacing("_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = /^(?<name>.+?)[\s,:;.\-–—]*(?:(?:vol(?:ume)?|v|book|bk|part|pt|tome|no|#)\.?\s*)?(?<number>\d{1,4}(?:\.\d+)?)$/
            .ignoresCase()
        guard let match = stripped.wholeMatch(of: pattern) else { return nil }
        let name = String(match.output.name)
        guard name.contains(where: \.isLetter) else { return nil }
        return normalize(name)
    }

    /// Lowercased, accents folded, punctuation and runs of spaces collapsed:
    /// "Claymore," and "claymore" are the same series.
    static func normalize(_ text: String) -> String? {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        let words = folded.split { !$0.isLetter && !$0.isNumber }
        // A leading "The" is often dropped from file names.
        let trimmed = words.first == "the" && words.count > 1 ? Array(words.dropFirst()) : Array(words)
        let key = trimmed.joined(separator: " ")
        return key.isEmpty ? nil : key
    }
}

extension Book {
    /// Books with the same key share a default size on the shelf.
    public var seriesKey: String? {
        SeriesKey.key(series: series, title: title)
    }
}

import Foundation

/// What a comic's file name says about it, once the release tags are gone.
///
/// Comic and manga files are usually named for release, not reading:
/// "Claymore v15 (2009) (Digital) (LostNerevarine-Empire).cbz",
/// "[Group] Berserk_v01_c003 [1080p].cbz". This reads the series and the
/// volume or chapter out of names like these and builds a title a person
/// would write: "Claymore, Vol. 15".
public struct FileNameTitle: Equatable, Sendable {
    /// The cleaned-up title, never empty.
    public var title: String
    public var series: String?
    public var volume: Double?
    /// The last volume of a collection such as "v01-v27".
    public var lastVolume: Double?
    public var chapter: Double?
    /// An issue number with no "v" or "ch", such as "Saga 004" or "Saga #4".
    public var number: Double?
    /// Whatever follows the numbers, such as "The Black Swordsman".
    public var subtitle: String?
    /// A release year found in brackets, such as "(2009)".
    public var year: Int?

    /// The number to sort the book within its series by.
    public var seriesIndex: Double? { volume ?? chapter ?? number }

    public init(title: String) {
        self.title = title
    }

    /// Parses a file name, with or without its extension.
    public init(fileName: String) {
        self = FileNameTitleParser.parse(fileName)
    }
}

enum FileNameTitleParser {
    /// Extensions dropped from the end of a name. Only these, so a title
    /// such as "Vol. 15" doesn't lose ". 15" as if it were an extension.
    static let knownExtensions: Set<String> = Set(BookFormat.allCases.flatMap(\.fileExtensions))
        .union(["zip", "rar", "7z", "cb7", "cbt", "tar"])

    /// Release tags that sometimes appear outside brackets at the end of a name.
    /// Only words that are never the end of a real title, so "Charlotte's
    /// Web" or "Born Digital" keep their last word. Tags such as "(Digital)"
    /// are usually bracketed, and brackets are removed separately.
    static let trailingTags: Set<String> = [
        "hq", "lq", "webrip", "web-dl", "c2c", "scans", "scanlation", "repack",
    ]

    static func parse(_ fileName: String) -> FileNameTitle {
        var text = stripExtension(fileName.trimmingCharacters(in: .whitespacesAndNewlines))
        text = text.replacingOccurrences(of: "_", with: " ")
        // "Berserk.v01.c003" uses dots for spaces.
        // Decimal points ("Ch.12.5") are kept.
        if !text.contains(" "), text.filter({ $0 == "." }).count >= 2 {
            let characters = Array(text)
            text = String(characters.indices.map { i -> Character in
                guard characters[i] == "." else { return characters[i] }
                let between = i > 0 && i < characters.count - 1
                    && characters[i - 1].isNumber && characters[i + 1].isNumber
                return between ? "." : " "
            })
        }

        // Bracketed groups are release tags: scanlator, year, source, quality.
        var year: Int?
        let withoutBrackets = text.replacing(bracketGroup) { match in
            let inner = match.output.1.trimmingCharacters(in: .whitespaces)
            if year == nil, let found = inner.wholeMatch(of: yearPattern) { year = Int(found.output) }
            return " "
        }
        let unbracketed = collapse(withoutBrackets)
        // A name that was nothing but brackets keeps their contents.
        text = unbracketed.isEmpty ? collapse(text.replacing(/[\[\]\(\)\{\}]/, with: " ")) : unbracketed
        text = stripTrailingTags(text)

        var result = FileNameTitle(title: text)
        result.year = year

        var head = text[...]
        var tail = ""[...]
        if let match = text.firstMatch(of: volumePattern) {
            result.volume = Double(match.output.1)
            result.lastVolume = match.output.2.flatMap { Double($0) }
            head = text[..<match.range.lowerBound]
            tail = text[match.range.upperBound...]
            if let chapter = tail.prefixMatch(of: chapterPattern) {
                result.chapter = Double(chapter.output.1)
                tail = tail[chapter.range.upperBound...]
            }
        } else if let match = text.firstMatch(of: chapterPattern) {
            result.chapter = Double(match.output.1)
            head = text[..<match.range.lowerBound]
            tail = text[match.range.upperBound...]
        } else if let match = text.firstMatch(of: issuePattern) {
            result.number = Double(match.output.1)
            head = text[..<match.range.lowerBound]
            tail = text[match.range.upperBound...]
        } else {
            result.title = text.isEmpty ? String(localized: "Untitled") : text
            return result
        }

        let series = trimSeparators(head)
        let subtitle = stripTrailingTags(trimSeparators(tail))
        result.series = series.isEmpty ? nil : series
        result.subtitle = subtitle.isEmpty ? nil : subtitle
        result.title = format(result)
        return result
    }

    /// "Claymore, Vol. 15", "Berserk, Vol. 1, Ch. 3: The Brand", "Saga #4".
    static func format(_ parsed: FileNameTitle) -> String {
        var parts: [String] = []
        if let series = parsed.series { parts.append(series) }
        if let volume = parsed.volume {
            if let last = parsed.lastVolume {
                parts.append(String(localized: "Vol. \(number(volume))–\(number(last))"))
            } else {
                parts.append(String(localized: "Vol. \(number(volume))"))
            }
        }
        if let chapter = parsed.chapter { parts.append(String(localized: "Ch. \(number(chapter))")) }
        var title = parts.joined(separator: ", ")
        if let issue = parsed.number {
            title = title.isEmpty ? "#\(number(issue))" : "\(title) #\(number(issue))"
        }
        if let subtitle = parsed.subtitle {
            title = title.isEmpty ? subtitle : "\(title): \(subtitle)"
        }
        return title.isEmpty ? String(localized: "Untitled") : title
    }

    /// "015" reads as 15 and "10.5" stays 10.5, in every locale: the result
    /// is also written to the EPUB as `calibre:series_index`.
    static func number(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(value)
    }

    // MARK: - Patterns

    /// `[...]`, `(...)` or `{...}`, capturing what's inside.
    static var bracketGroup: Regex<(Substring, Substring)> { /[\[\(\{]([^\[\]\(\)\{\}]*)[\]\)\}]/ }
    static var yearPattern: Regex<Substring> { /(?:19|20)\d\d/ }

    /// "v15", "vol 3", "Vol.03", "Volume 2", "Tome 4", and ranges like "v01-v27" or "v1-3".
    /// Not inside a word, so "Love 2" isn't volume 2.
    static var volumePattern: Regex<(Substring, Substring, Substring?)> {
        /(?i)\b(?:v|vol|volume|tome)\.?\s*(\d{1,4}(?:\.\d+)?)(?:[-–](?:v|vol\.?)?(\d{1,4}(?:\.\d+)?))?(?!\d)/
    }

    /// "c003", "ch 12", "Ch.12.5", "Chapter 7".
    static var chapterPattern: Regex<(Substring, Substring)> {
        /(?i)\s*[-–,]?\s*\b(?:c|ch|chap|chapter)\.?\s*(\d{1,4}(?:\.\d+)?)(?!\d)/
    }

    /// "#4", or a zero-padded number such as "004". A plain number is left
    /// alone, so "Catch 22" stays a title.
    static var issuePattern: Regex<(Substring, Substring)> { /(?:#\s*|\b(?=0\d))(\d{1,4}(?:\.\d+)?)(?!\d)/ }

    // MARK: - Helpers

    /// A file name as a title with nothing else changed: no extension, and
    /// underscores as spaces. The title for files with no metadata, and what
    /// "Use File Name" puts back.
    static func plainTitle(fromFileName name: String) -> String {
        let title = stripExtension(name)
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? String(localized: "Untitled") : title
    }

    static func stripExtension(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        guard knownExtensions.contains(ext) else { return name }
        return (name as NSString).deletingPathExtension
    }

    static func stripTrailingTags(_ text: String) -> String {
        var words = text.split(separator: " ").map(String.init)
        while let last = words.last, words.count > 1,
              trailingTags.contains(last.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "-–.,")))
                || last.lowercased().wholeMatch(of: /\d{3,4}p/) != nil {
            words.removeLast()
        }
        return trimSeparators(words.joined(separator: " ")[...])
    }

    static func trimSeparators(_ text: Substring) -> String {
        text.trimmingCharacters(in: CharacterSet(charactersIn: " -–—_.,:;#+~").union(.whitespacesAndNewlines))
    }

    static func collapse(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

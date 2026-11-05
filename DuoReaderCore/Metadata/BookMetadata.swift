import Foundation

/// Everything we could read out of a file on import. Every field is optional
/// because third-party files are often missing most of it.
public struct BookMetadata: Equatable, Sendable {
    public var title: String?
    public var authors: [String] = []
    public var series: String?
    public var seriesIndex: Double?
    public var language: String?
    public var publisher: String?
    public var summary: String?
    public var subjects: [String] = []
    public var identifiers: [String] = []
    /// Raw bytes of the cover image as stored in the file (JPEG, PNG, …).
    public var coverImageData: Data?
    /// Present when the file came from Archive of Our Own.
    public var ao3: AO3Metadata?

    public init() {}
}

/// The extra metadata AO3 puts in its EPUB downloads, read from the work's
/// preface page. Stored on the book so fandoms, ships and tags are searchable.
public struct AO3Metadata: Codable, Equatable, Hashable, Sendable {
    public var workURL: URL?
    public var rating: String?
    public var warnings: [String] = []
    public var categories: [String] = []
    public var fandoms: [String] = []
    public var relationships: [String] = []
    public var characters: [String] = []
    public var additionalTags: [String] = []
    public var wordCount: Int?
    /// e.g. "12/?" or "5/5".
    public var chapters: String?

    public init() {}

    /// True when nothing was found, so callers can drop an empty value.
    public var isEmpty: Bool {
        self == AO3Metadata()
    }
}

/// Reads metadata from one file format.
public protocol MetadataReader: Sendable {
    func readMetadata(from url: URL) async throws -> BookMetadata
}

public enum MetadataError: Error, Equatable {
    /// The file isn't a valid container for its format (bad ZIP, missing OPF, …).
    case malformed(String)
    /// The file is protected and can't be read. DRM is out of scope.
    case drmProtected
}

public enum MetadataReaders {
    /// The reader for a format, or nil when metadata for it isn't supported yet.
    public static func reader(for format: BookFormat) -> (any MetadataReader)? {
        switch format {
        case .epub: return EPUBMetadataReader()
        case .pdf: return PDFMetadataReader()
        default: return nil
        }
    }
}

extension BookMetadata {
    /// A title for files with no metadata: the file name without its extension,
    /// with underscores turned into spaces.
    public static func fallbackTitle(for url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? String(localized: "Untitled") : name
    }
}

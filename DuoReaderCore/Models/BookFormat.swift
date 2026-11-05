import Foundation
import UniformTypeIdentifiers

/// The file formats the library knows about.
///
/// EPUB and PDF are rendered directly. Everything else is converted to EPUB
/// on import (comics to fixed-layout EPUB), so the reader and annotations only
/// ever deal with two formats (see the roadmap, #1).
public enum BookFormat: String, Codable, CaseIterable, Sendable {
    case epub
    case pdf
    case cbz
    case cbr
    case mobi
    case azw3
    case fb2
    case docx
    case txt
    case rtf
    case html
    case markdown

    /// Lowercased file extensions that map to this format.
    public var fileExtensions: [String] {
        switch self {
        case .epub: ["epub"]
        case .pdf: ["pdf"]
        case .cbz: ["cbz"]
        case .cbr: ["cbr"]
        case .mobi: ["mobi", "prc"]
        case .azw3: ["azw3", "azw"]
        case .fb2: ["fb2"]
        case .docx: ["docx"]
        case .txt: ["txt", "text"]
        case .rtf: ["rtf"]
        case .html: ["html", "htm", "xhtml"]
        case .markdown: ["md", "markdown"]
        }
    }

    /// Whether the reader opens this format as-is, without converting it first.
    public var isRenderedNatively: Bool {
        switch self {
        case .epub, .pdf: true
        default: false
        }
    }

    /// Picks a format from a file's extension, ignoring case.
    public init?(fileExtension: String) {
        let ext = fileExtension.lowercased()
        guard let match = Self.allCases.first(where: { $0.fileExtensions.contains(ext) }) else {
            return nil
        }
        self = match
    }

    /// Picks a format from a URL's path extension. `name.fb2.zip` is FictionBook.
    public init?(url: URL) {
        if url.pathExtension.lowercased() == "zip", url.deletingPathExtension().pathExtension.lowercased() == "fb2" {
            self = .fb2
            return
        }
        self.init(fileExtension: url.pathExtension)
    }

    /// Uniform types to offer in the document picker.
    public static var importableTypes: [UTType] {
        allCases
            .flatMap(\.fileExtensions)
            .compactMap { UTType(filenameExtension: $0) }
            .reduce(into: [UTType]()) { types, type in
                if !types.contains(type) { types.append(type) }
            }
    }
}

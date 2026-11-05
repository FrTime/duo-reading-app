import Foundation
import PDFKit
import UIKit

/// Reads the PDF document info dictionary and renders the first page as the cover.
public struct PDFMetadataReader: MetadataReader {
    /// Longest side of the rendered cover, in pixels.
    static let coverMaxPixels: CGFloat = 1200

    public init() {}

    public func readMetadata(from url: URL) throws -> BookMetadata {
        guard let document = PDFDocument(url: url) else {
            throw MetadataError.malformed("Not a PDF")
        }
        if document.isEncrypted && document.isLocked {
            throw MetadataError.drmProtected
        }

        var metadata = BookMetadata()
        let attributes = document.documentAttributes ?? [:]
        metadata.title = (attributes[PDFDocumentAttribute.titleAttribute] as? String)?.nilIfBlank
        if let author = (attributes[PDFDocumentAttribute.authorAttribute] as? String)?.nilIfBlank {
            metadata.authors = Self.splitAuthors(author)
        }
        metadata.summary = (attributes[PDFDocumentAttribute.subjectAttribute] as? String)?.nilIfBlank
        if let keywords = attributes[PDFDocumentAttribute.keywordsAttribute] {
            metadata.subjects = Self.keywords(from: keywords)
        }

        if let page = document.page(at: 0) {
            metadata.coverImageData = Self.renderCover(page)
        }
        return metadata
    }

    /// "A, B & C" or "A; B and C" → ["A", "B", "C"].
    static func splitAuthors(_ value: String) -> [String] {
        value
            .replacingOccurrences(of: " and ", with: ",")
            .replacingOccurrences(of: "&", with: ",")
            .replacingOccurrences(of: ";", with: ",")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// PDFKit returns keywords as either a string or an array of strings.
    static func keywords(from value: Any) -> [String] {
        let raw: [String]
        if let array = value as? [String] {
            raw = array
        } else if let string = value as? String {
            raw = string.split(whereSeparator: { $0 == "," || $0 == ";" }).map(String.init)
        } else {
            raw = []
        }
        return raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.uniqued()
    }

    static func renderCover(_ page: PDFPage) -> Data? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = coverMaxPixels / max(bounds.width, bounds.height)
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let image = page.thumbnail(of: size, for: .mediaBox)
        return image.jpegData(compressionQuality: 0.85)
    }
}

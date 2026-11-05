import Foundation
import Testing
@testable import DuoReader

struct BookFormatTests {
    @Test(arguments: [
        ("epub", BookFormat.epub), ("EPUB", .epub), ("pdf", .pdf), ("cbz", .cbz),
        ("mobi", .mobi), ("prc", .mobi), ("azw3", .azw3), ("fb2", .fb2),
        ("txt", .txt), ("htm", .html), ("md", .markdown), ("docx", .docx),
    ])
    func detectsFormatFromExtension(ext: String, expected: BookFormat) {
        #expect(BookFormat(fileExtension: ext) == expected)
    }

    @Test func unknownExtensionIsNil() {
        #expect(BookFormat(fileExtension: "zip") == nil)
        #expect(BookFormat(fileExtension: "") == nil)
    }

    @Test func detectsFormatFromURL() {
        let url = URL(fileURLWithPath: "/tmp/My Fic (AO3).Epub")
        #expect(BookFormat(url: url) == .epub)
    }

    @Test func onlyEpubPdfAndCbzRenderNatively() {
        let native = BookFormat.allCases.filter(\.isRenderedNatively)
        #expect(Set(native) == [.epub, .pdf, .cbz])
    }

    @Test func extensionsAreUniqueAcrossFormats() {
        let all = BookFormat.allCases.flatMap(\.fileExtensions)
        #expect(all.count == Set(all).count)
    }

    @Test func offersImportableTypes() {
        #expect(BookFormat.importableTypes.contains(.pdf))
        #expect(BookFormat.importableTypes.contains(.epub))
    }
}

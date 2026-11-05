import Foundation
import Testing
@testable import DuoReader

struct PDFMetadataReaderTests {
    let reader = PDFMetadataReader()

    @Test func readsInfoDictionaryAndCover() throws {
        let url = try Fixtures.pdf(title: "A Paper", author: "Ada Writer and Ben Coauthor",
                                   subject: "About things", keywords: ["one", "two", "one"])
        let m = try reader.readMetadata(from: url)
        #expect(m.title == "A Paper")
        #expect(m.authors == ["Ada Writer", "Ben Coauthor"])
        #expect(m.summary == "About things")
        #expect(m.subjects == ["one", "two"])
        let cover = try #require(m.coverImageData)
        #expect(cover.starts(with: [0xFF, 0xD8]))  // JPEG
    }

    @Test func emptyInfoStillGivesCover() throws {
        let url = try Fixtures.pdf()
        let m = try reader.readMetadata(from: url)
        #expect(m.title == nil)
        #expect(m.authors.isEmpty)
        #expect(m.coverImageData != nil)
    }

    @Test func rejectsNonPDF() throws {
        let url = Fixtures.temporaryURL("bad.pdf")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("nope".utf8).write(to: url)
        #expect(throws: MetadataError.malformed("Not a PDF")) { try reader.readMetadata(from: url) }
    }

    @Test(arguments: [
        ("A, B & C", ["A", "B", "C"]),
        ("A; B and C", ["A", "B", "C"]),
        ("Solo", ["Solo"]),
    ])
    func splitsAuthors(input: String, expected: [String]) {
        #expect(PDFMetadataReader.splitAuthors(input) == expected)
    }

    @Test func keywordsFromStringOrArray() {
        #expect(PDFMetadataReader.keywords(from: "a, b; c") == ["a", "b", "c"])
        #expect(PDFMetadataReader.keywords(from: ["x", " y "]) == ["x", "y"])
        #expect(PDFMetadataReader.keywords(from: 42).isEmpty)
    }
}

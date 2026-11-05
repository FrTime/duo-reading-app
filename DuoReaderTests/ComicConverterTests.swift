import Foundation
import ReadiumZIPFoundation
import SwiftData
import Testing
import UIKit
@testable import DuoReader

struct ComicConverterTests {
    /// A solid PNG of the given size, so pages are distinguishable.
    static func png(width: Int, height: Int, color: UIColor) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).pngData { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    /// Writes a plain ZIP (no EPUB extras) with the given entries.
    static func zip(_ files: [(String, Data)], name: String) async throws -> URL {
        let url = Fixtures.temporaryURL(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let archive = try await Archive(url: url, accessMode: .create)
        for (path, data) in files {
            try await archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count),
                                       compressionMethod: .deflate) { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            }
        }
        return url
    }

    static let page1 = png(width: 20, height: 30, color: .red)
    static let page2 = png(width: 22, height: 33, color: .green)
    static let page10 = png(width: 40, height: 30, color: .blue)
    static let comicInfo = Data("""
        <?xml version="1.0"?>
        <ComicInfo><Series>Moss &amp; Stone</Series><Number>3</Number><Writer>Ada Writer, Bo Second</Writer>
        <Summary>Green things.</Summary><LanguageISO>fr</LanguageISO><Manga>YesAndRightToLeft</Manga></ComicInfo>
        """.utf8)

    static func sampleComic(name: String = "moss.cbz") async throws -> URL {
        try await zip([
            ("Moss/page10.png", page10),
            ("Moss/page2.png", page2),
            ("Moss/page1.png", page1),
            ("__MACOSX/Moss/._page1.png", Data("junk".utf8)),
            ("Moss/.hidden.png", Data("junk".utf8)),
            ("Moss/notes.txt", Data("not a page".utf8)),
            ("ComicInfo.xml", comicInfo),
        ], name: name)
    }

    private func convert(_ source: URL) async throws -> URL {
        let output = source.deletingLastPathComponent().appending(path: "out.epub")
        try await ComicConverter().convert(source, to: output)
        return output
    }

    @Test func pagesComeInNaturalOrderWithComicInfoMetadata() async throws {
        let epub = try await convert(try await Self.sampleComic())

        let metadata = try await EPUBMetadataReader().readMetadata(from: epub)
        #expect(metadata.title == "Moss & Stone #3")
        #expect(metadata.authors == ["Ada Writer", "Bo Second"])
        #expect(metadata.series == "Moss & Stone")
        #expect(metadata.seriesIndex == 3)
        #expect(metadata.summary == "Green things.")
        #expect(metadata.language == "fr")
        #expect(metadata.coverImageData == Self.page1)

        let archive = try await Archive(url: epub, accessMode: .read)
        #expect(try await EPUBMetadataReader.data(at: "OEBPS/images/p0001.png", in: archive, limit: .max) == Self.page1)
        #expect(try await EPUBMetadataReader.data(at: "OEBPS/images/p0002.png", in: archive, limit: .max) == Self.page2)
        #expect(try await EPUBMetadataReader.data(at: "OEBPS/images/p0003.png", in: archive, limit: .max) == Self.page10)
        #expect(try await archive.get("OEBPS/images/p0004.png") == nil)

        let opf = String(decoding: try #require(try await EPUBMetadataReader.data(at: "OEBPS/content.opf", in: archive)), as: UTF8.self)
        #expect(opf.contains("pre-paginated"))
        #expect(opf.contains(#"page-progression-direction="rtl""#))
        #expect(opf.range(of: "page-1")!.lowerBound < opf.range(of: "page-3")!.lowerBound)
    }

    @Test func everyPageIsWellFormedAndSizedToItsImage() async throws {
        let epub = try await convert(try await Self.sampleComic())
        let archive = try await Archive(url: epub, accessMode: .read)
        for path in ["OEBPS/content.opf", "OEBPS/nav.xhtml", "OEBPS/pages/p0001.xhtml", "OEBPS/pages/p0003.xhtml"] {
            let data = try #require(try await EPUBMetadataReader.data(at: path, in: archive))
            let parser = XMLParser(data: data)
            #expect(parser.parse(), "\(path) isn't well-formed")
        }
        let page3 = String(decoding: try #require(try await EPUBMetadataReader.data(at: "OEBPS/pages/p0003.xhtml", in: archive)), as: UTF8.self)
        #expect(page3.contains(#"content="width=40, height=30""#))
    }

    @Test func mimetypeIsFirstAndStored() async throws {
        let epub = try await convert(try await Self.sampleComic())
        let archive = try await Archive(url: epub, accessMode: .read)
        let first = try #require(try await archive.entries().first)
        #expect(first.path == "mimetype")
        #expect(first.compressedSize == first.uncompressedSize)
    }

    @Test func titleFallsBackToTheFileName() async throws {
        let source = try await Self.zip([("a.jpg", Self.page1)], name: "Some_Comic.cbz")
        let metadata = try await EPUBMetadataReader().readMetadata(from: try await convert(source))
        #expect(metadata.title == "Some Comic")
    }

    @Test func archivesWithoutImagesAreRejected() async throws {
        let source = try await Self.zip([("readme.txt", Data("hi".utf8))], name: "empty.cbz")
        await #expect(throws: ConversionError.unreadable) { _ = try await convert(source) }

        let notZip = Fixtures.temporaryURL("bad.cbz")
        try FileManager.default.createDirectory(at: notZip.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a zip".utf8).write(to: notZip)
        await #expect(throws: ConversionError.unreadable) { _ = try await convert(notZip) }
    }

    @Test func readsImageSizeFromTheHeader() {
        #expect(ComicConverter.pixelSize(of: Self.page10) == CGSize(width: 40, height: 30))
        #expect(ComicConverter.pixelSize(of: Data("x".utf8)) == CGSize(width: 1000, height: 1500))
    }

    @Test func comicInfoTitleWinsOverSeries() {
        let info = ComicInfo.parse(Data("<ComicInfo><Title>Issue Title</Title><Series>S</Series><Number>1</Number></ComicInfo>".utf8))
        #expect(info.displayTitle == "Issue Title")
        #expect(!info.rightToLeft)
    }
}

@MainActor
struct ComicImportTests {
    @Test func importsACBZWithItsCover() async throws {
        let container = try LibraryStore.makeContainer(inMemory: true)
        let importer = LibraryImporter(modelContainer: container, booksFolder: Fixtures.temporaryURL("Books"))
        let outcome = await importer.importFile(try await ComicConverterTests.sampleComic())
        guard case .imported(_, let title) = outcome else {
            Issue.record("Expected import, got \(outcome)"); return
        }
        #expect(title == "Moss & Stone #3")
        let book = try #require(try container.mainContext.fetch(FetchDescriptor<Book>()).first)
        #expect(book.format == .epub)
        #expect(book.coverImageData != nil)
        #expect(LibraryImporter.supportedFormats.contains(.cbz))
    }
}

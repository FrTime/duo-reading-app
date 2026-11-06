import Foundation
import Testing
import UIKit
@testable import DuoReader

struct SeriesKeyTests {
    @Test func readsTheSeriesOffVolumeTitles() {
        let titles = [
            "Claymore v15 (2009) (Digital) (LostNerevarine-Empire)",
            "Claymore, Vol. 15",
            "Claymore 03",
            "Claymore_v01",
            "claymore volume 2 [Viz]",
            "Claymore #7",
        ]
        for title in titles {
            #expect(SeriesKey.fromTitle(title) == "claymore", "\(title)")
        }
        #expect(SeriesKey.fromTitle("The Expanse Book 2") == "expanse")
        #expect(SeriesKey.fromTitle("One Piece, Vol. 101") == "one piece")
        // A volume word has to stand apart, so it can't eat the end of the name.
        #expect(SeriesKey.fromTitle("Domino 2") == "domino")
        #expect(SeriesKey.fromTitle("Kiev 3") == "kiev")
    }

    @Test func titlesWithoutAVolumeHaveNoSeries() {
        #expect(SeriesKey.fromTitle("All the Young Dudes") == nil)
        #expect(SeriesKey.fromTitle("1984") == nil)
        #expect(SeriesKey.fromTitle("") == nil)
        #expect(SeriesKey.fromTitle("(2009) 12") == nil)
    }

    @Test func metadataSeriesWinsAndIsNormalised() {
        #expect(SeriesKey.key(series: "The Wheel of Time", title: "The Eye of the World") == "wheel of time")
        #expect(SeriesKey.key(series: "Clàymore,", title: "x") == "claymore")
        #expect(SeriesKey.key(series: "  ", title: "Claymore v2") == "claymore")
        // Metadata and a cleaned-up title land on the same key.
        #expect(SeriesKey.key(series: "Claymore", title: "Claymore, Vol. 15") == SeriesKey.fromTitle("Claymore v16"))
    }

    @Test func bookUsesItsSeriesOrTitle() {
        let book = Book(relativeFilePath: "a", contentHash: "a", format: .epub, title: "Claymore v04")
        #expect(book.seriesKey == "claymore")
        book.series = "Claymore"
        book.title = "Silver-eyed Slayer"
        #expect(book.seriesKey == "claymore")
    }
}

struct SeriesSizeTests {
    @Test func booksInASeriesShareADefaultSize() {
        let scales = Set((0..<20).map { _ in CoverDesign.defaultHeightScale(for: UUID(), seriesKey: "claymore") })
        #expect(scales.count == 1)
        let scale = scales.first!
        #expect(scale >= 0.93 - 1e-9 && scale <= 1.05 + 1e-9)
    }

    @Test func differentSeriesUsuallyDiffer() {
        let scales = Set(["claymore", "berserk", "one piece", "naruto", "bleach", "monster"].map {
            CoverDesign.defaultHeightScale(for: UUID(), seriesKey: $0)
        })
        #expect(scales.count > 3)
    }

    @Test func noSeriesFallsBackToTheBook() {
        let id = UUID()
        #expect(CoverDesign.defaultHeightScale(for: id, seriesKey: nil) == CoverDesign.defaultHeightScale(for: id))
        #expect(CoverDesign.defaultHeightScale(for: id, seriesKey: "") == CoverDesign.defaultHeightScale(for: id))
    }

    @Test func theUsersSizeStillWins() {
        var design = CoverTemplate.classic.makeDesign(seed: CoverFixtures.seed(), palette: .generated(for: "x"), imageSource: .embedded)
        design.heightScale = 1.1
        #expect(design.sizeScale(for: UUID(), seriesKey: "claymore") == 1.1)
    }
}

struct ThicknessTests {
    @Test func growsWithLengthAndNeverHitsTheCeilingEarly() {
        let pages = [8, 50, 200, 300, 600, 900, 1500, 3000]
        let values = pages.map(CoverDesign.thickness(forPageCount:))
        for (a, b) in zip(values, values.dropFirst()) {
            #expect(b > a)
        }
        #expect(abs(CoverDesign.thickness(forPageCount: 600) - 0.22) < 1e-9)
        #expect(CoverDesign.thickness(forPageCount: 3000) < CoverDesign.thicknessRange.upperBound)
    }

    @Test func seedUsesWordsThenPagesThenADefault() {
        var seed = CoverFixtures.seed()
        #expect(seed.estimatedPageCount == 300)
        seed.pageCount = 180
        #expect(seed.estimatedPageCount == 180)
        seed.wordCount = 27_500
        #expect(seed.estimatedPageCount == 100)
    }

    @Test func measuredLengthChangesTheFingerprint() {
        var seed = CoverFixtures.seed()
        let before = seed.fingerprint
        seed.pageCount = 200
        #expect(seed.fingerprint != before)
    }

    @Test func legacyDesignsFollowLengthOnlyAtTheOldDefault() {
        let seed = CoverFixtures.seed()
        var design = CoverTemplate.classic.makeDesign(seed: seed, palette: .generated(for: "x"), imageSource: .none)
        #expect(design.isThicknessCustom == nil)
        #expect(design.followsBookLength(seed: seed))
        design.thickness = 0.2
        #expect(!design.followsBookLength(seed: seed))
        design.isThicknessCustom = false
        #expect(design.followsBookLength(seed: seed))
        design.isThicknessCustom = true
        #expect(!design.followsBookLength(seed: seed))
    }
}

struct BookLengthTests {
    func opf(spine count: Int, fixed: Bool) -> Data {
        let items = (0..<count).map { "<item id=\"p\($0)\" href=\"p\($0).xhtml\" media-type=\"application/xhtml+xml\"/>" }.joined()
        let refs = (0..<count).map { "<itemref idref=\"p\($0)\"/>" }.joined()
        let layout = fixed ? "<meta property=\"rendition:layout\">pre-paginated</meta>" : ""
        return Data("""
        <?xml version="1.0"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>T</dc:title>\(layout)</metadata>
          <manifest>\(items)</manifest>
          <spine>\(refs)</spine>
        </package>
        """.utf8)
    }

    func page(words: Int) -> Data {
        let body = Array(repeating: "word", count: words).joined(separator: " ")
        return Data("<html><head><title>Chapter title here</title></head><body><p class=\"x\">\(body)</p></body></html>".utf8)
    }

    @Test func fixedLayoutCountsSpinePages() async throws {
        var files = ["OEBPS/content.opf": opf(spine: 24, fixed: true)]
        for i in 0..<24 { files["OEBPS/p\(i).xhtml"] = Data("<html><body><img src=\"a.jpg\"/></body></html>".utf8) }
        let url = try await Fixtures.epub(files)
        #expect(await BookLength.pageCount(of: url, format: .epub) == 24)
    }

    @Test func reflowableCountsWords() async throws {
        var files = ["OEBPS/content.opf": opf(spine: 3, fixed: false)]
        for i in 0..<3 { files["OEBPS/p\(i).xhtml"] = page(words: 27_500) }
        let url = try await Fixtures.epub(files)
        // 82,500 words of text plus 3 title words each, at 275 a page.
        #expect(await BookLength.pageCount(of: url, format: .epub) == 300)
    }

    @Test func countsWordsOutsideTags() {
        var count = BookLength.TextCount()
        count.add(markup: Data("<p class=\"a b c\">One two</p><br/>three\nfour<span>five</span>".utf8))
        #expect(count.words == 5)
    }

    @Test func countsPDFPages() async throws {
        let url = Fixtures.temporaryURL("pages.pdf")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 100, height: 150)).writePDF(to: url) { context in
            for _ in 0..<7 { context.beginPage() }
        }
        #expect(await BookLength.pageCount(of: url, format: .pdf) == 7)
    }

    @Test func unreadableFilesHaveNoLength() async {
        let missing = Fixtures.temporaryURL("missing.epub")
        #expect(await BookLength.pageCount(of: missing, format: .epub) == nil)
        #expect(await BookLength.pageCount(of: missing, format: .pdf) == nil)
    }

    @Test func cachesTheMeasurement() async throws {
        let files = ["OEBPS/content.opf": opf(spine: 5, fixed: true)]
        let url = try await Fixtures.epub(files)
        let cache = Fixtures.temporaryURL("pages")
        #expect(await BookLength.cachedPageCount(of: url, format: .epub, cache: cache) == 5)
        let stamp = try #require(BookLength.fileStamp(of: url))
        // Later reads come from the cache.
        try Data("\(BookLength.cacheVersion):\(stamp):42".utf8).write(to: cache)
        #expect(await BookLength.cachedPageCount(of: url, format: .epub, cache: cache) == 42)
        // A different file (size or date) is measured again.
        try Data("\(BookLength.cacheVersion):1-1:42".utf8).write(to: cache)
        #expect(await BookLength.cachedPageCount(of: url, format: .epub, cache: cache) == 5)
        #expect(BookLength.parseCache("0:\(stamp):5", stamp: stamp) == nil)
        #expect(BookLength.parseCache("garbage", stamp: stamp) == nil)
    }

    @Test func doesNotCacheAMissingFile() async {
        let missing = Fixtures.temporaryURL("missing.epub")
        let cache = Fixtures.temporaryURL("pages")
        #expect(await BookLength.cachedPageCount(of: missing, format: .epub, cache: cache) == nil)
        #expect(!FileManager.default.fileExists(atPath: cache.path()))
    }
}

struct LengthOnEditedCoversTests {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "LengthCoverTests-\(UUID().uuidString)", directoryHint: .isDirectory)

    @Test func automaticCoversRebuildWithTheMeasuredLength() async {
        let store = CoverStore(root: root, renderer: CoverRenderer(frontWidth: 120))
        var seed = CoverFixtures.seed()
        let first = await store.prepare(seed)
        #expect(abs(first.thickness - 0.12) < 1e-9)
        seed.pageCount = 180
        let rebuilt = await store.prepare(seed)
        #expect(abs(rebuilt.thickness - CoverDesign.thickness(forPageCount: 180)) < 1e-9)
    }

    @Test func editedCoversFollowLengthUnlessResized() async throws {
        let store = CoverStore(root: root, renderer: CoverRenderer(frontWidth: 120))
        var seed = CoverFixtures.seed()
        var design = await store.prepare(seed)
        design.textBoxes.removeAll()
        try await store.save(design, image: .keep, for: seed.bookID)

        seed.pageCount = 900
        let followed = await store.prepare(seed)
        #expect(followed.isUserEdited)
        #expect(followed.textBoxes.isEmpty)
        #expect(abs(followed.thickness - CoverDesign.thickness(forPageCount: 900)) < 1e-9)
        #expect(followed.isThicknessCustom == false)

        var resized = followed
        resized.thickness = 0.05
        resized.isThicknessCustom = true
        try await store.save(resized, image: .keep, for: seed.bookID)
        seed.pageCount = 100
        let kept = await store.prepare(seed)
        #expect(abs(kept.thickness - 0.05) < 1e-9)
    }
}

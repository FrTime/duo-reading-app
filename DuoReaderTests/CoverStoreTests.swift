import Foundation
import Testing
import UIKit
@testable import DuoReader

struct CoverStoreTests {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "CoverStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)

    var store: CoverStore { CoverStore(root: root, renderer: CoverRenderer(frontWidth: 120)) }

    func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path())
    }

    @Test func buildsADefaultFromTheEmbeddedCover() async throws {
        let store = store
        let seed = CoverFixtures.seed(cover: CoverFixtures.jpeg(color: .blue))
        let design = await store.prepare(seed)

        #expect(design.template == .classic)
        #expect(design.imageSource == .embedded)
        #expect(!design.isUserEdited)
        #expect(design.baseColor.blue > 0.7)
        for face in CoverFace.allCases {
            #expect(exists(store.renderedURL(face, for: seed.bookID)))
        }
        #expect(await store.sourceImageData(for: seed.bookID) == seed.embeddedCoverData)
    }

    @Test func buildsATypographicCoverWithoutArtwork() async {
        let store = store
        let seed = CoverFixtures.seed()
        let design = await store.prepare(seed)
        #expect(design.template == .typographic)
        #expect(design.imageSource == CoverImageSource.none)
        #expect(await store.sourceImageData(for: seed.bookID) == nil)
    }

    @Test func treatsUnreadableArtworkAsNone() async {
        let seed = CoverFixtures.seed(cover: Data("not an image".utf8))
        let design = await store.prepare(seed)
        #expect(design.imageSource == CoverImageSource.none)
    }

    @Test func preparingTwiceKeepsTheDesign() async {
        let store = store
        let seed = CoverFixtures.seed()
        let first = await store.prepare(seed)
        let second = await store.prepare(seed)
        #expect(first == second)
    }

    @Test func rebuildsAutomaticCoversWhenMetadataChanges() async {
        let store = store
        var seed = CoverFixtures.seed()
        _ = await store.prepare(seed)
        seed.embeddedCoverData = CoverFixtures.jpeg()
        let rebuilt = await store.prepare(seed)
        #expect(rebuilt.imageSource == .embedded)
    }

    @Test func keepsUserEditsWhenMetadataChanges() async throws {
        let store = store
        var seed = CoverFixtures.seed()
        var design = await store.prepare(seed)
        design.thickness = 0.3
        try await store.save(design, image: .keep, for: seed.bookID)

        seed.title = "Renamed"
        seed.embeddedCoverData = CoverFixtures.jpeg()
        let after = await store.prepare(seed)
        #expect(after.isUserEdited)
        #expect(after.thickness == 0.3)
        #expect(after.imageSource == CoverImageSource.none)
    }

    @Test func savingANewImage() async throws {
        let store = store
        let seed = CoverFixtures.seed()
        var design = await store.prepare(seed)
        design.imageSource = .userImage
        let rendered = try await store.save(design, image: .replace(CoverFixtures.jpeg(color: .green)), for: seed.bookID)
        #expect(rendered.front.size.width == 120)
        #expect(await store.design(for: seed.bookID)?.imageSource == .userImage)
        #expect(await store.sourceImageData(for: seed.bookID) != nil)

        try await store.save(design, image: .remove, for: seed.bookID)
        #expect(await store.sourceImageData(for: seed.bookID) == nil)
        #expect(await store.design(for: seed.bookID)?.imageSource == CoverImageSource.none)
    }

    @Test func rejectsAnUnreadableImage() async {
        let store = store
        let seed = CoverFixtures.seed()
        let design = await store.prepare(seed)
        await #expect(throws: CoverStoreError.unreadableImage) {
            try await store.save(design, image: .replace(Data("junk".utf8)), for: seed.bookID)
        }
    }

    @Test func resetGoesBackToTheDefault() async throws {
        let store = store
        let seed = CoverFixtures.seed()
        var design = await store.prepare(seed)
        design.template = .minimal
        try await store.save(design, image: .keep, for: seed.bookID)
        let reset = await store.reset(seed)
        #expect(!reset.isUserEdited)
        #expect(reset.template == .typographic)
    }

    @Test func redrawsMissingFaces() async throws {
        let store = store
        let seed = CoverFixtures.seed()
        _ = await store.prepare(seed)
        try FileManager.default.removeItem(at: store.renderedURL(.spine, for: seed.bookID))
        _ = await store.prepare(seed)
        #expect(exists(store.renderedURL(.spine, for: seed.bookID)))
    }

    @Test func deleteRemovesTheFolder() async {
        let store = store
        let seed = CoverFixtures.seed()
        _ = await store.prepare(seed)
        await store.delete(seed.bookID)
        #expect(!exists(store.folder(for: seed.bookID)))
        #expect(await store.design(for: seed.bookID) == nil)
    }

    @Test func decodesLargeImagesSmall() throws {
        let data = CoverFixtures.jpeg(width: 1000, height: 1500)
        let image = try #require(CoverStore.decodeImage(data, maxPixels: 300))
        #expect(max(image.size.width, image.size.height) <= 300)
    }
}

@MainActor
struct CoverLibraryTests {
    @Test func bumpsTheRevisionOnSave() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "CoverLibraryTests-\(UUID().uuidString)")
        let library = CoverLibrary(store: CoverStore(root: root, renderer: CoverRenderer(frontWidth: 90)))
        let book = Book(relativeFilePath: "x", contentHash: "x", format: .epub, title: "Hello")

        let front = await library.frontCover(for: book)
        #expect(front.size.width == 90)
        #expect(library.revision(for: book.id) == 0)

        var design = await library.design(for: book)
        design.template = .minimal
        try await library.save(design, image: .keep, for: book)
        #expect(library.revision(for: book.id) == 1)
        #expect(await library.design(for: book).isUserEdited)

        let small = await library.image(.front, for: book, maxPixels: 30)
        #expect(max(small.size.width, small.size.height) <= 30)

        await library.deleteCovers(for: book.id)
        #expect(library.revision(for: book.id) == 2)
    }
}

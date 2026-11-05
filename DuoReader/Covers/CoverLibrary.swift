import Observation
import SwiftUI
import UIKit

/// The app's one way to get a book's cover, for the shelf, the cover editor
/// and the outer display.
///
/// Every book always has a cover: the one the user designed, else the file's
/// own artwork, else a generated typographic cover. Views read
/// `revision(for:)` so they redraw when a cover is saved.
@MainActor
@Observable
final class CoverLibrary {
    static let shared = CoverLibrary(store: CoverStore(root: CoverStore.defaultRoot()))

    private let store: CoverStore
    private var revisions: [UUID: Int] = [:]
    private let images = NSCache<NSString, UIImage>()
    @ObservationIgnored private var designs: [UUID: CoverDesign] = [:]

    init(store: CoverStore) {
        self.store = store
        images.countLimit = 300
    }

    /// Goes up by one each time a book's cover changes.
    func revision(for bookID: UUID) -> Int {
        revisions[bookID, default: 0]
    }

    /// The book's current design, building the default the first time.
    ///
    /// Reading a book's metadata (including its cover bytes) costs a disk
    /// read, so after the first check this session the cached design is used.
    /// Call `metadataDidChange(for:)` after re-importing a book.
    func design(for book: Book) async -> CoverDesign {
        if let cached = designs[book.id] { return cached }
        let design = await store.prepare(book.coverSeed)
        designs[book.id] = design
        return design
    }

    /// Rebuilds an automatic cover from the book's current metadata. Covers
    /// the user edited aren't touched.
    func metadataDidChange(for book: Book) async {
        let previous = designs[book.id]
        let design = await store.prepare(book.coverSeed)
        designs[book.id] = design
        if previous != design { bump(book.id) }
    }

    /// The front cover, at 2:3. `pixelWidth` caps the size (the full render
    /// is `CoverRenderer.defaultFrontWidth`, 1400 px, enough for the outer display).
    func frontCover(for book: Book, pixelWidth: CGFloat? = nil) async -> UIImage {
        let maxPixels = pixelWidth.map { Int(($0 / CoverDesign.frontAspectRatio).rounded(.up)) }
        return await image(.front, for: book, maxPixels: maxPixels)
    }

    /// One face of the cover, no larger than `maxPixels` on its longest side.
    /// Shelf textures ask for small sizes; nil gives the full render.
    func image(_ face: CoverFace, for book: Book, maxPixels: Int? = nil) async -> UIImage {
        let id = book.id
        let key = "\(id.uuidString)-\(face.rawValue)-\(maxPixels ?? 0)-\(revision(for: id))" as NSString
        if let cached = images.object(forKey: key) { return cached }

        let design = await design(for: book)
        let url = store.renderedURL(face, for: id)
        let limit = maxPixels ?? Int.max
        let loaded = await Task.detached(priority: .userInitiated) {
            CoverStore.loadImage(at: url, maxPixels: min(limit, 4096))
        }.value
        let image = loaded ?? Self.placeholder(face, design: design)
        images.setObject(image, forKey: key)
        return image
    }

    /// The colour to show around the cover where it doesn't fill a screen,
    /// such as the outer display's slightly wider panel.
    func backgroundColor(for book: Book) async -> Color {
        let base = await design(for: book).baseColor
        return Color(cgColor: base.cgColor)
    }

    /// Saves an edited design and tells every view showing the cover.
    func save(_ design: CoverDesign, image: CoverStore.ImageChange, for book: Book) async throws {
        let id = book.id
        _ = try await store.save(design, image: image, for: id)
        designs[id] = await store.design(for: id)
        bump(id)
    }

    /// Throws away the user's edits and goes back to the default cover.
    func resetToDefault(for book: Book) async {
        let design = await store.reset(book.coverSeed)
        designs[book.id] = design
        bump(book.id)
    }

    /// The image the user picked for the front, as they picked it.
    func sourceImageData(for book: Book) async -> Data? {
        await store.sourceImageData(for: book.id)
    }

    /// Removes a book's cover files. Call when the book is deleted.
    func deleteCovers(for bookID: UUID) async {
        await store.delete(bookID)
        designs[bookID] = nil
        bump(bookID)
    }

    private func bump(_ bookID: UUID) {
        revisions[bookID, default: 0] += 1
    }

    /// Drawn on the spot if the rendered file is missing (say the disk was full).
    private static func placeholder(_ face: CoverFace, design: CoverDesign) -> UIImage {
        CoverRenderer(frontWidth: 400).render(face, design: design, image: nil)
    }
}

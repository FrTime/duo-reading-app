import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Saves cover designs and their rendered faces on disk, and builds a default
/// cover for books that don't have one yet.
///
/// Each book gets a folder named after its ID:
///
///     Covers/<book id>/design.json   the design
///     Covers/<book id>/source.img    the front image as the user chose it
///     Covers/<book id>/front.jpg     rendered faces
///     Covers/<book id>/spine.jpg
///     Covers/<book id>/back.jpg
///     Covers/<book id>/pages         the book's measured length (`BookLength`)
///
/// Designs live beside the library store rather than in it, so cover work
/// never needs a schema change and big images stay out of library queries.
/// The actor serialises rendering, which keeps memory flat when a large
/// library asks for many covers at once.
public actor CoverStore {
    /// What to do with the stored front image when saving.
    public enum ImageChange: Sendable {
        case keep
        case replace(Data)
        case remove
    }

    public nonisolated let root: URL
    private let renderer: CoverRenderer
    /// Largest side, in pixels, that a source image is decoded at.
    static let maxSourcePixels = 2400
    static let jpegQuality: CGFloat = 0.9

    public init(root: URL, renderer: CoverRenderer = CoverRenderer()) {
        self.root = root
        self.renderer = renderer
    }

    /// `Application Support/Covers`.
    public static func defaultRoot() -> URL {
        URL.applicationSupportDirectory.appending(path: "Covers", directoryHint: .isDirectory)
    }

    // MARK: - Paths

    public nonisolated func folder(for bookID: UUID) -> URL {
        root.appending(path: bookID.uuidString, directoryHint: .isDirectory)
    }

    public nonisolated func renderedURL(_ face: CoverFace, for bookID: UUID) -> URL {
        folder(for: bookID).appending(path: "\(face.rawValue).jpg")
    }

    nonisolated func designURL(for bookID: UUID) -> URL {
        folder(for: bookID).appending(path: "design.json")
    }

    /// Where the book's measured page count is cached. It lives with the
    /// cover so deleting the book's covers removes it too.
    public nonisolated func pageCountURL(for bookID: UUID) -> URL {
        folder(for: bookID).appending(path: "pages")
    }

    nonisolated func sourceURL(for bookID: UUID) -> URL {
        folder(for: bookID).appending(path: "source.img")
    }

    // MARK: - Reading

    /// The saved design, or nil if the book has none (or it can't be read).
    public func design(for bookID: UUID) -> CoverDesign? {
        guard let data = try? Data(contentsOf: designURL(for: bookID)) else { return nil }
        return try? JSONDecoder().decode(CoverDesign.self, from: data)
    }

    public func sourceImageData(for bookID: UUID) -> Data? {
        try? Data(contentsOf: sourceURL(for: bookID))
    }

    private func hasRenderedFaces(for bookID: UUID) -> Bool {
        CoverFace.allCases.allSatisfy { FileManager.default.fileExists(atPath: renderedURL($0, for: bookID).path()) }
    }

    // MARK: - Preparing

    /// Makes sure the book has a design and rendered faces, building the
    /// default cover the first time, and returns the design.
    ///
    /// Automatic designs are rebuilt when the book's metadata changes (say a
    /// cover turned up on re-import) or the templates' layout improves
    /// (`CoverDesign.currentVersion`). Designs the user edited are left alone.
    @discardableResult
    public func prepare(_ seed: CoverSeed) -> CoverDesign {
        if var existing = design(for: seed.bookID), existing.isUserEdited, seed.pageCount != nil || seed.wordCount != nil,
           existing.followsBookLength(seed: seed) {
            // An edited cover whose spine the user never resized keeps up
            // with the book's measured length.
            let thickness = CoverDesign.thickness(for: seed)
            if abs(existing.thickness - thickness) > 1e-6 || existing.isThicknessCustom == nil {
                existing.thickness = thickness
                existing.isThicknessCustom = false
                let image = sourceImageData(for: seed.bookID).flatMap { Self.decodeImage($0, maxPixels: Self.maxSourcePixels) }
                try? write(design: existing, image: .keep, rendered: renderer.render(design: existing, image: image), for: seed.bookID)
                return existing
            }
        }
        if var existing = design(for: seed.bookID), existing.isUserEdited,
           existing.thickness < CoverDesign.thicknessRange.lowerBound - 1e-9 {
            // A spine the user made thinner than today's minimum is widened
            // to it, so its title stays legible.
            existing.thickness = existing.clampedThickness
            let image = sourceImageData(for: seed.bookID).flatMap { Self.decodeImage($0, maxPixels: Self.maxSourcePixels) }
            try? write(design: existing, image: .keep, rendered: renderer.render(design: existing, image: image), for: seed.bookID)
            return existing
        }
        if let existing = design(for: seed.bookID),
           existing.isUserEdited
            || (existing.seedFingerprint == seed.fingerprint && existing.version >= CoverDesign.currentVersion) {
            if !hasRenderedFaces(for: seed.bookID) {
                let image = sourceImageData(for: seed.bookID).flatMap { Self.decodeImage($0, maxPixels: Self.maxSourcePixels) }
                try? writeRendered(renderer.render(design: existing, image: image), for: seed.bookID)
            }
            return existing
        }

        let image = seed.embeddedCoverData.flatMap { Self.decodeImage($0, maxPixels: Self.maxSourcePixels) }
        let design = Self.defaultDesign(for: seed, image: image)
        do {
            try write(
                design: design,
                image: image == nil ? .remove : .replace(seed.embeddedCoverData ?? Data()),
                rendered: renderer.render(design: design, image: image),
                for: seed.bookID
            )
        } catch {
            // The cover is drawn again next time; nothing else depends on it.
        }
        return design
    }

    /// The cover a book gets before anyone edits it: the file's own artwork
    /// with the Classic template, or a typographic cover when there's none.
    public static func defaultDesign(for seed: CoverSeed, image: UIImage?) -> CoverDesign {
        let palette = image?.cgImage.flatMap(ColorSampler.palette) ?? .generated(for: seed.title)
        let template = CoverTemplate.defaultTemplate(hasImage: image != nil)
        var design = template.makeDesign(seed: seed, palette: palette, imageSource: image == nil ? .none : .embedded)
        design.seedFingerprint = seed.fingerprint
        return design
    }

    // MARK: - Saving

    /// Saves a design the user edited and renders it. Returns the new faces.
    @discardableResult
    public func save(_ design: CoverDesign, image change: ImageChange, for bookID: UUID) throws -> RenderedCover {
        var design = design
        design.isUserEdited = true
        design.version = CoverDesign.currentVersion

        let imageData: Data? = switch change {
        case .keep: sourceImageData(for: bookID)
        case .replace(let data): data
        case .remove: nil
        }
        let image = imageData.flatMap { Self.decodeImage($0, maxPixels: Self.maxSourcePixels) }
        if case .replace = change, image == nil {
            throw CoverStoreError.unreadableImage
        }
        if image == nil { design.imageSource = .none }

        let rendered = renderer.render(design: design, image: image)
        try write(design: design, image: change, rendered: rendered, for: bookID)
        return rendered
    }

    /// Throws away the user's design so the default is built again.
    public func reset(_ seed: CoverSeed) -> CoverDesign {
        delete(seed.bookID)
        return prepare(seed)
    }

    public func delete(_ bookID: UUID) {
        try? FileManager.default.removeItem(at: folder(for: bookID))
    }

    private func write(design: CoverDesign, image change: ImageChange, rendered: RenderedCover, for bookID: UUID) throws {
        try FileManager.default.createDirectory(at: folder(for: bookID), withIntermediateDirectories: true)
        switch change {
        case .keep: break
        case .replace(let data): try data.write(to: sourceURL(for: bookID), options: Self.writeOptions)
        case .remove: try? FileManager.default.removeItem(at: sourceURL(for: bookID))
        }
        try writeRendered(rendered, for: bookID)
        // The design goes last, so a design on disk always has its faces.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(design).write(to: designURL(for: bookID), options: Self.writeOptions)
    }

    private func writeRendered(_ rendered: RenderedCover, for bookID: UUID) throws {
        try FileManager.default.createDirectory(at: folder(for: bookID), withIntermediateDirectories: true)
        for face in CoverFace.allCases {
            guard let data = rendered.image(for: face).jpegData(compressionQuality: Self.jpegQuality) else {
                throw CoverStoreError.renderFailed
            }
            try data.write(to: renderedURL(face, for: bookID), options: Self.writeOptions)
        }
    }

    private static let writeOptions: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]

    // MARK: - Images

    /// Decodes image data no larger than `maxPixels` on its longest side,
    /// without first inflating the full-size image.
    public static func decodeImage(_ data: Data, maxPixels: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return thumbnail(from: source, maxPixels: maxPixels)
    }

    /// Loads an image file at no more than `maxPixels` on its longest side.
    public static func loadImage(at url: URL, maxPixels: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return thumbnail(from: source, maxPixels: maxPixels)
    }

    private static func thumbnail(from source: CGImageSource, maxPixels: Int) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(maxPixels, 1),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}

public enum CoverStoreError: Error, Equatable {
    case unreadableImage
    case renderFailed
}

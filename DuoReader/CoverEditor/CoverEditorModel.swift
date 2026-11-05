import Observation
import SwiftUI
import UIKit

/// Everything the cover editor is working on, kept apart from the views so
/// edits, undo of the whole session (Cancel) and saving are in one place.
@MainActor
@Observable
final class CoverEditorModel {
    enum Panel: String, CaseIterable, Identifiable {
        case image
        case template
        case text
        case book

        var id: String { rawValue }

        var title: String {
            switch self {
            case .image: String(localized: "Image")
            case .template: String(localized: "Template")
            case .text: String(localized: "Text")
            case .book: String(localized: "Book")
            }
        }

        var systemImage: String {
            switch self {
            case .image: "photo"
            case .template: "square.grid.2x2"
            case .text: "textformat"
            case .book: "book.closed"
            }
        }
    }

    /// What the canvas shows: one face, or the whole book in 3D.
    enum Stage: Hashable {
        case face(CoverFace)
        case threeD
    }

    let book: Book
    let seed: CoverSeed
    private let covers: CoverLibrary
    /// Preview width for the front and back; the spine follows the thickness.
    nonisolated static let previewWidth: CGFloat = 600

    private(set) var isLoaded = false
    /// The design being edited. Views call `designDidChange()` when it changes.
    var design: CoverDesign
    private(set) var image: UIImage?
    private(set) var imageChange: CoverStore.ImageChange = .keep
    private var palette: CoverPalette
    private(set) var rendered: RenderedCover?
    /// Goes up each time `rendered` changes.
    private(set) var renderRevision = 0
    private var savedDesign: CoverDesign?

    var stage: Stage = .face(.front)
    var panel: Panel = .image
    var selectedBoxID: UUID?
    var errorMessage: String?
    private(set) var isSaving = false

    @ObservationIgnored private var renderTask: Task<Void, Never>?

    init(book: Book, covers: CoverLibrary = .shared) {
        self.book = book
        self.seed = book.coverSeed
        self.covers = covers
        self.palette = .generated(for: book.title)
        // A stand-in until `load()` reads the saved design.
        self.design = CoverTemplate.typographic.makeDesign(seed: book.coverSeed, palette: .generated(for: book.title), imageSource: .none)
    }

    var face: CoverFace? {
        if case .face(let face) = stage { face } else { nil }
    }

    var hasChanges: Bool {
        guard let savedDesign else { return false }
        if case .keep = imageChange { return design != savedDesign }
        return true
    }

    var hasEmbeddedCover: Bool { seed.embeddedCoverData != nil }

    var selectedBox: CoverTextBox? {
        guard let selectedBoxID else { return nil }
        return design.textBoxes.first { $0.id == selectedBoxID }
    }

    // MARK: - Loading

    func load() async {
        guard !isLoaded else { return }
        let design = await covers.design(for: book)
        if let data = await covers.sourceImageData(for: book) {
            image = await Self.decode(data)
        }
        if let image, let sampled = image.cgImage.flatMap(ColorSampler.palette) {
            palette = sampled
        }
        savedDesign = design
        self.design = design
        isLoaded = true
        scheduleRender(immediately: true)
    }

    // MARK: - Image

    /// Uses new artwork for the front. Colours are re-sampled from it; text
    /// and layout stay as they are.
    func setImage(_ data: Data, source: CoverImageSource) async {
        guard let decoded = await Self.decode(data) else {
            errorMessage = String(localized: "That image couldn't be opened.")
            return
        }
        image = decoded
        imageChange = .replace(data)
        palette = decoded.cgImage.flatMap(ColorSampler.palette) ?? .generated(for: seed.title)
        var updated = design
        updated.imageSource = source
        updated.imageZoom = 1
        updated.imageOffsetX = 0
        updated.imageOffsetY = 0
        // Art far from a book's shape (wide fan art, say) is fitted whole
        // rather than cropped hard; the user can switch it back.
        updated.fitsWholeImage = Self.prefersFitting(decoded.size) ? true : nil
        // "Text only" never shows art, so switch to one that does.
        let template = updated.template.showsImageOnFront ? updated.template : .classic
        design = template.apply(to: updated, seed: seed, palette: palette)
    }

    /// True when cropping to the front would lose more than about a third
    /// of the image.
    nonisolated static func prefersFitting(_ size: CGSize) -> Bool {
        guard size.width > 0, size.height > 0 else { return false }
        let aspect = size.width / size.height
        let front = CoverDesign.frontAspectRatio
        return max(aspect / front, front / aspect) > 1.5
    }

    func useEmbeddedCover() async {
        guard let data = seed.embeddedCoverData else { return }
        await setImage(data, source: .embedded)
    }

    func removeImage() {
        image = nil
        imageChange = .remove
        palette = .generated(for: seed.title)
        var updated = design
        updated.imageSource = .none
        let template = updated.template == .classic ? CoverTemplate.typographic : updated.template
        design = template.apply(to: updated, seed: seed, palette: palette)
    }

    func resetCrop() {
        design.imageZoom = 1
        design.imageOffsetX = 0
        design.imageOffsetY = 0
    }

    // MARK: - Templates

    func apply(_ template: CoverTemplate) {
        design = template.apply(to: design, seed: seed, palette: palette)
        selectedBoxID = nil
    }

    /// A small render of the current design in another template, for the picker.
    func thumbnail(for template: CoverTemplate) async -> UIImage {
        let design = template.apply(to: design, seed: seed, palette: palette)
        let image = image
        return await Task.detached(priority: .utility) {
            CoverRenderer(frontWidth: 120).render(.front, design: design, image: image)
        }.value
    }

    // MARK: - Text

    func addTextBox(on face: CoverFace) {
        let isSpine = face == .spine
        let ink = color(of: face).contrastingText
        var box = CoverTextBox(
            face: face,
            role: .custom,
            text: String(localized: "New text"),
            centerY: isSpine ? 0.5 : 0.5,
            width: isSpine ? 0.8 : 0.7,
            height: isSpine ? 0.3 : 0.1,
            font: .serif,
            fontSize: isSpine ? min(0.05, design.thickness * 0.5) : 0.06,
            color: ink,
            isVertical: isSpine
        )
        box.clamp()
        design.textBoxes.append(box)
        selectedBoxID = box.id
        stage = .face(face)
        panel = .text
    }

    func update(_ id: UUID, _ change: (inout CoverTextBox) -> Void) {
        guard let index = design.textBoxes.firstIndex(where: { $0.id == id }) else { return }
        var box = design.textBoxes[index]
        change(&box)
        box.clamp()
        design.textBoxes[index] = box
    }

    func deleteTextBox(_ id: UUID) {
        design.textBoxes.removeAll { $0.id == id }
        if selectedBoxID == id { selectedBoxID = nil }
    }

    /// Recolours a face. Text that was in the automatic readable colour
    /// follows, so it stays legible; text the user coloured is left alone.
    func setColor(_ color: RGBAColor, of face: CoverFace) {
        let old = self.color(of: face)
        var updated = design
        switch face {
        case .front: updated.baseColor = color
        case .spine: updated.spineColor = color
        case .back: updated.backColor = color
        }
        for index in updated.textBoxes.indices where updated.textBoxes[index].face == face {
            if updated.textBoxes[index].color == old.contrastingText {
                updated.textBoxes[index].color = color.contrastingText
            }
        }
        design = updated
    }

    /// The background colour of a face, for picking readable text.
    func color(of face: CoverFace) -> RGBAColor {
        switch face {
        case .front: design.baseColor
        case .spine: design.spineColor
        case .back: design.backColor
        }
    }

    // MARK: - Rendering

    /// Redraws the preview after an edit.
    func designDidChange() {
        scheduleRender()
    }

    private func scheduleRender(immediately: Bool = false) {
        renderTask?.cancel()
        let design = design
        let image = image
        renderTask = Task { [weak self] in
            if !immediately {
                // Coalesce bursts of edits, like dragging a slider.
                try? await Task.sleep(for: .milliseconds(40))
                guard !Task.isCancelled else { return }
            }
            let rendered = await Task.detached(priority: .userInitiated) {
                CoverRenderer(frontWidth: CoverEditorModel.previewWidth).render(design: design, image: image)
            }.value
            guard !Task.isCancelled else { return }
            self?.rendered = rendered
            self?.renderRevision += 1
        }
    }

    // MARK: - Saving

    /// Saves the design. Returns false (and sets `errorMessage`) on failure.
    func save() async -> Bool {
        isSaving = true
        defer { isSaving = false }
        do {
            try await covers.save(design, image: imageChange, for: book)
            savedDesign = design
            imageChange = .keep
            return true
        } catch {
            errorMessage = String(localized: "The cover couldn't be saved. Try again.")
            return false
        }
    }

    func resetToDefault() async {
        await covers.resetToDefault(for: book)
        isLoaded = false
        image = nil
        imageChange = .keep
        palette = .generated(for: seed.title)
        selectedBoxID = nil
        await load()
    }

    private static func decode(_ data: Data) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            CoverStore.decodeImage(data, maxPixels: 2400)
        }.value
    }
}

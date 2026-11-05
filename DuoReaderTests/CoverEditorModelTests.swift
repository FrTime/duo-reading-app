import Foundation
import Testing
import UIKit
@testable import DuoReader

@MainActor
struct CoverEditorModelTests {
    let library = CoverLibrary(store: CoverStore(
        root: FileManager.default.temporaryDirectory.appending(path: "CoverEditorTests-\(UUID().uuidString)"),
        renderer: CoverRenderer(frontWidth: 80)
    ))

    func book(cover: Data? = nil) -> Book {
        let book = Book(relativeFilePath: "x", contentHash: "x", format: .epub, title: "Hello World", authors: ["Ada Writer"])
        book.coverImageData = cover
        return book
    }

    @Test func loadsTheCurrentDesign() async {
        let model = CoverEditorModel(book: book(), covers: library)
        await model.load()
        #expect(model.isLoaded)
        #expect(model.design.template == .typographic)
        #expect(!model.hasChanges)
        #expect(!model.hasEmbeddedCover)
    }

    @Test func choosingAnImageLeavesTextOnly() async {
        let model = CoverEditorModel(book: book(), covers: library)
        await model.load()
        await model.setImage(CoverFixtures.jpeg(color: .blue), source: .userImage)
        #expect(model.design.imageSource == .userImage)
        #expect(model.design.template == .classic)
        #expect(model.design.baseColor.blue > 0.7)
        #expect(model.image != nil)
        #expect(model.hasChanges)
    }

    @Test func rejectsJunkImages() async {
        let model = CoverEditorModel(book: book(), covers: library)
        await model.load()
        await model.setImage(Data("junk".utf8), source: .userImage)
        #expect(model.errorMessage != nil)
        #expect(model.design.imageSource == CoverImageSource.none)
    }

    @Test func removingTheImageGoesBackToText() async {
        let model = CoverEditorModel(book: book(cover: CoverFixtures.jpeg()), covers: library)
        await model.load()
        #expect(model.design.imageSource == .embedded)
        model.removeImage()
        #expect(model.design.imageSource == CoverImageSource.none)
        #expect(model.design.template == .typographic)
        #expect(model.design.textBoxes(on: .front).contains { $0.role == .title })

        await model.useEmbeddedCover()
        #expect(model.design.imageSource == .embedded)
    }

    @Test func recolouringKeepsTextReadable() async throws {
        let model = CoverEditorModel(book: book(), covers: library)
        await model.load()
        model.setColor(.white, of: .spine)
        #expect(model.design.spineColor == .white)
        let spineText = model.design.textBoxes(on: .spine)
        #expect(!spineText.isEmpty)
        #expect(spineText.allSatisfy { $0.color == RGBAColor.ink })

        model.setColor(.black, of: .spine)
        #expect(model.design.textBoxes(on: .spine).allSatisfy { $0.color == RGBAColor.paper })
    }

    @Test func addingAndEditingText() async throws {
        let model = CoverEditorModel(book: book(), covers: library)
        await model.load()
        model.addTextBox(on: .back)
        let id = try #require(model.selectedBoxID)
        #expect(model.panel == .text)
        #expect(model.stage == .face(.back))
        #expect(model.selectedBox?.face == .back)

        model.update(id) { $0.centerX = 5; $0.text = "Signed" }
        #expect(model.selectedBox?.text == "Signed")
        #expect((model.selectedBox?.centerX ?? 0) <= 1)

        model.deleteTextBox(id)
        #expect(model.selectedBoxID == nil)
        #expect(!model.design.textBoxes.contains { $0.id == id })
    }

    @Test func savingUpdatesTheShelf() async throws {
        let book = book()
        let model = CoverEditorModel(book: book, covers: library)
        await model.load()
        model.apply(.minimal)
        #expect(await model.save())
        #expect(!model.hasChanges)
        #expect(library.revision(for: book.id) == 1)
        #expect(await library.design(for: book).template == .minimal)
    }

    @Test func templateThumbnailsRender() async {
        let model = CoverEditorModel(book: book(), covers: library)
        await model.load()
        for template in CoverTemplate.allCases {
            let thumbnail = await model.thumbnail(for: template)
            #expect(thumbnail.size.width == 120)
        }
    }

    @Test func convertsPickerColours() throws {
        let color = try #require(RGBAColor(cgColor: UIColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1).cgColor))
        #expect(abs(color.red - 0.2) < 0.01)
        #expect(abs(color.blue - 0.6) < 0.01)
        let grey = try #require(RGBAColor(cgColor: UIColor(white: 0.5, alpha: 1).cgColor))
        #expect(abs(grey.red - grey.blue) < 0.01)
    }
}

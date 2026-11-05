import Foundation
import Testing
import UIKit
@testable import DuoReader

/// Solid-colour test images, so no real artwork is needed.
enum CoverFixtures {
    static func image(width: Int = 200, height: Int = 300, color: UIColor = .systemRed, leftEdge: UIColor? = nil) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: width, height: height)
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            if let leftEdge {
                leftEdge.setFill()
                context.fill(CGRect(x: 0, y: 0, width: CGFloat(width) * 0.15, height: CGFloat(height)))
            }
        }
    }

    static func jpeg(width: Int = 200, height: Int = 300, color: UIColor = .systemRed) -> Data {
        image(width: width, height: height, color: color).jpegData(compressionQuality: 0.9)!
    }

    static func seed(
        title: String = "The Long Way Round",
        authors: [String] = ["Ada Writer"],
        summary: String? = "A story about a long way round.",
        wordCount: Int? = nil,
        cover: Data? = nil
    ) -> CoverSeed {
        CoverSeed(bookID: UUID(), title: title, authors: authors, summary: summary, wordCount: wordCount, embeddedCoverData: cover)
    }
}

struct RGBAColorTests {
    @Test func parsesAndPrintsHex() throws {
        let color = try #require(RGBAColor(hex: "#3366CC"))
        #expect(color.hex == "#3366CC")
        #expect(RGBAColor(hex: "3366cc80")?.hex == "#3366CC80")
    }

    @Test(arguments: ["", "#12", "#GGGGGG", "1234567"])
    func rejectsBadHex(_ value: String) {
        #expect(RGBAColor(hex: value) == nil)
    }

    @Test func clampsComponents() {
        let color = RGBAColor(red: 2, green: -1, blue: .nan)
        #expect(color == RGBAColor(red: 1, green: 0, blue: 0))
    }

    @Test func picksReadableText() {
        #expect(RGBAColor.black.contrastingText == .paper)
        #expect(RGBAColor.white.contrastingText == .ink)
        #expect(RGBAColor.cream.contrastingText == .ink)
        #expect(RGBAColor(red: 0.16, green: 0.25, blue: 0.4).contrastingText == .paper)
    }

    @Test func contrastRatioMatchesWCAG() {
        #expect(abs(RGBAColor.black.contrastRatio(with: .white) - 21) < 0.01)
        #expect(RGBAColor.white.contrastRatio(with: .white) == 1)
    }

    @Test func generatedColourIsStable() {
        #expect(RGBAColor.generated(for: "Dune") == RGBAColor.generated(for: "Dune"))
        let titles = (0..<40).map { "Book \($0)" }
        #expect(Set(titles.map { RGBAColor.generated(for: $0) }).count > 3)
    }
}

struct CoverSeedTests {
    @Test func estimatesPagesFromWordCount() {
        #expect(CoverFixtures.seed(wordCount: nil).estimatedPageCount == 300)
        #expect(CoverFixtures.seed(wordCount: 82_500).estimatedPageCount == 300)
        #expect(CoverFixtures.seed(wordCount: 500).estimatedPageCount == 8)
    }

    @Test func formatsSeries() {
        var seed = CoverFixtures.seed()
        #expect(seed.seriesLine == nil)
        seed.series = "Round Books"
        #expect(seed.seriesLine == "Round Books")
        seed.seriesIndex = 2
        #expect(seed.seriesLine?.contains("2") == true)
        #expect(seed.seriesLine?.contains(".") == false)
    }

    @Test func trimsLongBlurbAtAWord() throws {
        let long = String(repeating: "word ", count: 400)
        let blurb = try #require(CoverFixtures.seed(summary: long).blurb)
        #expect(blurb.count <= 701)
        #expect(blurb.hasSuffix("…"))
        #expect(CoverFixtures.seed(summary: "   ").blurb == nil)
    }

    @Test func fingerprintFollowsMetadata() {
        let seed = CoverFixtures.seed()
        var changed = seed
        #expect(seed.fingerprint == changed.fingerprint)
        changed.title = "Another"
        #expect(seed.fingerprint != changed.fingerprint)
        var withCover = seed
        withCover.embeddedCoverData = CoverFixtures.jpeg()
        #expect(seed.fingerprint != withCover.fingerprint)
    }
}

struct CoverDesignTests {
    @Test func thicknessFollowsPageCount() {
        #expect(abs(CoverDesign.thickness(forPageCount: 300) - 0.12) < 0.0001)
        #expect(CoverDesign.thickness(forPageCount: 0) == CoverDesign.thicknessRange.lowerBound)
        #expect(CoverDesign.thickness(forPageCount: 100_000) == CoverDesign.thicknessRange.upperBound)
    }

    @Test func clampsTextBoxesInsideTheFace() {
        var box = CoverTextBox(face: .front, text: "Hi", centerX: 1.2, centerY: -0.5, width: 0.001, height: 3, fontSize: 9)
        box.clamp()
        #expect(box.width == CoverTextBox.minimumSide)
        #expect(box.height == 1)
        #expect(box.centerX == 1 - box.width / 2)
        #expect(box.centerY == 0.5)
        #expect(box.fontSize == CoverTextBox.fontSizeRange.upperBound)
    }

    @Test func roundTripsThroughJSON() throws {
        var design = CoverTemplate.classic.makeDesign(
            seed: CoverFixtures.seed(),
            palette: .generated(for: "x"),
            imageSource: .search(provider: "openLibrary", url: URL(string: "https://covers.openlibrary.org/b/id/1-L.jpg")!)
        )
        design.isUserEdited = true
        design.seedFingerprint = "abc"
        let data = try JSONEncoder().encode(design)
        let decoded = try JSONDecoder().decode(CoverDesign.self, from: data)
        #expect(decoded == design)
    }
}

struct CoverTemplateTests {
    let palette = CoverPalette.generated(for: "Test")

    @Test func imageCoverHasNoFrontText() {
        let design = CoverTemplate.classic.makeDesign(seed: CoverFixtures.seed(), palette: palette, imageSource: .embedded)
        #expect(design.textBoxes(on: .front).isEmpty)
        #expect(design.textBoxes(on: .spine).contains { $0.role == .title && $0.isVertical })
        #expect(design.textBoxes(on: .back).contains { $0.role == .blurb })
    }

    @Test func textOnlyCoverPutsTitleOnFront() {
        let design = CoverTemplate.typographic.makeDesign(seed: CoverFixtures.seed(), palette: palette, imageSource: .none)
        let front = design.textBoxes(on: .front)
        #expect(front.contains { $0.role == .title && $0.text == "The Long Way Round" })
        #expect(front.contains { $0.role == .author })
    }

    @Test func noAuthorOrSummaryMeansNoEmptyBoxes() {
        let seed = CoverFixtures.seed(authors: [], summary: nil)
        let design = CoverTemplate.minimal.makeDesign(seed: seed, palette: palette, imageSource: .none)
        #expect(!design.textBoxes.contains { $0.role == .author || $0.role == .blurb })
        #expect(design.textBoxes.allSatisfy { !$0.text.isEmpty })
    }

    @Test(arguments: CoverTemplate.allCases)
    func spineTextIsReadable(_ template: CoverTemplate) {
        let design = template.makeDesign(seed: CoverFixtures.seed(), palette: palette, imageSource: .embedded)
        for box in design.textBoxes(on: .spine) {
            #expect(box.color.contrastRatio(with: design.spineColor) >= 3, "\(template) spine text")
        }
    }

    @Test(arguments: CoverTemplate.allCases)
    func boxesStartInsideTheirFace(_ template: CoverTemplate) {
        let design = template.makeDesign(seed: CoverFixtures.seed(), palette: palette, imageSource: .none)
        for box in design.textBoxes {
            var clamped = box
            clamped.clamp()
            #expect(clamped == box, "\(template) \(box.face) \(box.role)")
        }
    }

    @Test func switchingTemplateKeepsEditsAndCustomText() throws {
        var design = CoverTemplate.classic.makeDesign(seed: CoverFixtures.seed(), palette: palette, imageSource: .embedded)
        design.imageZoom = 1.5
        design.thickness = 0.2
        let titleIndex = try #require(design.textBoxes.firstIndex { $0.role == .title })
        design.textBoxes[titleIndex].text = "My Own Title"
        design.textBoxes.append(CoverTextBox(face: .front, role: .custom, text: "Signed"))

        let switched = CoverTemplate.clothbound.apply(to: design, seed: CoverFixtures.seed(), palette: palette)
        #expect(switched.template == .clothbound)
        #expect(switched.imageZoom == 1.5)
        #expect(switched.thickness == 0.2)
        #expect(switched.textBoxes.filter { $0.role == .title }.allSatisfy { $0.text == "My Own Title" })
        #expect(switched.textBoxes.contains { $0.role == .custom && $0.text == "Signed" })
        #expect(switched.accentColor == .gold)
    }

    @Test func clothboundSpineTextClearsTheGiltBands() {
        let design = CoverTemplate.clothbound.makeDesign(seed: CoverFixtures.seed(), palette: palette, imageSource: .embedded)
        for box in design.textBoxes(on: .spine) {
            #expect(box.centerY - box.height / 2 >= 0.095, "\(box.role) runs into the head bands")
            #expect(box.centerY + box.height / 2 <= 0.91, "\(box.role) runs into the foot bands")
        }
    }

    @Test func backAndSpineFollowTheFront() {
        let palette = CoverPalette(base: RGBAColor(red: 0.1, green: 0.3, blue: 0.6), edge: RGBAColor(red: 0.1, green: 0.3, blue: 0.6), accent: .gold)
        let classic = CoverTemplate.classic.makeDesign(seed: CoverFixtures.seed(), palette: palette, imageSource: .embedded)
        #expect(classic.backColor == classic.baseColor)
        let minimal = CoverTemplate.minimal.makeDesign(seed: CoverFixtures.seed(), palette: palette, imageSource: .none)
        #expect(minimal.baseColor == .cream)
    }

    @Test func noMuddyShadowsOnFlatColour() {
        let flat = CoverTemplate.wraparound.makeDesign(seed: CoverFixtures.seed(), palette: palette, imageSource: .none)
        #expect(flat.textBoxes.allSatisfy { !$0.hasShadow })
        let art = CoverTemplate.wraparound.makeDesign(seed: CoverFixtures.seed(), palette: palette, imageSource: .embedded)
        #expect(art.textBoxes(on: .back).allSatisfy { $0.hasShadow })
    }

    @Test func wraparoundNeedsArt() {
        #expect(!CoverTemplate.wraparound.isAvailable(hasImage: false))
        #expect(CoverTemplate.wraparound.isAvailable(hasImage: true))
        #expect(CoverTemplate.allCases.filter { $0.isAvailable(hasImage: false) }.count == CoverTemplate.allCases.count - 1)
    }

    @Test func minimalTintsItsPaperFromTheArt() {
        let blue = CoverPalette(base: RGBAColor(red: 0.1, green: 0.3, blue: 0.6), edge: RGBAColor(red: 0.1, green: 0.3, blue: 0.6), accent: .gold)
        let design = CoverTemplate.minimal.makeDesign(seed: CoverFixtures.seed(), palette: blue, imageSource: .embedded)
        #expect(design.backColor != .cream)
        #expect(design.backColor.blue > design.backColor.red)
        #expect(design.backColor.luminance > 0.4)
    }

    @Test func defaultTemplateDependsOnArtwork() {
        #expect(CoverTemplate.defaultTemplate(hasImage: true) == .classic)
        #expect(CoverTemplate.defaultTemplate(hasImage: false) == .typographic)
    }
}

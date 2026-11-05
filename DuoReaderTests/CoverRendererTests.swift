import Foundation
import Testing
import UIKit
@testable import DuoReader

struct CoverRendererTests {
    let renderer = CoverRenderer(frontWidth: 300)

    func design(template: CoverTemplate = .classic, image: Bool = true) -> CoverDesign {
        template.makeDesign(
            seed: CoverFixtures.seed(),
            palette: .generated(for: "x"),
            imageSource: image ? .embedded : .none
        )
    }

    @Test func facesHaveBookProportions() {
        let design = design()
        #expect(renderer.size(of: .front, design: design) == CGSize(width: 300, height: 450))
        #expect(renderer.size(of: .back, design: design) == CGSize(width: 300, height: 450))
        #expect(renderer.size(of: .spine, design: design) == CGSize(width: 36, height: 450))
    }

    @Test func defaultFrontIsSharpOnTheOuterDisplay() {
        // The outer display is 466 pt wide at 3x.
        #expect(CoverRenderer.defaultFrontWidth >= 466 * 3)
    }

    @Test(arguments: CoverTemplate.allCases)
    func rendersEveryFaceAtPixelSize(_ template: CoverTemplate) {
        let design = design(template: template)
        let rendered = renderer.render(design: design, image: CoverFixtures.image())
        for face in CoverFace.allCases {
            let image = rendered.image(for: face)
            #expect(image.scale == 1)
            #expect(image.size == renderer.size(of: face, design: design), "\(template) \(face)")
        }
    }

    @Test func frontShowsTheImage() throws {
        let design = design()
        let front = renderer.render(.front, design: design, image: CoverFixtures.image(color: .blue))
        let palette = try #require(front.cgImage.flatMap(ColorSampler.palette))
        #expect(palette.base.blue > 0.7)
        #expect(palette.base.red < 0.3)
    }

    @Test func typographicFrontIgnoresTheImage() throws {
        let design = design(template: .typographic)
        let front = renderer.render(.front, design: design, image: CoverFixtures.image(color: .blue))
        let palette = try #require(front.cgImage.flatMap(ColorSampler.palette))
        #expect(abs(palette.base.blue - design.baseColor.blue) < 0.2)
    }

    @Test func rendersWithoutAnImage() {
        let rendered = renderer.render(design: design(image: false), image: nil)
        #expect(rendered.front.size.width == 300)
    }

    @Test func fillRectCoversTheBounds() {
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 300)
        let wide = CoverRenderer.fillRect(imageSize: CGSize(width: 400, height: 200), in: bounds, zoom: 1, offsetX: 0, offsetY: 0)
        #expect(wide.height == 300)
        #expect(wide.width == 600)
        #expect(wide.midX == 100)

        let left = CoverRenderer.fillRect(imageSize: CGSize(width: 400, height: 200), in: bounds, zoom: 1, offsetX: -1, offsetY: 0)
        #expect(left.minX == 0)
        let right = CoverRenderer.fillRect(imageSize: CGSize(width: 400, height: 200), in: bounds, zoom: 1, offsetX: 1, offsetY: 0)
        #expect(right.maxX == 200)

        let zoomed = CoverRenderer.fillRect(imageSize: CGSize(width: 200, height: 300), in: bounds, zoom: 2, offsetX: 0, offsetY: 0)
        #expect(zoomed.size == CGSize(width: 400, height: 600))
        #expect(zoomed.contains(bounds))
    }

    @Test func zoomBelowOneStillFills() {
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 300)
        let rect = CoverRenderer.fillRect(imageSize: CGSize(width: 200, height: 300), in: bounds, zoom: 0.2, offsetX: 5, offsetY: -5)
        #expect(rect == bounds)
    }

    @Test func longTitlesShrinkToFit() {
        let box = CoverTextBox(face: .spine, text: String(repeating: "Supercalifragilistic ", count: 6), width: 1, height: 1, fontSize: 0.1)
        let layout = CGSize(width: 200, height: 40)
        let fitted = CoverRenderer.fittedText(box.text, box: box, pointSize: 30, in: layout)
        let font = fitted.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        #expect((font?.pointSize ?? 30) < 30)
        #expect((font?.pointSize ?? 0) >= 10)
    }

    @Test(arguments: CoverFont.allCases)
    func everyFontResolves(_ font: CoverFont) {
        let resolved = CoverRenderer.font(font, weight: .bold, size: 20)
        #expect(resolved.pointSize == 20)
        if let family = font.familyName {
            #expect(UIFont.familyNames.contains(family), "\(family) isn't installed")
        }
    }
}

struct ColorSamplerTests {
    @Test func samplesOverallAndEdgeColours() throws {
        let image = CoverFixtures.image(color: .red, leftEdge: .blue)
        let palette = try #require(image.cgImage.flatMap(ColorSampler.palette))
        #expect(palette.edge.blue > 0.8)
        #expect(palette.edge.red < 0.2)
        #expect(palette.base.red > 0.7)
        #expect(palette.accent.red > 0.7)
    }

    @Test func greyImageGetsAnAccentAnyway() throws {
        let palette = try #require(CoverFixtures.image(color: .gray).cgImage.flatMap(ColorSampler.palette))
        #expect(palette.accent != palette.base)
    }
}

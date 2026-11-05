import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import DuoReader

struct BookSizeTests {
    func design() -> CoverDesign {
        CoverTemplate.classic.makeDesign(
            seed: CoverFixtures.seed(),
            palette: .generated(for: "x"),
            imageSource: .embedded
        )
    }

    @Test func defaultSizeIsStableAndInRange() {
        for _ in 0..<200 {
            let id = UUID()
            let scale = CoverDesign.defaultHeightScale(for: id)
            #expect(scale >= 0.93 - 1e-9 && scale <= 1.05 + 1e-9)
            #expect(CoverDesign.defaultHeightScale(for: id) == scale)
        }
    }

    @Test func defaultSizesVary() {
        let scales = Set((0..<50).map { _ in CoverDesign.defaultHeightScale(for: UUID()) })
        #expect(scales.count > 10)
    }

    @Test func userSizeWinsAndIsClamped() {
        var design = design()
        let id = UUID()
        #expect(design.sizeScale(for: id) == CoverDesign.defaultHeightScale(for: id))
        design.heightScale = 1.1
        #expect(design.sizeScale(for: id) == 1.1)
        design.heightScale = 5
        #expect(design.sizeScale(for: id) == CoverDesign.heightScaleRange.upperBound)
        design.heightScale = 0
        #expect(design.sizeScale(for: id) == CoverDesign.heightScaleRange.lowerBound)
    }

    @Test func olderDesignsDecodeWithoutTheNewFields() throws {
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(design())) as? [String: Any])
        json.removeValue(forKey: "heightScale")
        json.removeValue(forKey: "fitsWholeImage")
        let data = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(CoverDesign.self, from: data)
        #expect(decoded.heightScale == nil)
        #expect(decoded.fitsWholeImage == nil)
    }

    @Test func newFieldsRoundTrip() throws {
        var design = design()
        design.heightScale = 0.9
        design.fitsWholeImage = true
        let decoded = try JSONDecoder().decode(CoverDesign.self, from: JSONEncoder().encode(design))
        #expect(decoded == design)
    }

    @Test func biggerBooksAreTallerWiderAndDeeper() {
        let metrics = ShelfMetrics()
        let small = ShelfBookSpec(id: UUID(), thickness: 0.12, heightScale: 0.85)
        let big = ShelfBookSpec(id: UUID(), thickness: 0.12, heightScale: 1.1)
        #expect(metrics.height(of: big) > metrics.height(of: small))
        #expect(metrics.width(of: big) > metrics.width(of: small))
        #expect(metrics.depth(of: big) > metrics.depth(of: small))
        #expect(metrics.height(of: big) <= metrics.maxBookHeight)
        #expect(metrics.width(of: big) < metrics.shelfDepth)
    }

    @Test func specScaleIsClamped() {
        let metrics = ShelfMetrics()
        let huge = ShelfBookSpec(id: UUID(), thickness: 0.12, heightScale: 9)
        #expect(abs(metrics.height(of: huge) - metrics.maxBookHeight) < 1e-6)
    }

    @Test func mixedSizesStandOnTheBoardAndFitUnderTheNext() {
        let specs = (0..<40).map { index in
            ShelfBookSpec(id: UUID(), thickness: 0.12, heightScale: index.isMultiple(of: 2) ? 0.8 : 1.15)
        }
        let layout = ShelfLayout(books: specs, mode: .spines, shelfWidth: 0.5)
        #expect(layout.rowCount > 1)
        let metrics = layout.metrics
        for slot in layout.slots {
            let spec = specs[slot.index]
            #expect(abs(slot.height - metrics.height(of: spec)) < 1e-6)
            // The board above sits a full row higher, so the book never pokes through it.
            #expect(slot.height + metrics.headroom <= metrics.rowHeight - metrics.boardThickness + 1e-6)
        }
        // Every slot can still be hit-tested at half its own height.
        for slot in layout.slots {
            #expect(layout.book(atX: slot.x, y: slot.baseY + slot.height / 2) == slot.id)
        }
    }

    @Test func fitRectShowsTheWholeImage() {
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 300)
        let wide = CoverRenderer.fitRect(imageSize: CGSize(width: 400, height: 200), in: bounds, zoom: 1, offsetX: 1, offsetY: 1)
        #expect(wide.size == CGSize(width: 200, height: 100))
        #expect(wide.midX == 100 && wide.midY == 150)
        #expect(bounds.contains(wide))

        let zoomed = CoverRenderer.fitRect(imageSize: CGSize(width: 400, height: 200), in: bounds, zoom: 2, offsetX: -1, offsetY: 0)
        #expect(zoomed.size == CGSize(width: 400, height: 200))
        #expect(zoomed.minX == 0)
    }

    @Test func rendersAFittedImage() {
        var design = design()
        design.fitsWholeImage = true
        let image = CoverFixtures.image(width: 400, height: 100, color: .systemBlue)
        let rendered = CoverRenderer(frontWidth: 300).render(design: design, image: image)
        #expect(rendered.front.size.width == 300)
    }
}

struct WebImageSearchTests {
    @Test func buildsADefaultQuery() {
        #expect(WebImageSearch.defaultQuery(title: "All the Young Dudes", authors: ["MsKingBean89"]) == "All the Young Dudes MsKingBean89 book cover")
        #expect(WebImageSearch.defaultQuery(title: " Dune ", authors: []) == "Dune book cover")
    }

    @Test func buildsASearchURL() throws {
        let url = try #require(WebImageSearch.searchURL(for: "all the young dudes sirius pov front cover"))
        #expect(url.scheme == "https")
        #expect(url.host() == "www.bing.com")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "q" }?.value == "all the young dudes sirius pov front cover")
        #expect(WebImageSearch.searchURL(for: "   ") == nil)
    }

    @Test func prefersTheFullImageThenTheShownOne() {
        let candidates = WebImageSearch.candidates(full: "https://example.com/full.jpg", shown: "https://example.com/thumb.jpg")
        #expect(candidates == [.remote(URL(string: "https://example.com/full.jpg")!), .remote(URL(string: "https://example.com/thumb.jpg")!)])
    }

    @Test func dropsInsecureAndDuplicateSources() {
        let candidates = WebImageSearch.candidates(full: "http://example.com/a.jpg", shown: "javascript:alert(1)")
        #expect(candidates.isEmpty)
        let same = WebImageSearch.candidates(full: "https://example.com/a.jpg", shown: "https://example.com/a.jpg")
        #expect(same.count == 1)
    }

    @Test func decodesInlineImages() {
        let data = Data([1, 2, 3, 4])
        let candidates = WebImageSearch.candidates(full: nil, shown: "data:image/png;base64,\(data.base64EncodedString())")
        #expect(candidates == [.inline(data)])
        #expect(WebImageSearch.candidates(full: nil, shown: "data:image/svg+xml,<svg/>").isEmpty)
    }

    @Test func fitsArtFarFromABookShape() {
        #expect(CoverEditorModel.prefersFitting(CGSize(width: 1600, height: 900)))
        #expect(!CoverEditorModel.prefersFitting(CGSize(width: 1000, height: 1500)))
        #expect(!CoverEditorModel.prefersFitting(CGSize(width: 1000, height: 1200)))
        #expect(!CoverEditorModel.prefersFitting(.zero))
    }
}

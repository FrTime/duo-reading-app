import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import DuoReader

struct CoverImageTests {
    static func png(width: Int, height: Int) throws -> Data {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
        return data as Data
    }

    static func pixelSize(_ data: Data) throws -> (Int, Int) {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return (props[kCGImagePropertyPixelWidth] as? Int ?? 0, props[kCGImagePropertyPixelHeight] as? Int ?? 0)
    }

    @Test func downsizesLargeCoversKeepingAspect() throws {
        let thumb = try #require(CoverImage.thumbnail(from: try Self.png(width: 2000, height: 3000)))
        let (w, h) = try Self.pixelSize(thumb)
        #expect(h == CoverImage.thumbnailMaxPixel)
        #expect(w == 320)
        #expect(thumb.starts(with: [0xFF, 0xD8]))  // JPEG
        #expect(thumb.count < 100_000)
    }

    @Test func returnsNilForNonImages() {
        #expect(CoverImage.thumbnail(from: Data("not an image".utf8)) == nil)
    }

    @MainActor
    @Test func setCoverKeepsThumbnailInStep() throws {
        let book = Book(relativeFilePath: "x", contentHash: "x", format: .epub, title: "T")
        let cover = try Self.png(width: 600, height: 900)
        book.setCover(cover)
        #expect(book.coverImageData == cover)
        #expect(book.coverThumbnailData != nil)

        book.setCover(nil)
        #expect(book.coverImageData == nil)
        #expect(book.coverThumbnailData == nil)
    }
}

import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Small helpers for cover images that don't need UIKit.
public enum CoverImage {
    /// Longest side of the stored thumbnail, in pixels. Enough for a grid cell
    /// on the inner display at 3x.
    public static let thumbnailMaxPixel = 480

    /// A small JPEG of the cover for grids and lists, so they never load the
    /// full-size image. Nil if the data isn't an image.
    public static func thumbnail(from data: Data, maxPixel: Int = thumbnailMaxPixel) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

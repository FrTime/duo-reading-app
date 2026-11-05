import CoreGraphics
import Foundation

/// Picks the colours a template needs out of a cover image.
public enum ColorSampler {
    /// Samples a small copy of the image: its overall colour, the colour of its
    /// left edge (which runs onto the spine) and its most common vivid colour.
    public static func palette(from image: CGImage) -> CoverPalette? {
        let width = 24
        let height = 36
        guard let pixels = rgbaPixels(of: image, width: width, height: height) else { return nil }

        /// The average of the most common colour in those columns, so a
        /// blue cover with an orange sun reads as blue, not grey.
        func dominant(columns: Range<Int>) -> RGBAColor {
            var bins = [Int: (r: Double, g: Double, b: Double, n: Int)]()
            for y in 0..<height {
                for x in columns {
                    let i = (y * width + x) * 4
                    let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
                    let key = (r >> 6) << 4 | (g >> 6) << 2 | (b >> 6)
                    var bin = bins[key] ?? (0, 0, 0, 0)
                    bin.r += Double(r); bin.g += Double(g); bin.b += Double(b); bin.n += 1
                    bins[key] = bin
                }
            }
            guard let best = bins.values.max(by: { $0.n < $1.n }), best.n > 0 else { return .cream }
            let n = Double(best.n) * 255
            return RGBAColor(red: best.r / n, green: best.g / n, blue: best.b / n)
        }

        let base = dominant(columns: 0..<width)
        let edge = dominant(columns: 0..<3)

        // Bucket vivid pixels by hue and average the busiest bucket.
        var buckets = [(r: Double, g: Double, b: Double, n: Int)](repeating: (0, 0, 0, 0), count: 12)
        for p in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[p]) / 255, g = Double(pixels[p + 1]) / 255, b = Double(pixels[p + 2]) / 255
            let hsv = hsv(r, g, b)
            guard hsv.s > 0.35, hsv.v > 0.25 else { continue }
            let bucket = min(Int(hsv.h * 12), 11)
            buckets[bucket].r += r; buckets[bucket].g += g; buckets[bucket].b += b; buckets[bucket].n += 1
        }
        let accent: RGBAColor
        if let best = buckets.max(by: { $0.n < $1.n }), best.n >= 6 {
            let n = Double(best.n)
            accent = RGBAColor(red: best.r / n, green: best.g / n, blue: best.b / n)
        } else {
            accent = base.luminance > 0.5 ? base.darkened(0.35) : base.lightened(0.35)
        }
        return CoverPalette(base: base, edge: edge, accent: accent)
    }

    /// Draws the image into an sRGB RGBA8 bitmap of the given size.
    static func rgbaPixels(of image: CGImage, width: Int, height: Int) -> [UInt8]? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }

    static func hsv(_ r: Double, _ g: Double, _ b: Double) -> (h: Double, s: Double, v: Double) {
        let maxC = max(r, g, b), minC = min(r, g, b), delta = maxC - minC
        var h = 0.0
        if delta > 0 {
            if maxC == r {
                h = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxC == g {
                h = (b - r) / delta + 2
            } else {
                h = (r - g) / delta + 4
            }
            h /= 6
            if h < 0 { h += 1 }
        }
        return (h, maxC == 0 ? 0 : delta / maxC, maxC)
    }
}

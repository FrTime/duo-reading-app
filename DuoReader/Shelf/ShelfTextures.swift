import RealityKit
import UIKit

/// Procedural textures for the bookcase, drawn once on first use. Nothing is
/// bundled, so there are no third-party assets to license.
enum ShelfTextures {
    static let wood = RGBAColor(red: 0.55, green: 0.38, blue: 0.24)
    static let wall = RGBAColor(red: 0.30, green: 0.21, blue: 0.14)

    /// A board's face: warm wood with long, gently wavy grain in lighter and
    /// darker streaks, a few knots' worth of colour variation, and a lit top
    /// edge.
    static func boardImage() -> CGImage? {
        draw(size: CGSize(width: 1024, height: 128)) { context, size in
            context.setFillColor(wood.cgColor)
            context.fill(CGRect(origin: .zero, size: size))
            var generator = SeededGenerator(seed: 7)
            // Broad, soft colour bands first, then fine grain over them.
            for _ in 0..<10 {
                let y = CGFloat.random(in: 0..<size.height, using: &generator)
                let height = CGFloat.random(in: 8...30, using: &generator)
                let tone = Bool.random(using: &generator) ? wood.darkened(0.25) : wood.lightened(0.12)
                context.setFillColor(tone.cgColor.copy(alpha: CGFloat.random(in: 0.18...0.35, using: &generator)) ?? wood.cgColor)
                context.fill(CGRect(x: 0, y: y, width: size.width, height: height))
            }
            for _ in 0..<70 {
                var y = CGFloat.random(in: 0..<size.height, using: &generator)
                let dark = CGFloat.random(in: 0...1, using: &generator) < 0.75
                let tone = dark ? wood.darkened(0.55) : wood.lightened(0.25)
                let alpha = CGFloat.random(in: dark ? 0.12...0.32 : 0.08...0.18, using: &generator)
                context.setStrokeColor(tone.cgColor.copy(alpha: alpha) ?? wood.cgColor)
                context.setLineWidth(CGFloat.random(in: 0.6...2.2, using: &generator))
                let amplitude = CGFloat.random(in: 0.5...3, using: &generator)
                let wavelength = CGFloat.random(in: 120...420, using: &generator)
                let phase = CGFloat.random(in: 0...(2 * .pi), using: &generator)
                context.move(to: CGPoint(x: 0, y: y))
                var x: CGFloat = 0
                while x < size.width {
                    x += 8
                    y += CGFloat.random(in: -0.15...0.15, using: &generator)
                    context.addLine(to: CGPoint(x: x, y: y + amplitude * sin(x / wavelength * 2 * .pi + phase)))
                }
                context.strokePath()
            }
            context.setFillColor(UIColor.white.withAlphaComponent(0.14).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: size.width, height: 4))
            context.setFillColor(UIColor.black.withAlphaComponent(0.18).cgColor)
            context.fill(CGRect(x: 0, y: size.height - 4, width: size.width, height: 4))
        }
    }

    /// Wood for the uprights: the board's grain turned to run top to
    /// bottom, with darker edges so each upright reads as its own board.
    static func uprightImage() -> CGImage? {
        guard let board = boardImage() else { return nil }
        return draw(size: CGSize(width: board.height, height: board.width)) { context, size in
            context.saveGState()
            context.translateBy(x: size.width / 2, y: size.height / 2)
            context.rotate(by: .pi / 2)
            context.draw(board, in: CGRect(x: -size.height / 2, y: -size.width / 2, width: size.height, height: size.width))
            context.restoreGState()
            context.setFillColor(UIColor.black.withAlphaComponent(0.22).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 5, height: size.height))
            context.fill(CGRect(x: size.width - 5, y: 0, width: 5, height: size.height))
        }
    }

    /// The back of one shelf: darker horizontal planks, in shadow under the
    /// board above.
    static func backPanelImage() -> CGImage? {
        draw(size: CGSize(width: 512, height: 256)) { context, size in
            context.setFillColor(wall.cgColor)
            context.fill(CGRect(origin: .zero, size: size))
            var generator = SeededGenerator(seed: 11)
            for _ in 0..<40 {
                let y = CGFloat.random(in: 0..<size.height, using: &generator)
                let tone = Bool.random(using: &generator) ? wall.darkened(0.4) : wall.lightened(0.15)
                context.setFillColor(tone.cgColor.copy(alpha: CGFloat.random(in: 0.08...0.22, using: &generator)) ?? wall.cgColor)
                context.fill(CGRect(x: 0, y: y, width: size.width, height: CGFloat.random(in: 1...4, using: &generator)))
            }
            // A seam between two planks.
            context.setFillColor(UIColor.black.withAlphaComponent(0.25).cgColor)
            context.fill(CGRect(x: 0, y: size.height * 0.55, width: size.width, height: 2))
            guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return }
            let colors = [
                UIColor.black.withAlphaComponent(0.45).cgColor,
                UIColor.black.withAlphaComponent(0.12).cgColor,
                UIColor.black.withAlphaComponent(0.0).cgColor,
                UIColor.black.withAlphaComponent(0.15).cgColor,
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.25, 0.7, 1]) {
                context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            }
        }
    }

    private static func draw(size: CGSize, _ body: (CGContext, CGSize) -> Void) -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { body($0.cgContext, size) }.cgImage
    }

    /// A lit material: the image as its colour, with a satin finish so the
    /// key light picks out edges and the books cast real shadows.
    @MainActor
    static func material(from image: CGImage?, fallback: RGBAColor, roughness: Float = 0.6) async -> PhysicallyBasedMaterial {
        var material = solid(fallback, roughness: roughness)
        if let image, let texture = try? await TextureResource(image: bgra(image) ?? image, options: .init(semantic: .color)) {
            material.baseColor = .init(tint: .white, texture: .init(texture))
        }
        return material
    }

    /// RealityKit uploads BGRA images directly; other layouts (such as the
    /// RGB a JPEG decodes to) take a slow path that logs CVPixelBuffer errors.
    static func bgra(_ image: CGImage) -> CGImage? {
        let alpha = image.alphaInfo
        if image.bitsPerPixel == 32, image.byteOrderInfo == .order32Little,
           alpha == .premultipliedFirst || alpha == .noneSkipFirst {
            return image
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: image.width,
                  height: image.height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              )
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    static func solid(_ color: RGBAColor, roughness: Float = 0.6) -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: UIColor(cgColor: color.cgColor))
        material.roughness = .init(floatLiteral: roughness)
        material.metallic = .init(floatLiteral: 0)
        return material
    }
}

/// A tiny deterministic generator so the grain looks the same every launch.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &+ 0x9E3779B97F4A7C15
    }

    mutating func next() -> UInt64 {
        // SplitMix64.
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

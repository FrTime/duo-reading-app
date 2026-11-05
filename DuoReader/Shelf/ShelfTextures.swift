import RealityKit
import UIKit

/// Procedural textures for the bookcase, drawn once on first use. Nothing is
/// bundled, so there are no third-party assets to license.
enum ShelfTextures {
    static let wood = RGBAColor(red: 0.55, green: 0.38, blue: 0.24)
    static let wall = RGBAColor(red: 0.30, green: 0.21, blue: 0.14)

    /// A board's face: warm wood with a few long grain lines and a lit top edge.
    static func boardImage() -> CGImage? {
        draw(size: CGSize(width: 1024, height: 64)) { context, size in
            context.setFillColor(wood.cgColor)
            context.fill(CGRect(origin: .zero, size: size))
            var generator = SeededGenerator(seed: 7)
            for _ in 0..<26 {
                let y = CGFloat.random(in: 0..<size.height, using: &generator)
                let alpha = CGFloat.random(in: 0.04...0.12, using: &generator)
                context.setFillColor(wood.darkened(0.5).cgColor.copy(alpha: alpha) ?? wood.cgColor)
                context.fill(CGRect(x: 0, y: y, width: size.width, height: CGFloat.random(in: 1...3, using: &generator)))
            }
            context.setFillColor(UIColor.white.withAlphaComponent(0.1).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: size.width, height: 3))
        }
    }

    /// The back of one shelf: darker wood, in shadow under the board above.
    static func backPanelImage() -> CGImage? {
        draw(size: CGSize(width: 64, height: 256)) { context, size in
            context.setFillColor(wall.cgColor)
            context.fill(CGRect(origin: .zero, size: size))
            guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return }
            let colors = [
                UIColor.black.withAlphaComponent(0.3).cgColor,
                UIColor.black.withAlphaComponent(0.08).cgColor,
                UIColor.black.withAlphaComponent(0.0).cgColor,
                UIColor.black.withAlphaComponent(0.1).cgColor,
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
        if let image, let texture = try? await TextureResource(image: image, options: .init(semantic: .color)) {
            material.baseColor = .init(tint: .white, texture: .init(texture))
        }
        return material
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

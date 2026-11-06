import CoreImage
import Foundation
import UIKit

/// The three faces of a book's jacket, drawn.
public struct RenderedCover: Sendable {
    public var front: UIImage
    public var spine: UIImage
    public var back: UIImage

    public init(front: UIImage, spine: UIImage, back: UIImage) {
        self.front = front
        self.spine = spine
        self.back = back
    }

    public func image(for face: CoverFace) -> UIImage {
        switch face {
        case .front: front
        case .spine: spine
        case .back: back
        }
    }
}

/// Draws a `CoverDesign` into images: the front for the outer display and the
/// editor, and all three faces as textures for the 3D book.
///
/// Pure drawing with no shared state, so it's safe to run off the main actor.
public struct CoverRenderer: Sendable {
    /// Wide enough for the iPhone Duo's outer display at 3x (1398 px).
    public static let defaultFrontWidth: CGFloat = 1400

    public var frontWidth: CGFloat

    public init(frontWidth: CGFloat = CoverRenderer.defaultFrontWidth) {
        self.frontWidth = max(frontWidth, 16)
    }

    /// Pixel size of a face. Front and back are 2:3; the spine is as wide as
    /// the design's thickness.
    public func size(of face: CoverFace, design: CoverDesign) -> CGSize {
        let height = (frontWidth / CoverDesign.frontAspectRatio).rounded()
        switch face {
        case .front, .back:
            return CGSize(width: frontWidth.rounded(), height: height)
        case .spine:
            return CGSize(width: max((frontWidth * design.clampedThickness).rounded(), 4), height: height)
        }
    }

    public func render(design: CoverDesign, image: UIImage?) -> RenderedCover {
        let blurred = needsBlurredImage(design) ? image.flatMap(Self.blurred) : nil
        return RenderedCover(
            front: render(.front, design: design, image: image, blurred: blurred),
            spine: render(.spine, design: design, image: image, blurred: blurred),
            back: render(.back, design: design, image: image, blurred: blurred)
        )
    }

    public func render(_ face: CoverFace, design: CoverDesign, image: UIImage?) -> UIImage {
        let blurred = face != .front && needsBlurredImage(design) ? image.flatMap(Self.blurred) : nil
        return render(face, design: design, image: image, blurred: blurred)
    }

    // MARK: - Faces

    private func needsBlurredImage(_ design: CoverDesign) -> Bool {
        design.template == .wraparound && design.hasImage
    }

    private func render(_ face: CoverFace, design: CoverDesign, image: UIImage?, blurred: UIImage?) -> UIImage {
        let size = size(of: face, design: design)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { context in
            let cg = context.cgContext
            let bounds = CGRect(origin: .zero, size: size)
            switch face {
            case .front: drawFront(design: design, image: image, in: bounds, context: cg)
            case .spine: drawSpine(design: design, blurred: blurred, in: bounds, context: cg)
            case .back: drawBack(design: design, blurred: blurred, in: bounds, context: cg)
            }
            for box in design.textBoxes(on: face) {
                draw(box, faceBounds: bounds, context: cg)
            }
            drawShading(for: face, in: bounds, context: cg)
        }
    }

    private func drawFront(design: CoverDesign, image: UIImage?, in bounds: CGRect, context: CGContext) {
        context.setFillColor(design.baseColor.cgColor)
        context.fill(bounds)
        if design.hasImage, design.template.showsImageOnFront, let image {
            context.saveGState()
            context.clip(to: bounds)
            context.interpolationQuality = .high
            if design.fitsWholeImage == true {
                // Letterbox: a blurred, filled copy behind the whole image.
                if let backdrop = Self.blurred(image) {
                    backdrop.draw(in: Self.fillRect(imageSize: backdrop.size, in: bounds, zoom: 1, offsetX: 0, offsetY: 0))
                }
                image.draw(in: Self.fitRect(imageSize: image.size, in: bounds, zoom: design.imageZoom, offsetX: design.imageOffsetX, offsetY: design.imageOffsetY))
            } else {
                image.draw(in: Self.fillRect(
                    imageSize: image.size, in: bounds,
                    zoom: design.imageZoom, offsetX: design.imageOffsetX, offsetY: design.imageOffsetY
                ))
            }
            context.restoreGState()
        } else if design.template.framesTextFront {
            // A simple double rule so a text-only cover still looks finished.
            let ink = design.template == .clothbound ? design.accentColor : design.baseColor.contrastingText
            let inset = bounds.width * 0.06
            context.setStrokeColor(ink.mixed(with: design.baseColor, amount: 0.45).cgColor)
            context.setLineWidth(max(bounds.width * 0.004, 1))
            context.stroke(bounds.insetBy(dx: inset, dy: inset))
            context.setLineWidth(max(bounds.width * 0.0015, 1))
            context.stroke(bounds.insetBy(dx: inset * 1.25, dy: inset * 1.25))
        } else {
            // Frameless fronts get one short rule in the text colour.
            context.setFillColor(design.baseColor.contrastingText.cgColor.copy(alpha: 0.6) ?? design.baseColor.contrastingText.cgColor)
            context.fill(CGRect(x: bounds.width * 0.1, y: bounds.height * 0.53, width: bounds.width * 0.22, height: max(bounds.height * 0.008, 2)))
        }
    }

    private func drawSpine(design: CoverDesign, blurred: UIImage?, in bounds: CGRect, context: CGContext) {
        context.setFillColor(design.spineColor.cgColor)
        context.fill(bounds)
        if let blurred {
            // Continue the cover's left edge round the spine.
            let height = bounds.height
            let width = blurred.size.width * height / max(blurred.size.height, 1)
            context.interpolationQuality = .high
            blurred.draw(in: CGRect(x: 0, y: 0, width: max(width, bounds.width), height: height))
        }
        if design.template == .clothbound {
            // Pairs of gilt bands near the head and foot.
            context.setFillColor(design.accentColor.cgColor)
            let band = max(bounds.height * 0.004, 1)
            for y in [0.07, 0.085, 0.915, 0.93] {
                context.fill(CGRect(x: 0, y: bounds.height * y, width: bounds.width, height: band))
            }
        }
    }

    private func drawBack(design: CoverDesign, blurred: UIImage?, in bounds: CGRect, context: CGContext) {
        context.setFillColor(design.backColor.cgColor)
        context.fill(bounds)
        if let blurred {
            context.saveGState()
            // Mirror so the colours meet the spine the way they leave the front.
            context.translateBy(x: bounds.width, y: 0)
            context.scaleBy(x: -1, y: 1)
            context.interpolationQuality = .high
            blurred.draw(in: Self.fillRect(imageSize: blurred.size, in: bounds, zoom: 1, offsetX: 0, offsetY: 0))
            context.restoreGState()
            context.setFillColor(UIColor.black.withAlphaComponent(0.18).cgColor)
            context.fill(bounds)
        }
    }

    /// Soft shading where the jacket bends, so the faces read as a real book.
    private func drawShading(for face: CoverFace, in bounds: CGRect, context: CGContext) {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return }
        func gradient(_ stops: [(CGFloat, CGFloat)]) -> CGGradient? {
            let colors = stops.map { UIColor.black.withAlphaComponent($0.1).cgColor } as CFArray
            return CGGradient(colorsSpace: space, colors: colors, locations: stops.map { $0.0 })
        }
        context.saveGState()
        switch face {
        case .front:
            // The hinge runs down the left edge of the front.
            if let g = gradient([(0, 0.18), (0.02, 0.04), (0.035, 0)]) {
                context.drawLinearGradient(g, start: .zero, end: CGPoint(x: bounds.width, y: 0), options: [])
            }
        case .back:
            if let g = gradient([(0.965, 0), (0.98, 0.04), (1, 0.18)]) {
                context.drawLinearGradient(g, start: .zero, end: CGPoint(x: bounds.width, y: 0), options: [])
            }
        case .spine:
            // Rounded spine: darker at both edges, lighter just left of centre.
            if let g = gradient([(0, 0.24), (0.15, 0.05), (0.4, 0), (0.8, 0.05), (1, 0.22)]) {
                context.drawLinearGradient(g, start: .zero, end: CGPoint(x: bounds.width, y: 0), options: [])
            }
        }
        context.restoreGState()
    }

    // MARK: - Text

    private func draw(_ box: CoverTextBox, faceBounds: CGRect, context: CGContext) {
        let text = box.isUppercased ? box.text.localizedUppercase : box.text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let rect = Self.rect(for: box, in: faceBounds.size)
        let layout = box.isVertical ? CGSize(width: rect.height, height: rect.width) : rect.size
        guard layout.width > 1, layout.height > 1 else { return }

        let attributed = Self.fittedText(text, box: box, pointSize: box.fontSize * frontWidth, in: layout)
        let measured = attributed.boundingRect(
            with: CGSize(width: layout.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )

        context.saveGState()
        context.translateBy(x: rect.midX, y: rect.midY)
        if box.isVertical {
            context.rotate(by: .pi / 2)
        }
        if box.hasShadow {
            let size = box.fontSize * frontWidth
            context.setShadow(
                offset: CGSize(width: 0, height: size * 0.04),
                blur: size * 0.18,
                color: UIColor.black.withAlphaComponent(0.6).cgColor
            )
        }
        let drawRect = CGRect(
            x: -layout.width / 2,
            y: -min(measured.height, layout.height) / 2,
            width: layout.width,
            height: min(measured.height, layout.height) + 1
        )
        attributed.draw(with: drawRect, options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine], context: nil)
        context.restoreGState()
    }

    /// Shrinks the text until it fits the box, down to a third of its size.
    static func fittedText(_ text: String, box: CoverTextBox, pointSize: CGFloat, in layout: CGSize) -> NSAttributedString {
        var size = pointSize
        let minimum = pointSize / 3
        // Spine text reads best on one line: shrink a little to get there
        // before falling back to wrapping.
        if box.isVertical {
            var single = pointSize
            while single >= pointSize * 0.6 {
                let line = attributedText(text, box: box, pointSize: single)
                let width = line.boundingRect(
                    with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    context: nil
                ).width
                let height = line.boundingRect(
                    with: CGSize(width: layout.width, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    context: nil
                ).height
                if width <= layout.width, height <= layout.height { return line }
                single *= 0.92
            }
        }
        var attributed = attributedText(text, box: box, pointSize: size)
        while size > minimum {
            let bounds = attributed.boundingRect(
                with: CGSize(width: layout.width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            )
            if bounds.height <= layout.height, longestWordFits(text, box: box, pointSize: size, width: layout.width) {
                break
            }
            size *= 0.92
            attributed = attributedText(text, box: box, pointSize: size)
        }
        return attributed
    }

    private static func longestWordFits(_ text: String, box: CoverTextBox, pointSize: CGFloat, width: CGFloat) -> Bool {
        let font = font(box.font, weight: box.weight, size: pointSize)
        let longest = text.split(whereSeparator: \.isWhitespace).max(by: { $0.count < $1.count }) ?? ""
        let measured = (String(longest) as NSString).size(withAttributes: [.font: font])
        return measured.width <= width
    }

    static func attributedText(_ text: String, box: CoverTextBox, pointSize: CGFloat) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = switch box.alignment {
        case .leading: .left
        case .center: .center
        case .trailing: .right
        }
        paragraph.lineBreakMode = .byWordWrapping
        // Avoids one-word last lines on titles.
        paragraph.lineBreakStrategy = .standard
        paragraph.lineHeightMultiple = box.role == .blurb ? 1.15 : 0.95
        return NSAttributedString(string: text, attributes: [
            .font: font(box.font, weight: box.weight, size: pointSize),
            .foregroundColor: UIColor(cgColor: box.color.cgColor),
            .paragraphStyle: paragraph,
            .kern: box.isUppercased ? pointSize * 0.06 : 0,
        ])
    }

    static func font(_ font: CoverFont, weight: CoverFontWeight, size: CGFloat) -> UIFont {
        let uiWeight: UIFont.Weight = switch weight {
        case .regular: .regular
        case .medium: .medium
        case .bold: .bold
        case .heavy: .heavy
        }
        if let family = font.familyName {
            var descriptor = UIFontDescriptor(fontAttributes: [.family: family])
            if weight == .bold || weight == .heavy,
               let bold = descriptor.withSymbolicTraits(.traitBold) {
                descriptor = bold
            }
            return UIFont(descriptor: descriptor, size: size)
        }
        let system = UIFont.systemFont(ofSize: size, weight: uiWeight)
        let design: UIFontDescriptor.SystemDesign = switch font {
        case .serif: .serif
        case .rounded: .rounded
        default: .default
        }
        guard let descriptor = system.fontDescriptor.withDesign(design) else { return system }
        return UIFont(descriptor: descriptor, size: size)
    }

    // MARK: - Geometry

    /// A text box's frame in pixels on a face of the given size.
    public static func rect(for box: CoverTextBox, in faceSize: CGSize) -> CGRect {
        CGRect(
            x: (box.centerX - box.width / 2) * faceSize.width,
            y: (box.centerY - box.height / 2) * faceSize.height,
            width: box.width * faceSize.width,
            height: box.height * faceSize.height
        )
    }

    /// Where to draw an image so it fills `bounds`, zoomed and panned.
    /// Offsets run from -1 (left or top edge) to 1 (right or bottom edge).
    public static func fillRect(imageSize: CGSize, in bounds: CGRect, zoom: Double, offsetX: Double, offsetY: Double) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return bounds }
        let scale = max(bounds.width / imageSize.width, bounds.height / imageSize.height) * max(zoom, 1)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let spareX = (size.width - bounds.width) / 2
        let spareY = (size.height - bounds.height) / 2
        let dx = min(max(offsetX, -1), 1)
        let dy = min(max(offsetY, -1), 1)
        return CGRect(
            x: bounds.midX - size.width / 2 - dx * spareX,
            y: bounds.midY - size.height / 2 - dy * spareY,
            width: size.width,
            height: size.height
        )
    }

    /// Where to draw an image so all of it shows inside `bounds`, centred,
    /// then zoomed and panned like `fillRect`.
    public static func fitRect(imageSize: CGSize, in bounds: CGRect, zoom: Double, offsetX: Double, offsetY: Double) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return bounds }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height) * max(zoom, 1)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let spareX = max((size.width - bounds.width) / 2, 0)
        let spareY = max((size.height - bounds.height) / 2, 0)
        return CGRect(
            x: bounds.midX - size.width / 2 - min(max(offsetX, -1), 1) * spareX,
            y: bounds.midY - size.height / 2 - min(max(offsetY, -1), 1) * spareY,
            width: size.width,
            height: size.height
        )
    }

    /// A heavy, smooth blur of a small copy of the image, for the
    /// wraparound back and spine.
    static func blurred(_ image: UIImage) -> UIImage? {
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        let small = CGSize(width: 160, height: max((160 * image.size.height / image.size.width).rounded(), 1))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let shrunk = UIGraphicsImageRenderer(size: small, format: format).image { context in
            context.cgContext.interpolationQuality = .high
            image.draw(in: CGRect(origin: .zero, size: small))
        }
        guard let cgImage = shrunk.cgImage else { return shrunk }
        let input = CIImage(cgImage: cgImage)
        let output = input.clampedToExtent()
            .applyingGaussianBlur(sigma: 9)
            .cropped(to: input.extent)
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let blurred = context.createCGImage(output, from: input.extent) else { return shrunk }
        return UIImage(cgImage: blurred)
    }
}

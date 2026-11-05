import Foundation

/// Colours picked from a cover image (or generated) that templates build on.
public struct CoverPalette: Hashable, Sendable {
    /// The image's overall colour.
    public var base: RGBAColor
    /// The colour along the image's left edge, which continues onto the spine.
    public var edge: RGBAColor
    /// The most saturated common colour, for small details.
    public var accent: RGBAColor

    public init(base: RGBAColor, edge: RGBAColor, accent: RGBAColor) {
        self.base = base
        self.edge = edge
        self.accent = accent
    }

    /// A palette for a book with no artwork, stable for the same title.
    public static func generated(for title: String) -> CoverPalette {
        let base = RGBAColor.generated(for: title)
        return CoverPalette(base: base, edge: base, accent: base.lightened(0.35))
    }
}

/// Ready-made looks for the spine and back (and the front, when there's no
/// image). Picking one lays out the title, author and blurb; everything stays
/// editable afterwards.
public enum CoverTemplate: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Spine in the cover's edge colour, plain back with the blurb.
    case classic
    /// The cover image continues, blurred, across the spine and back.
    case wraparound
    /// Dark cloth with gold lettering and bands, like a hardback without its jacket.
    case clothbound
    /// Cream spine and back with simple dark type.
    case minimal
    /// No image: a bold typographic front in a solid colour.
    case typographic

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .classic: String(localized: "Classic")
        case .wraparound: String(localized: "Wraparound")
        case .clothbound: String(localized: "Clothbound")
        case .minimal: String(localized: "Minimal")
        case .typographic: String(localized: "Text only")
        }
    }

    /// Whether the front shows the cover image under this template.
    public var showsImageOnFront: Bool { self != .typographic }

    /// The template a new book starts with.
    public static func defaultTemplate(hasImage: Bool) -> CoverTemplate {
        hasImage ? .classic : .typographic
    }

    // MARK: - Building designs

    /// A complete design for a book, with this template's colours and text.
    public func makeDesign(
        seed: CoverSeed,
        palette: CoverPalette,
        imageSource: CoverImageSource
    ) -> CoverDesign {
        let colors = colors(for: palette, hasImage: imageSource != .none)
        var design = CoverDesign(
            template: self,
            imageSource: imageSource,
            baseColor: colors.front,
            spineColor: colors.spine,
            backColor: colors.back,
            accentColor: colors.accent,
            thickness: CoverDesign.thickness(forPageCount: seed.estimatedPageCount)
        )
        design.textBoxes = textBoxes(seed: seed, design: design)
        return design
    }

    /// Switches an existing design to this template. The image, its crop, the
    /// thickness and any custom text boxes are kept; title, author, series and
    /// blurb are laid out again but keep any wording the user changed.
    public func apply(to design: CoverDesign, seed: CoverSeed, palette: CoverPalette) -> CoverDesign {
        var result = design
        let colors = colors(for: palette, hasImage: design.hasImage)
        result.template = self
        result.baseColor = colors.front
        result.spineColor = colors.spine
        result.backColor = colors.back
        result.accentColor = colors.accent

        var edited = seed
        if let title = design.textBoxes.first(where: { $0.role == .title })?.text { edited.title = title }
        if let author = design.textBoxes.first(where: { $0.role == .author })?.text { edited.authors = [author] }
        if let blurb = design.textBoxes.first(where: { $0.role == .blurb })?.text { edited.summary = blurb }
        let customSeries = design.textBoxes.first(where: { $0.role == .series })?.text

        var boxes = textBoxes(seed: edited, design: result)
        if let customSeries {
            for index in boxes.indices where boxes[index].role == .series {
                boxes[index].text = customSeries
            }
        }
        result.textBoxes = boxes + design.textBoxes.filter { $0.role == .custom }
        return result
    }

    struct Colors {
        /// The front's fill. With an image this is the image's own colour.
        var front: RGBAColor
        var spine: RGBAColor
        var back: RGBAColor
        var accent: RGBAColor
    }

    /// Spine and back follow the front, so the jacket reads as one book.
    func colors(for palette: CoverPalette, hasImage: Bool) -> Colors {
        let image = hasImage && showsImageOnFront
        let cloth = palette.base.mixed(with: RGBAColor(red: 0.12, green: 0.1, blue: 0.09), amount: 0.6)
        return switch self {
        case .classic:
            Colors(front: palette.base, spine: palette.edge, back: palette.base, accent: palette.accent)
        case .wraparound:
            Colors(front: palette.base, spine: palette.edge, back: palette.base, accent: palette.accent)
        case .clothbound:
            Colors(front: image ? palette.base : cloth, spine: cloth, back: cloth, accent: .gold)
        case .minimal:
            Colors(front: image ? palette.base : .cream, spine: .cream, back: .cream, accent: palette.accent)
        case .typographic:
            Colors(front: palette.base, spine: palette.base, back: palette.base, accent: palette.accent)
        }
    }

    private var font: CoverFont {
        switch self {
        case .classic, .wraparound: .serif
        case .clothbound: .baskerville
        case .minimal: .sans
        case .typographic: .didot
        }
    }

    func textBoxes(seed: CoverSeed, design: CoverDesign) -> [CoverTextBox] {
        let spineText = self == .clothbound ? RGBAColor.gold : design.spineColor.contrastingText
        let backText = self == .clothbound ? RGBAColor.gold : design.backColor.contrastingText
        let frontColor = design.baseColor
        let shadow = self == .wraparound && design.hasImage
        let uppercase = self == .clothbound
        let gilt = self == .clothbound
        var boxes: [CoverTextBox] = []

        // Front: only when there's no image to carry the title.
        if !(design.hasImage && showsImageOnFront) {
            let ink = gilt ? RGBAColor.gold : frontColor.contrastingText
            // Narrower than the face so the title clears the double rule.
            boxes.append(CoverTextBox(
                face: .front, role: .title, text: seed.title,
                centerY: 0.36, width: 0.74, height: 0.36,
                font: font, weight: .bold, fontSize: 0.12, color: ink,
                isUppercased: uppercase
            ))
            if !seed.authorLine.isEmpty {
                boxes.append(CoverTextBox(
                    face: .front, role: .author, text: seed.authorLine,
                    centerY: 0.8, width: 0.74, height: 0.1,
                    font: font, weight: .medium, fontSize: 0.055, color: ink,
                    isUppercased: true
                ))
            }
            if let series = seed.seriesLine {
                boxes.append(CoverTextBox(
                    face: .front, role: .series, text: series,
                    centerY: 0.62, width: 0.74, height: 0.07,
                    font: font, weight: .medium, fontSize: 0.045, color: ink
                ))
            }
        }

        // Spine: title reading top to bottom, author near the foot.
        let spineFont = min(0.06, design.thickness * 0.5)
        let hasAuthor = !seed.authorLine.isEmpty
        // Clothbound spines keep clear of the gilt bands at head and foot.
        let titleSpan = gilt ? (hasAuthor ? 0.12...0.68 : 0.12...0.88) : (hasAuthor ? 0.07...0.73 : 0.08...0.92)
        let authorSpan = gilt ? 0.72...0.88 : 0.77...0.95
        boxes.append(CoverTextBox(
            face: .spine, role: .title, text: seed.title,
            centerY: (titleSpan.lowerBound + titleSpan.upperBound) / 2, width: 0.8,
            height: titleSpan.upperBound - titleSpan.lowerBound,
            font: font, weight: .bold, fontSize: spineFont, color: spineText,
            isVertical: true, isUppercased: uppercase, hasShadow: shadow
        ))
        if hasAuthor {
            boxes.append(CoverTextBox(
                face: .spine, role: .author, text: seed.authors.first ?? seed.authorLine,
                centerY: (authorSpan.lowerBound + authorSpan.upperBound) / 2, width: 0.7,
                height: authorSpan.upperBound - authorSpan.lowerBound,
                font: font, weight: font == .didot ? .bold : .medium, fontSize: spineFont * 0.7, color: spineText,
                isVertical: true, isUppercased: true, hasShadow: shadow
            ))
        }

        // Back: title, blurb, author.
        boxes.append(CoverTextBox(
            face: .back, role: .title, text: seed.title,
            centerY: 0.11, width: 0.8, height: 0.1,
            font: font, weight: .bold, fontSize: 0.065, color: backText,
            isUppercased: uppercase, hasShadow: shadow
        ))
        if let blurb = seed.blurb {
            boxes.append(CoverTextBox(
                face: .back, role: .blurb, text: blurb,
                centerY: 0.44, width: 0.8, height: 0.5,
                font: self == .minimal ? .sans : .serif, weight: .regular, fontSize: 0.038,
                color: backText, alignment: .leading, hasShadow: shadow
            ))
        }
        if hasAuthor {
            boxes.append(CoverTextBox(
                face: .back, role: .author, text: seed.authorLine,
                centerY: 0.88, width: 0.84, height: 0.07,
                font: font, weight: .medium, fontSize: 0.04, color: backText,
                isUppercased: true, hasShadow: shadow
            ))
        }
        return boxes
    }
}

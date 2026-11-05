import Foundation

/// One side of a book's jacket.
public enum CoverFace: String, Codable, CaseIterable, Sendable, Identifiable {
    case front
    case spine
    case back

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .front: String(localized: "Front")
        case .spine: String(localized: "Spine")
        case .back: String(localized: "Back")
        }
    }
}

/// Typefaces offered for cover text. All ship with iOS, so nothing is bundled.
public enum CoverFont: String, Codable, CaseIterable, Sendable, Identifiable {
    case serif
    case sans
    case rounded
    case condensed
    case didot
    case baskerville
    case futura
    case typewriter
    case copperplate
    case script

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .serif: String(localized: "New York")
        case .sans: String(localized: "SF Pro")
        case .rounded: String(localized: "Rounded")
        case .condensed: String(localized: "Condensed")
        case .didot: "Didot"
        case .baskerville: "Baskerville"
        case .futura: "Futura"
        case .typewriter: String(localized: "Typewriter")
        case .copperplate: "Copperplate"
        case .script: String(localized: "Script")
        }
    }

    /// The installed font family, or nil for the system font designs.
    public var familyName: String? {
        switch self {
        case .serif, .sans, .rounded: nil
        case .condensed: "Avenir Next Condensed"
        case .didot: "Didot"
        case .baskerville: "Baskerville"
        case .futura: "Futura"
        case .typewriter: "American Typewriter"
        case .copperplate: "Copperplate"
        case .script: "Snell Roundhand"
        }
    }
}

public enum CoverFontWeight: String, Codable, CaseIterable, Sendable, Identifiable {
    case regular
    case medium
    case bold
    case heavy

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .regular: String(localized: "Regular")
        case .medium: String(localized: "Medium")
        case .bold: String(localized: "Bold")
        case .heavy: String(localized: "Heavy")
        }
    }
}

public enum CoverTextAlignment: String, Codable, CaseIterable, Sendable, Identifiable {
    case leading
    case center
    case trailing

    public var id: String { rawValue }
}

/// A piece of text placed on one face of the cover.
///
/// Positions are in unit coordinates of the face (0 to 1, origin top left) so
/// a design renders the same at any resolution. Font size is a fraction of the
/// front cover's width, so text on the spine and the front match.
public struct CoverTextBox: Codable, Hashable, Sendable, Identifiable {
    /// What the text is for, so switching templates can move it sensibly.
    public enum Role: String, Codable, Sendable {
        case title
        case author
        case series
        case blurb
        case custom
    }

    public var id: UUID
    public var face: CoverFace
    public var role: Role
    public var text: String
    public var centerX: Double
    public var centerY: Double
    public var width: Double
    public var height: Double
    public var font: CoverFont
    public var weight: CoverFontWeight
    public var fontSize: Double
    public var color: RGBAColor
    public var alignment: CoverTextAlignment
    /// Runs top to bottom, as on English-language spines.
    public var isVertical: Bool
    public var isUppercased: Bool
    public var hasShadow: Bool

    public init(
        id: UUID = UUID(),
        face: CoverFace,
        role: Role = .custom,
        text: String,
        centerX: Double = 0.5,
        centerY: Double = 0.5,
        width: Double = 0.8,
        height: Double = 0.15,
        font: CoverFont = .serif,
        weight: CoverFontWeight = .regular,
        fontSize: Double = 0.08,
        color: RGBAColor = .ink,
        alignment: CoverTextAlignment = .center,
        isVertical: Bool = false,
        isUppercased: Bool = false,
        hasShadow: Bool = false
    ) {
        self.id = id
        self.face = face
        self.role = role
        self.text = text
        self.centerX = centerX
        self.centerY = centerY
        self.width = width
        self.height = height
        self.font = font
        self.weight = weight
        self.fontSize = fontSize
        self.color = color
        self.alignment = alignment
        self.isVertical = isVertical
        self.isUppercased = isUppercased
        self.hasShadow = hasShadow
    }

    /// The smallest a box can be, so it stays grabbable.
    public static let minimumSide = 0.04
    public static let fontSizeRange = 0.015...0.3

    /// Keeps the box inside its face and at a usable size.
    public mutating func clamp() {
        width = min(max(width, Self.minimumSide), 1)
        height = min(max(height, Self.minimumSide), 1)
        centerX = min(max(centerX, width / 2), 1 - width / 2)
        centerY = min(max(centerY, height / 2), 1 - height / 2)
        fontSize = min(max(fontSize, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
    }
}

/// Where the front image came from, kept so the editor can say so and so a
/// default cover can be told apart from one the user chose.
public enum CoverImageSource: Codable, Hashable, Sendable {
    /// No image: the front is drawn from the template and text alone.
    case none
    /// The cover that came inside the file.
    case embedded
    /// Picked from a cover search.
    case search(provider: String, url: URL)
    /// From the user's photos or files.
    case userImage
}

/// Everything needed to draw a book's jacket. The front image itself is
/// stored next to the design as a file, not inside it.
public struct CoverDesign: Codable, Hashable, Sendable {
    /// Raised when the default layouts change, so automatic designs made
    /// with older ones are rebuilt. 2: larger spine author text.
    public static let currentVersion = 2

    /// The width-to-height ratio of every front cover.
    public static let frontAspectRatio = 2.0 / 3.0
    /// Spine width as a fraction of the front's width.
    public static let thicknessRange = 0.04...0.35

    public var version: Int
    public var template: CoverTemplate
    public var imageSource: CoverImageSource
    /// 1 fills the front exactly; larger zooms in.
    public var imageZoom: Double
    /// Pan of the zoomed image, -1 to 1 on each axis (0 is centred).
    public var imageOffsetX: Double
    public var imageOffsetY: Double
    /// The main colour of the cover, sampled from the image or generated.
    /// Used behind the cover wherever it's letterboxed (e.g. the outer display).
    public var baseColor: RGBAColor
    public var spineColor: RGBAColor
    public var backColor: RGBAColor
    public var accentColor: RGBAColor
    public var textBoxes: [CoverTextBox]
    /// Spine width as a fraction of the front cover's width.
    public var thickness: Double
    /// False while the design is still the automatic default. Once the user
    /// saves an edit it's theirs, and new metadata never overwrites it.
    public var isUserEdited: Bool
    /// For automatic designs, a fingerprint of the metadata they were built
    /// from, so they can be rebuilt when the metadata changes.
    public var seedFingerprint: String?
    /// How big the book is next to others, 1 being standard. Nil in designs
    /// saved before sizes existed; `sizeScale(for:)` fills in a default.
    public var heightScale: Double?
    /// Fit the whole image on the front (over a blurred copy of itself)
    /// instead of filling and cropping. Nil means fill.
    public var fitsWholeImage: Bool?

    public init(
        template: CoverTemplate,
        imageSource: CoverImageSource,
        baseColor: RGBAColor,
        spineColor: RGBAColor,
        backColor: RGBAColor,
        accentColor: RGBAColor,
        textBoxes: [CoverTextBox] = [],
        thickness: Double = 0.12,
        imageZoom: Double = 1,
        imageOffsetX: Double = 0,
        imageOffsetY: Double = 0,
        isUserEdited: Bool = false
    ) {
        self.version = Self.currentVersion
        self.template = template
        self.imageSource = imageSource
        self.baseColor = baseColor
        self.spineColor = spineColor
        self.backColor = backColor
        self.accentColor = accentColor
        self.textBoxes = textBoxes
        self.thickness = min(max(thickness, Self.thicknessRange.lowerBound), Self.thicknessRange.upperBound)
        self.imageZoom = imageZoom
        self.imageOffsetX = imageOffsetX
        self.imageOffsetY = imageOffsetY
        self.isUserEdited = isUserEdited
    }

    public var hasImage: Bool { imageSource != .none }

    /// Book sizes the user can pick, relative to a standard paperback.
    public static let heightScaleRange = 0.8...1.15

    /// The book's size: the user's choice, or a small, stable variation per
    /// book so a shelf isn't a row of identical blocks.
    public func sizeScale(for bookID: UUID) -> Double {
        if let heightScale {
            return min(max(heightScale, Self.heightScaleRange.lowerBound), Self.heightScaleRange.upperBound)
        }
        return Self.defaultHeightScale(for: bookID)
    }

    /// 0.93 to 1.05, picked from the book's ID so it never changes.
    public static func defaultHeightScale(for bookID: UUID) -> Double {
        let bytes = bookID.uuid
        let value = (Int(bytes.0) << 8 | Int(bytes.1)) % 1000
        return 0.93 + Double(value) / 999 * 0.12
    }

    public func textBoxes(on face: CoverFace) -> [CoverTextBox] {
        textBoxes.filter { $0.face == face }
    }

    /// Spine width as a fraction of the front's width, from an estimated page
    /// count. A 300-page paperback comes out at about 0.12.
    public static func thickness(forPageCount pages: Int) -> Double {
        let value = 0.02 + Double(max(pages, 0)) / 300 * 0.10
        return min(max(value, thicknessRange.lowerBound), thicknessRange.upperBound)
    }
}

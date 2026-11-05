import Foundation

/// How a book looks and behaves while reading: the Kindle-style settings.
///
/// One set applies to every book. It's stored as JSON, and decoding tolerates
/// missing keys, so adding a setting later never resets the rest.
public struct ReaderSettings: Codable, Equatable, Sendable {
    // MARK: Colour

    public var theme: ReaderTheme = .light
    /// Switch to `darkTheme` while the system is in Dark Mode.
    public var followsSystemAppearance = true
    /// Theme used in Dark Mode when `followsSystemAppearance` is on.
    public var darkTheme: ReaderTheme = .dark
    /// Colours for `ReaderTheme.custom`, as `RRGGBB` hex.
    public var customBackgroundHex = "F5EFE0"
    public var customTextHex = "2B2B2B"
    /// Invert images (diagrams, maps) on dark themes instead of dimming them.
    public var invertsImagesInDarkThemes = false

    // MARK: Text

    public var font: ReaderFont = .publisher
    /// Text size as a multiple of the book's own size, 1 = 100%.
    public var fontScale: Double = 1.0
    /// Text weight, 1 = normal. Above 1 is bolder.
    public var fontWeight: Double = 1.0
    /// Use the book's own spacing, alignment and indents. Turn off to apply
    /// the spacing settings below.
    public var usesPublisherStyles = true
    /// Line height as a multiple of the font size.
    public var lineHeight: Double = 1.5
    /// Space between paragraphs, in em.
    public var paragraphSpacing: Double = 0.5
    /// First-line indent, in em.
    public var paragraphIndent: Double = 1.0
    /// Extra space between words, in em.
    public var wordSpacing: Double = 0
    /// Extra space between letters, in em.
    public var letterSpacing: Double = 0
    public var alignment: ReaderAlignment = .publisher
    public var hyphenation = false

    // MARK: Layout

    /// Side margins as a multiple of the default, 1 = default.
    public var margins: Double = 1.0
    public var flow: ReaderFlow = .paged
    /// One page or two side by side when there's room.
    public var spread: ReaderSpread = .automatic

    // MARK: Page turning

    public var pageTurn: PageTurnStyle = .slide
    public var tapZones: TapZoneMode = .backAndForward

    public init() {}

    public static let `default` = ReaderSettings()

    // MARK: Ranges

    public static let fontScaleRange = 0.6 ... 3.0
    public static let fontWeightRange = 0.6 ... 2.0
    // Line height and paragraph ranges match Readium's own editor ranges.
    public static let lineHeightRange = 1.0 ... 2.0
    public static let paragraphSpacingRange = 0.0 ... 2.0
    public static let paragraphIndentRange = 0.0 ... 3.0
    public static let wordSpacingRange = 0.0 ... 1.0
    public static let letterSpacingRange = 0.0 ... 0.5
    public static let marginsRange = 0.0 ... 4.0

    /// Returns a copy with every number pulled into its range, so a hand-edited
    /// or old stored value can't break layout.
    public func clamped() -> ReaderSettings {
        var copy = self
        copy.fontScale = fontScale.limited(to: Self.fontScaleRange)
        copy.fontWeight = fontWeight.limited(to: Self.fontWeightRange)
        copy.lineHeight = lineHeight.limited(to: Self.lineHeightRange)
        copy.paragraphSpacing = paragraphSpacing.limited(to: Self.paragraphSpacingRange)
        copy.paragraphIndent = paragraphIndent.limited(to: Self.paragraphIndentRange)
        copy.wordSpacing = wordSpacing.limited(to: Self.wordSpacingRange)
        copy.letterSpacing = letterSpacing.limited(to: Self.letterSpacingRange)
        copy.margins = margins.limited(to: Self.marginsRange)
        if ReaderColor(hex: customBackgroundHex) == nil { copy.customBackgroundHex = Self.default.customBackgroundHex }
        if ReaderColor(hex: customTextHex) == nil { copy.customTextHex = Self.default.customTextHex }
        return copy
    }

    /// The theme to draw with, given whether the system is in Dark Mode.
    public func effectiveTheme(systemIsDark: Bool) -> ReaderTheme {
        followsSystemAppearance && systemIsDark ? darkTheme : theme
    }

    /// Background and text colours for a theme.
    public func colors(for theme: ReaderTheme) -> ReaderPalette {
        switch theme {
        case .custom:
            let background = ReaderColor(hex: customBackgroundHex) ?? ReaderTheme.light.palette.background
            let text = ReaderColor(hex: customTextHex) ?? ReaderTheme.light.palette.text
            return ReaderPalette(background: background, text: text)
        default:
            return theme.palette
        }
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case theme, followsSystemAppearance, darkTheme, customBackgroundHex, customTextHex, invertsImagesInDarkThemes
        case font, fontScale, fontWeight, usesPublisherStyles, lineHeight, paragraphSpacing, paragraphIndent
        case wordSpacing, letterSpacing, alignment, hyphenation
        case margins, flow, spread, pageTurn, tapZones
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ReaderSettings.default
        // `try?` per key: an unknown enum case from a newer version falls back
        // to the default instead of failing the whole decode.
        theme = (try? c.decodeIfPresent(ReaderTheme.self, forKey: .theme)) ?? d.theme
        followsSystemAppearance = (try? c.decodeIfPresent(Bool.self, forKey: .followsSystemAppearance)) ?? d.followsSystemAppearance
        darkTheme = (try? c.decodeIfPresent(ReaderTheme.self, forKey: .darkTheme)) ?? d.darkTheme
        customBackgroundHex = (try? c.decodeIfPresent(String.self, forKey: .customBackgroundHex)) ?? d.customBackgroundHex
        customTextHex = (try? c.decodeIfPresent(String.self, forKey: .customTextHex)) ?? d.customTextHex
        invertsImagesInDarkThemes = (try? c.decodeIfPresent(Bool.self, forKey: .invertsImagesInDarkThemes)) ?? d.invertsImagesInDarkThemes
        font = (try? c.decodeIfPresent(ReaderFont.self, forKey: .font)) ?? d.font
        fontScale = (try? c.decodeIfPresent(Double.self, forKey: .fontScale)) ?? d.fontScale
        fontWeight = (try? c.decodeIfPresent(Double.self, forKey: .fontWeight)) ?? d.fontWeight
        usesPublisherStyles = (try? c.decodeIfPresent(Bool.self, forKey: .usesPublisherStyles)) ?? d.usesPublisherStyles
        lineHeight = (try? c.decodeIfPresent(Double.self, forKey: .lineHeight)) ?? d.lineHeight
        paragraphSpacing = (try? c.decodeIfPresent(Double.self, forKey: .paragraphSpacing)) ?? d.paragraphSpacing
        paragraphIndent = (try? c.decodeIfPresent(Double.self, forKey: .paragraphIndent)) ?? d.paragraphIndent
        wordSpacing = (try? c.decodeIfPresent(Double.self, forKey: .wordSpacing)) ?? d.wordSpacing
        letterSpacing = (try? c.decodeIfPresent(Double.self, forKey: .letterSpacing)) ?? d.letterSpacing
        alignment = (try? c.decodeIfPresent(ReaderAlignment.self, forKey: .alignment)) ?? d.alignment
        hyphenation = (try? c.decodeIfPresent(Bool.self, forKey: .hyphenation)) ?? d.hyphenation
        margins = (try? c.decodeIfPresent(Double.self, forKey: .margins)) ?? d.margins
        flow = (try? c.decodeIfPresent(ReaderFlow.self, forKey: .flow)) ?? d.flow
        spread = (try? c.decodeIfPresent(ReaderSpread.self, forKey: .spread)) ?? d.spread
        pageTurn = (try? c.decodeIfPresent(PageTurnStyle.self, forKey: .pageTurn)) ?? d.pageTurn
        tapZones = (try? c.decodeIfPresent(TapZoneMode.self, forKey: .tapZones)) ?? d.tapZones
        self = clamped()
    }
}

// MARK: - Options

public enum ReaderTheme: String, Codable, CaseIterable, Sendable, Identifiable {
    case light, sepia, green, gray, dark, custom

    public var id: Self { self }

    /// Whether the theme has light text on a dark page.
    public var isDark: Bool {
        switch self {
        case .gray, .dark: true
        case .light, .sepia, .green, .custom: false
        }
    }

    /// Built-in colours. `custom` returns the light palette; use
    /// `ReaderSettings.colors(for:)` to get the user's custom colours.
    public var palette: ReaderPalette {
        switch self {
        case .light, .custom: ReaderPalette(background: ReaderColor(0xFFFFFF), text: ReaderColor(0x1C1C1E))
        case .sepia: ReaderPalette(background: ReaderColor(0xF7EFDF), text: ReaderColor(0x4A3B2A))
        case .green: ReaderPalette(background: ReaderColor(0xDDEEDB), text: ReaderColor(0x1F2E1E))
        case .gray: ReaderPalette(background: ReaderColor(0x3A3A3C), text: ReaderColor(0xE6E6E8))
        case .dark: ReaderPalette(background: ReaderColor(0x000000), text: ReaderColor(0xCFCFD1))
        }
    }
}

public enum ReaderFont: String, Codable, CaseIterable, Sendable, Identifiable {
    /// The book's own fonts.
    case publisher
    /// San Francisco.
    case system
    /// New York.
    case newYork
    case georgia
    case palatino
    case iowan
    case charter
    case athelas
    case avenirNext
    /// OpenDyslexic, which ships with the reader engine.
    case openDyslexic

    public var id: Self { self }

    /// CSS `font-family` value, or nil for the book's own fonts.
    public var cssFamily: String? {
        switch self {
        case .publisher: nil
        case .system: "-apple-system"
        case .newYork: "ui-serif"
        case .georgia: "Georgia"
        case .palatino: "Palatino"
        case .iowan: "Iowan Old Style"
        case .charter: "Charter"
        case .athelas: "Athelas"
        case .avenirNext: "Avenir Next"
        case .openDyslexic: "OpenDyslexic"
        }
    }
}

public enum ReaderAlignment: String, Codable, CaseIterable, Sendable, Identifiable {
    case publisher, start, justify
    public var id: Self { self }
}

public enum ReaderFlow: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Turn pages.
    case paged
    /// Scroll continuously, like a web page.
    case scroll
    public var id: Self { self }
}

public enum ReaderSpread: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Two pages when the window is wide enough, otherwise one.
    case automatic
    case single
    case double
    public var id: Self { self }
}

public enum PageTurnStyle: String, Codable, CaseIterable, Sendable, Identifiable {
    case slide, curl, fade, none
    public var id: Self { self }
}

public enum TapZoneMode: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Left goes back, right goes forward.
    case backAndForward
    /// Either side goes forward, for one-handed reading.
    case forwardOnly
    /// Taps only show and hide the controls.
    case off
    public var id: Self { self }
}

// MARK: - Colour

/// An opaque RGB colour, independent of UIKit so it can be tested and stored.
public struct ReaderColor: Equatable, Hashable, Sendable {
    public var rgb: UInt32

    public init(_ rgb: UInt32) {
        self.rgb = rgb & 0xFFFFFF
    }

    /// Parses `RRGGBB` or `#RRGGBB`.
    public init?(hex: String) {
        var string = hex.trimmingCharacters(in: .whitespaces)
        if string.hasPrefix("#") { string.removeFirst() }
        guard string.count == 6, let value = UInt32(string, radix: 16) else { return nil }
        self.init(value)
    }

    public var hex: String { String(format: "%06X", rgb) }
    public var red: Double { Double((rgb >> 16) & 0xFF) / 255 }
    public var green: Double { Double((rgb >> 8) & 0xFF) / 255 }
    public var blue: Double { Double(rgb & 0xFF) / 255 }

    /// WCAG relative luminance, 0 (black) to 1 (white).
    public var luminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG contrast ratio between two colours, from 1 to 21.
    public func contrastRatio(with other: ReaderColor) -> Double {
        let (l1, l2) = (max(luminance, other.luminance), min(luminance, other.luminance))
        return (l1 + 0.05) / (l2 + 0.05)
    }
}

public struct ReaderPalette: Equatable, Sendable {
    public var background: ReaderColor
    public var text: ReaderColor

    /// Whether the page is dark, judged from the background.
    public var isDark: Bool { background.luminance < 0.2 }
}

extension Double {
    /// Pulls the value into `range`; NaN and infinity become the lower bound.
    func limited(to range: ClosedRange<Double>) -> Double {
        guard isFinite else { return range.lowerBound }
        return Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - Storage

/// Loads and saves `ReaderSettings` in user defaults.
public struct ReaderSettingsStore: Sendable {
    public static let key = "reader.settings.v1"
    private let defaultsSuite: String?

    /// - Parameter suiteName: A user defaults suite, for tests. Nil uses the standard defaults.
    public init(suiteName: String? = nil) {
        defaultsSuite = suiteName
    }

    private var defaults: UserDefaults {
        defaultsSuite.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    public func load() -> ReaderSettings {
        guard let data = defaults.data(forKey: Self.key),
              let settings = try? JSONDecoder().decode(ReaderSettings.self, from: data) else {
            return .default
        }
        return settings
    }

    public func save(_ settings: ReaderSettings) {
        guard let data = try? JSONEncoder().encode(settings.clamped()) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

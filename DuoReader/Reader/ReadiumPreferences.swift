import ReadiumNavigator
import UIKit

/// Translates `ReaderSettings` into Readium's preference types.
///
/// Kept separate from the views and the model so the mapping can be tested
/// without a navigator.
enum ReadiumPreferences {
    /// Preferences for the EPUB navigator.
    ///
    /// - Parameters:
    ///   - settings: The user's settings.
    ///   - systemIsDark: Whether the system is in Dark Mode.
    ///   - columns: How many pages to show side by side, decided by the layout.
    ///   - spread: Side-by-side pages for fixed-layout EPUBs, which ignore `columns`.
    ///   - extraMargin: Added to the margin factor, e.g. to keep text out of the fold.
    static func epub(
        _ settings: ReaderSettings,
        systemIsDark: Bool,
        columns: ColumnCount = .one,
        spread: Spread? = nil,
        extraMargin: Double = 0
    ) -> EPUBPreferences {
        let theme = settings.effectiveTheme(systemIsDark: systemIsDark)
        let palette = settings.colors(for: theme)
        let custom = !settings.usesPublisherStyles

        return EPUBPreferences(
            backgroundColor: ReadiumNavigator.Color(palette.background),
            columnCount: settings.flow == .scroll ? .one : columns,
            fontFamily: settings.font.cssFamily.map { FontFamily(rawValue: $0) },
            fontSize: settings.fontScale,
            fontWeight: settings.fontWeight == 1 ? nil : settings.fontWeight,
            hyphens: custom ? settings.hyphenation : nil,
            imageFilter: palette.isDark ? (settings.invertsImagesInDarkThemes ? .invert : .darken) : nil,
            letterSpacing: custom ? settings.letterSpacing : nil,
            lineHeight: custom ? settings.lineHeight : nil,
            pageMargins: settings.margins + extraMargin,
            paragraphIndent: custom ? settings.paragraphIndent : nil,
            paragraphSpacing: custom ? settings.paragraphSpacing : nil,
            publisherStyles: settings.usesPublisherStyles,
            scroll: settings.flow == .scroll,
            spread: spread,
            textAlign: custom ? settings.alignment.readium : nil,
            textColor: ReadiumNavigator.Color(palette.text),
            theme: readiumTheme(for: theme, palette: palette),
            wordSpacing: custom ? settings.wordSpacing : nil
        )
    }

    /// Preferences for the PDF navigator. PDFs keep their own typography, so
    /// only the page colour, flow and spread apply.
    static func pdf(
        _ settings: ReaderSettings,
        systemIsDark: Bool,
        spread: Spread = .never
    ) -> PDFPreferences {
        let palette = settings.colors(for: settings.effectiveTheme(systemIsDark: systemIsDark))
        return PDFPreferences(
            backgroundColor: ReadiumNavigator.Color(palette.background),
            fit: .auto,
            scroll: settings.flow == .scroll,
            spread: settings.flow == .scroll ? .never : spread
        )
    }

    /// Readium's column count for reflowable books, from the pages the
    /// layout shows side by side.
    static func columnCount(pages: Int) -> ColumnCount {
        pages == 2 ? .two : .one
    }

    /// Readium's spread for PDFs and fixed-layout books, from the pages the
    /// layout shows side by side.
    static func spread(pages: Int) -> Spread {
        pages == 2 ? .always : .never
    }

    /// Readium's own theme drives image filters and its fallback colours. The
    /// dark theme is the only one that applies image filters.
    private static func readiumTheme(for theme: ReaderTheme, palette: ReaderPalette) -> Theme {
        if palette.isDark { return .dark }
        return theme == .sepia ? .sepia : .light
    }
}

extension ReadiumNavigator.Color {
    init(_ color: ReaderColor) {
        // Readium packs colours as 0xRRGGBB, with no alpha.
        self.init(rawValue: Int(color.rgb))
    }
}

extension ReaderAlignment {
    var readium: TextAlignment? {
        switch self {
        case .publisher: nil
        case .start: .start
        case .justify: .justify
        }
    }
}

extension ReaderColor {
    var uiColor: UIColor {
        UIColor(red: red, green: green, blue: blue, alpha: 1)
    }
}

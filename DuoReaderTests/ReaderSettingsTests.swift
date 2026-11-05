import Foundation
import ReadiumNavigator
import Testing
@testable import DuoReader

struct ReaderSettingsTests {
    @Test func defaultsAreSensible() {
        let s = ReaderSettings.default
        #expect(s.theme == .light)
        #expect(s.fontScale == 1)
        #expect(s.usesPublisherStyles)
        #expect(s.flow == .paged)
        #expect(s.pageTurn == .slide)
    }

    @Test func roundTripsThroughJSON() throws {
        var s = ReaderSettings()
        s.theme = .sepia
        s.font = .openDyslexic
        s.fontScale = 1.4
        s.usesPublisherStyles = false
        s.alignment = .justify
        s.flow = .scroll
        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(ReaderSettings.self, from: data) == s)
    }

    @Test func missingKeysKeepTheirDefaults() throws {
        let json = #"{"theme":"green","fontScale":1.2}"#
        let s = try JSONDecoder().decode(ReaderSettings.self, from: Data(json.utf8))
        #expect(s.theme == .green)
        #expect(s.fontScale == 1.2)
        #expect(s.margins == ReaderSettings.default.margins)
        #expect(s.font == .publisher)
    }

    @Test func unknownValuesFromANewerVersionFallBack() throws {
        let json = #"{"theme":"neon","font":"comic","fontScale":"big","margins":2}"#
        let s = try JSONDecoder().decode(ReaderSettings.self, from: Data(json.utf8))
        #expect(s.theme == .light)
        #expect(s.font == .publisher)
        #expect(s.fontScale == 1)
        #expect(s.margins == 2)
    }

    @Test func clampsOutOfRangeNumbers() throws {
        let json = #"{"fontScale":40,"margins":-3,"lineHeight":0.1,"letterSpacing":9}"#
        let s = try JSONDecoder().decode(ReaderSettings.self, from: Data(json.utf8))
        #expect(s.fontScale == ReaderSettings.fontScaleRange.upperBound)
        #expect(s.margins == ReaderSettings.marginsRange.lowerBound)
        #expect(s.lineHeight == ReaderSettings.lineHeightRange.lowerBound)
        #expect(s.letterSpacing == ReaderSettings.letterSpacingRange.upperBound)
    }

    @Test func nonFiniteNumbersBecomeInRange() {
        var s = ReaderSettings()
        s.fontScale = .nan
        s.margins = .infinity
        let c = s.clamped()
        #expect(ReaderSettings.fontScaleRange.contains(c.fontScale))
        #expect(ReaderSettings.marginsRange.contains(c.margins))
    }

    @Test func invalidCustomColoursAreReplaced() {
        var s = ReaderSettings()
        s.customBackgroundHex = "zzz"
        s.customTextHex = "12345"
        let c = s.clamped()
        #expect(c.customBackgroundHex == ReaderSettings.default.customBackgroundHex)
        #expect(c.customTextHex == ReaderSettings.default.customTextHex)
    }

    @Test func followsDarkModeWhenAsked() {
        var s = ReaderSettings()
        s.theme = .sepia
        s.darkTheme = .gray
        #expect(s.effectiveTheme(systemIsDark: false) == .sepia)
        #expect(s.effectiveTheme(systemIsDark: true) == .gray)
        s.followsSystemAppearance = false
        #expect(s.effectiveTheme(systemIsDark: true) == .sepia)
    }

    @Test func customThemeUsesCustomColours() {
        var s = ReaderSettings()
        s.customBackgroundHex = "#102030"
        s.customTextHex = "F0E0D0"
        let palette = s.colors(for: .custom)
        #expect(palette.background == ReaderColor(0x102030))
        #expect(palette.text == ReaderColor(0xF0E0D0))
        #expect(palette.isDark)
    }

    @Test(arguments: ReaderTheme.allCases.filter { $0 != .custom })
    func builtInThemesAreReadable(theme: ReaderTheme) {
        let palette = theme.palette
        // WCAG AA for body text.
        #expect(palette.text.contrastRatio(with: palette.background) >= 4.5)
        #expect(palette.isDark == theme.isDark)
    }

    @Test func parsesAndFormatsHex() {
        #expect(ReaderColor(hex: "#FFAA00")?.rgb == 0xFFAA00)
        #expect(ReaderColor(hex: "ffaa00")?.hex == "FFAA00")
        #expect(ReaderColor(hex: "#FFF") == nil)
        #expect(ReaderColor(hex: "GGGGGG") == nil)
    }

    @Test func contrastRatioMatchesWCAG() {
        let black = ReaderColor(0x000000), white = ReaderColor(0xFFFFFF)
        #expect(abs(black.contrastRatio(with: white) - 21) < 0.01)
        #expect(black.contrastRatio(with: black) == 1)
    }

    @Test func storeSavesAndLoads() {
        let suite = "ReaderSettingsTests-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let store = ReaderSettingsStore(suiteName: suite)
        #expect(store.load() == .default)
        var s = ReaderSettings()
        s.theme = .dark
        s.margins = 2.5
        store.save(s)
        #expect(store.load() == s)
    }

    @Test func storeIgnoresCorruptData() {
        let suite = "ReaderSettingsTests-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        UserDefaults(suiteName: suite)!.set(Data("garbage".utf8), forKey: ReaderSettingsStore.key)
        #expect(ReaderSettingsStore(suiteName: suite).load() == .default)
    }

    @Test func stepsDoNotDrift() {
        var value = 1.0
        for _ in 0 ..< 3 { value = (value + 0.1).roundedToStep(0.1) }
        #expect(value == 1.3)
    }
}

struct ReadiumPreferencesTests {
    @Test func publisherStylesLeaveSpacingToTheBook() {
        var s = ReaderSettings()
        s.lineHeight = 2
        s.alignment = .justify
        let p = ReadiumPreferences.epub(s, systemIsDark: false)
        #expect(p.publisherStyles == true)
        #expect(p.lineHeight == nil)
        #expect(p.textAlign == nil)
        #expect(p.hyphens == nil)
    }

    @Test func customLayoutAppliesSpacing() {
        var s = ReaderSettings()
        s.usesPublisherStyles = false
        s.lineHeight = 1.8
        s.paragraphSpacing = 1
        s.wordSpacing = 0.2
        s.alignment = .justify
        s.hyphenation = true
        let p = ReadiumPreferences.epub(s, systemIsDark: false)
        #expect(p.publisherStyles == false)
        #expect(p.lineHeight == 1.8)
        #expect(p.paragraphSpacing == 1)
        #expect(p.wordSpacing == 0.2)
        #expect(p.textAlign == .justify)
        #expect(p.hyphens == true)
    }

    @Test func darkThemesUseReadiumsDarkModeAndFilterImages() {
        var s = ReaderSettings()
        s.theme = .gray
        var p = ReadiumPreferences.epub(s, systemIsDark: false)
        #expect(p.theme == .dark)
        #expect(p.imageFilter == .darken)
        #expect(p.backgroundColor == ReadiumNavigator.Color(hex: "3A3A3C"))
        s.invertsImagesInDarkThemes = true
        p = ReadiumPreferences.epub(s, systemIsDark: false)
        #expect(p.imageFilter == .invert)
    }

    @Test func lightThemesDoNotFilterImages() {
        var s = ReaderSettings()
        s.theme = .sepia
        let p = ReadiumPreferences.epub(s, systemIsDark: false)
        #expect(p.theme == .sepia)
        #expect(p.imageFilter == nil)
    }

    @Test func fontsMapToCSSFamilies() {
        var s = ReaderSettings()
        #expect(ReadiumPreferences.epub(s, systemIsDark: false).fontFamily == nil)
        s.font = .openDyslexic
        #expect(ReadiumPreferences.epub(s, systemIsDark: false).fontFamily == FontFamily.openDyslexic)
        s.font = .georgia
        #expect(ReadiumPreferences.epub(s, systemIsDark: false).fontFamily == FontFamily.georgia)
    }

    @Test func scrollModeUsesOneColumn() {
        var s = ReaderSettings()
        s.flow = .scroll
        let p = ReadiumPreferences.epub(s, systemIsDark: false, columns: .two)
        #expect(p.scroll == true)
        #expect(p.columnCount == .one)
    }

    @Test func extraMarginAddsToTheUsersMargin() {
        var s = ReaderSettings()
        s.margins = 1.5
        #expect(ReadiumPreferences.epub(s, systemIsDark: false, extraMargin: 0.5).pageMargins == 2)
    }

    @Test func pdfsTakePageColourAndSpread() {
        var s = ReaderSettings()
        s.theme = .dark
        let p = ReadiumPreferences.pdf(s, systemIsDark: false, spread: .always)
        #expect(p.backgroundColor == ReadiumNavigator.Color(hex: "000000"))
        #expect(p.spread == .always)
        s.flow = .scroll
        #expect(ReadiumPreferences.pdf(s, systemIsDark: false, spread: .always).spread == .never)
    }
}

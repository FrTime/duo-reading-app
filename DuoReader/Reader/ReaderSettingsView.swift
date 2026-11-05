import SwiftUI
import UIKit

/// The "Aa" sheet: themes, fonts, spacing and layout.
///
/// Changes apply to the page live, so the sheet stops at a medium detent and
/// leaves the page interactive behind it.
struct ReaderSettingsView: View {
    @Binding var settings: ReaderSettings
    /// PDFs keep their own typography, so only colour and layout show for them.
    var isReflowable = true
    /// Whether to offer the outer-screen cover, and what to say about it.
    var outerCoverStatus: OuterCoverPolicy.Status = .unsupported
    /// Closes settings when they're docked in the reader rather than presented.
    var onDone: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ReaderPanelContainer(title: "Reading Settings", onDone: onDone) {
            form
        }
    }

    private var form: some View {
        Form {
            themeSection
            if isReflowable {
                textSection
            }
            layoutSection
            if isReflowable {
                spacingSection
            }
            pageTurningSection
            OuterCoverSettingsSection(status: outerCoverStatus, camera: .shared)
            Section {
                Button("Reset to Defaults", role: .destructive) {
                    settings = .default
                }
                .disabled(settings == .default)
            }
        }
    }

    // MARK: - Theme

    private var themeSection: some View {
        Section("Theme") {
            ThemePicker(selection: $settings.theme, settings: settings)
            if settings.theme == .custom {
                customColors
            }
            Toggle("Dark Theme in Dark Mode", isOn: $settings.followsSystemAppearance)
            if settings.followsSystemAppearance {
                Picker("Dark Mode Theme", selection: $settings.darkTheme) {
                    ForEach(ReaderTheme.allCases) { theme in
                        Text(theme.name).tag(theme)
                    }
                }
            }
            if isReflowable {
                Toggle("Invert Images on Dark Pages", isOn: $settings.invertsImagesInDarkThemes)
            }
        }
    }

    @ViewBuilder
    private var customColors: some View {
        ColorPicker("Page Colour", selection: hexBinding(\.customBackgroundHex), supportsOpacity: false)
        ColorPicker("Text Colour", selection: hexBinding(\.customTextHex), supportsOpacity: false)
        let palette = settings.colors(for: .custom)
        if palette.text.contrastRatio(with: palette.background) < 4.5 {
            Label("These colours may be hard to read. Try more contrast.", systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.multicolor)
        }
    }

    private func hexBinding(_ keyPath: WritableKeyPath<ReaderSettings, String>) -> Binding<Color> {
        Binding {
            Color(uiColor: (ReaderColor(hex: settings[keyPath: keyPath]) ?? ReaderColor(0)).uiColor)
        } set: { color in
            if let hex = ReaderColor(color)?.hex {
                settings[keyPath: keyPath] = hex
            }
        }
    }

    // MARK: - Text

    private var textSection: some View {
        Section("Text") {
            Picker("Font", selection: $settings.font) {
                ForEach(ReaderFont.allCases) { font in
                    Text(font.name)
                        .font(font.previewFont)
                        .tag(font)
                }
            }
            .pickerStyle(.navigationLink)

            LabeledStepper(
                title: "Text Size",
                value: $settings.fontScale,
                range: ReaderSettings.fontScaleRange,
                step: 0.1,
                format: .percent.precision(.fractionLength(0)),
                decreaseLabel: "Smaller Text",
                increaseLabel: "Larger Text"
            )

            LabeledSlider(
                title: "Boldness",
                value: $settings.fontWeight,
                range: ReaderSettings.fontWeightRange,
                step: 0.1,
                format: .percent.precision(.fractionLength(0))
            )
        }
    }

    // MARK: - Layout

    private var layoutSection: some View {
        Section("Layout") {
            Picker("Reading Mode", selection: $settings.flow) {
                Text("Pages").tag(ReaderFlow.paged)
                Text("Scroll").tag(ReaderFlow.scroll)
            }
            .pickerStyle(.segmented)

            Picker("Pages Side by Side", selection: $settings.spread) {
                Text("Automatic").tag(ReaderSpread.automatic)
                Text("One Page").tag(ReaderSpread.single)
                Text("Two Pages").tag(ReaderSpread.double)
            }
            .disabled(settings.flow == .scroll)

            if isReflowable {
                LabeledSlider(
                    title: "Margins",
                    value: $settings.margins,
                    range: ReaderSettings.marginsRange,
                    step: 0.25,
                    format: .number.precision(.fractionLength(2))
                )
            }
        }
    }

    // MARK: - Page turning

    private var pageTurningSection: some View {
        Section {
            Picker("Page Turn Animation", selection: $settings.pageTurn) {
                ForEach(PageTurnStyle.allCases) { style in
                    Label(style.name, systemImage: style.systemImage).tag(style)
                }
            }
            .disabled(settings.flow == .scroll)

            Picker("Tapping the Sides", selection: $settings.tapZones) {
                Text("Left Back, Right Forward").tag(TapZoneMode.backAndForward)
                Text("Both Go Forward").tag(TapZoneMode.forwardOnly)
                Text("Show Controls Only").tag(TapZoneMode.off)
            }
        } header: {
            Text("Page Turning")
        } footer: {
            if reduceMotion, settings.pageTurn == .slide || settings.pageTurn == .curl {
                Text("Reduce Motion is on, so pages fade instead.")
            } else if !isReflowable, settings.pageTurn == .curl || settings.pageTurn == .fade {
                Text("PDFs slide between pages.")
            }
        }
    }

    // MARK: - Spacing

    private var spacingSection: some View {
        Section {
            Toggle("Book's Original Layout", isOn: $settings.usesPublisherStyles)
            if !settings.usesPublisherStyles {
                Picker("Alignment", selection: $settings.alignment) {
                    Text("Original").tag(ReaderAlignment.publisher)
                    Text("Left").tag(ReaderAlignment.start)
                    Text("Justified").tag(ReaderAlignment.justify)
                }
                .pickerStyle(.segmented)
                Toggle("Hyphenation", isOn: $settings.hyphenation)
                LabeledSlider(title: "Line Spacing", value: $settings.lineHeight, range: ReaderSettings.lineHeightRange, step: 0.1, format: .number.precision(.fractionLength(1)))
                LabeledSlider(title: "Paragraph Spacing", value: $settings.paragraphSpacing, range: ReaderSettings.paragraphSpacingRange, step: 0.25, format: .number.precision(.fractionLength(2)))
                LabeledSlider(title: "First-Line Indent", value: $settings.paragraphIndent, range: ReaderSettings.paragraphIndentRange, step: 0.25, format: .number.precision(.fractionLength(2)))
                LabeledSlider(title: "Word Spacing", value: $settings.wordSpacing, range: ReaderSettings.wordSpacingRange, step: 0.05, format: .number.precision(.fractionLength(2)))
                LabeledSlider(title: "Letter Spacing", value: $settings.letterSpacing, range: ReaderSettings.letterSpacingRange, step: 0.025, format: .number.precision(.fractionLength(3)))
            }
        } header: {
            Text("Spacing")
        } footer: {
            Text(settings.usesPublisherStyles
                ? "Using the spacing, alignment and indents the book was designed with."
                : "Your spacing, alignment and indents replace the book's own.")
        }
    }
}

// MARK: - Controls

/// A row of theme swatches, each showing "Aa" in the theme's colours.
private struct ThemePicker: View {
    @Binding var selection: ReaderTheme
    let settings: ReaderSettings
    @ScaledMetric(relativeTo: .title3) private var swatchSize = 52.0

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(ReaderTheme.allCases) { theme in
                    let palette = settings.colors(for: theme)
                    Button {
                        selection = theme
                    } label: {
                        VStack(spacing: 6) {
                            Text("Aa")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(Color(uiColor: palette.text.uiColor))
                                .frame(width: swatchSize, height: swatchSize)
                                .background(Color(uiColor: palette.background.uiColor), in: .circle)
                                .overlay {
                                    Circle().strokeBorder(selection == theme ? Color.accentColor : Color.secondary.opacity(0.4),
                                                          lineWidth: selection == theme ? 3 : 1)
                                }
                            Text(theme.name)
                                .font(.caption)
                                .foregroundStyle(.primary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(theme.name)
                    .accessibilityAddTraits(selection == theme ? .isSelected : [])
                }
            }
            .padding(.vertical, 4)
        }
    }
}

/// A slider with its title and current value, adjustable with VoiceOver.
struct LabeledSlider<F: FormatStyle>: View where F.FormatInput == Double, F.FormatOutput == String {
    let title: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: F

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(value.formatted(format))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            // The slider below speaks the title and value itself.
            .accessibilityHidden(true)
            Slider(value: $value, in: range, step: step)
                .accessibilityLabel(Text(title))
                .accessibilityValue(Text(value.formatted(format)))
        }
        .accessibilityElement(children: .contain)
    }
}

/// "A  100%  A" with buttons that step the value, like Kindle's text size.
struct LabeledStepper<F: FormatStyle>: View where F.FormatInput == Double, F.FormatOutput == String {
    let title: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: F
    let decreaseLabel: LocalizedStringKey
    let increaseLabel: LocalizedStringKey

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Button {
                value = max(range.lowerBound, (value - step).roundedToStep(step))
            } label: {
                Image(systemName: "textformat.size.smaller")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel(Text(decreaseLabel))
            .disabled(value <= range.lowerBound)

            Text(value.formatted(format))
                .monospacedDigit()
                .frame(minWidth: 52)

            Button {
                value = min(range.upperBound, (value + step).roundedToStep(step))
            } label: {
                Image(systemName: "textformat.size.larger")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel(Text(increaseLabel))
            .disabled(value >= range.upperBound)
        }
        .buttonStyle(.borderless)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(value.formatted(format)))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(range.upperBound, (value + step).roundedToStep(step))
            case .decrement: value = max(range.lowerBound, (value - step).roundedToStep(step))
            @unknown default: break
            }
        }
    }
}

extension Double {
    /// Rounds to the nearest multiple of `step`, so repeated steps don't drift
    /// (0.1 + 0.1 + 0.1 ≠ 0.3 in floating point).
    func roundedToStep(_ step: Double) -> Double {
        guard step > 0 else { return self }
        // Dividing by a whole number of steps per unit keeps decimal steps
        // exact: 12 / 10 is 1.2, where 12 * 0.1 is 1.2000000000000002.
        let perUnit = (1 / step).rounded()
        if perUnit > 0, abs(perUnit * step - 1) < 1e-9 {
            return (self * perUnit).rounded() / perUnit
        }
        return (self / step).rounded() * step
    }
}

// MARK: - Names

extension ReaderTheme {
    var name: String {
        switch self {
        case .light: String(localized: "White")
        case .sepia: String(localized: "Sepia")
        case .green: String(localized: "Green")
        case .gray: String(localized: "Grey")
        case .dark: String(localized: "Black")
        case .custom: String(localized: "Custom")
        }
    }
}

extension PageTurnStyle {
    var name: String {
        switch self {
        case .slide: String(localized: "Slide")
        case .curl: String(localized: "Page Curl")
        case .fade: String(localized: "Fade")
        case .none: String(localized: "None")
        }
    }

    var systemImage: String {
        switch self {
        case .slide: "rectangle.portrait.and.arrow.right"
        case .curl: "book.pages"
        case .fade: "circle.lefthalf.filled"
        case .none: "rectangle.portrait"
        }
    }
}

extension ReaderFont {
    var name: String {
        switch self {
        case .publisher: String(localized: "Book's Font")
        case .system: String(localized: "San Francisco")
        case .newYork: String(localized: "New York")
        case .georgia: "Georgia"
        case .palatino: "Palatino"
        case .iowan: "Iowan Old Style"
        case .charter: "Charter"
        case .athelas: "Athelas"
        case .avenirNext: "Avenir Next"
        case .openDyslexic: "OpenDyslexic"
        }
    }

    /// A SwiftUI font to preview the face in the picker, where one is available.
    var previewFont: Font {
        switch self {
        case .publisher, .openDyslexic: .body
        case .system: .system(.body)
        case .newYork: .system(.body, design: .serif)
        default: .custom(cssFamily ?? "", size: 17, relativeTo: .body)
        }
    }
}

extension ReaderColor {
    /// Converts a SwiftUI colour, dropping alpha.
    init?(_ color: Color) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        func byte(_ c: CGFloat) -> UInt32 { UInt32((min(max(c, 0), 1) * 255).rounded()) }
        self.init(byte(red) << 16 | byte(green) << 8 | byte(blue))
    }
}

#Preview {
    @Previewable @State var settings = ReaderSettings()
    Color.clear.sheet(isPresented: .constant(true)) {
        ReaderSettingsView(settings: $settings)
    }
}

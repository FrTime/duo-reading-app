import Foundation
import Observation
@preconcurrency import ReadiumNavigator
@preconcurrency import ReadiumShared
import SwiftData
import UIKit
import WebKit

/// State for one open book: the publication, its navigator, and where the
/// reader is.
///
/// The model is the navigator's delegate. Every position change is recorded
/// on the `Book` straight away and saved to the store through a throttle, so
/// a crash or a force quit loses at most a couple of seconds of reading.
@Observable
@MainActor
final class ReaderModel {
    enum State: Equatable {
        case loading
        case ready
        case failed(ReaderOpenError)
    }

    let book: Book
    private(set) var state: State = .loading
    private(set) var publication: Publication?
    private(set) var navigator: (any VisualNavigator & UIViewController)?

    /// Whether the top and bottom bars are showing.
    var isChromeVisible = true

    /// A web or mail link the reader tapped, waiting for confirmation.
    var pendingExternalURL: URL?

    /// The reading settings. Changing them saves them and restyles the page.
    var settings: ReaderSettings {
        didSet {
            guard settings != oldValue else { return }
            scheduleSettingsUpdate()
        }
    }

    /// Whether the system is in Dark Mode, which picks the dark theme when the
    /// settings follow the system.
    var systemIsDark = false {
        didSet {
            if systemIsDark != oldValue { applySettings() }
        }
    }

    /// The page and text colours in effect.
    var palette: ReaderPalette {
        settings.colors(for: settings.effectiveTheme(systemIsDark: systemIsDark))
    }

    /// Whether the book reflows (EPUB). PDFs have fixed pages.
    var isReflowable: Bool {
        guard let publication else { return true }
        return publication.metadata.layout != .fixed && !publication.conforms(to: .pdf)
    }

    /// How far through the book the current page is, from 0 to 1.
    private(set) var progression: Double?
    /// The chapter title at the current position, when the book has one.
    private(set) var chapterTitle: String?
    /// "Page 12 of 300" style position, when positions are known.
    private(set) var position: Int?
    private(set) var positionCount: Int?

    @ObservationIgnored private let booksFolder: URL
    @ObservationIgnored private let loader: PublicationLoader
    @ObservationIgnored private let settingsStore: ReaderSettingsStore
    @ObservationIgnored private var modelContext: ModelContext?
    @ObservationIgnored private lazy var saveThrottle = SaveThrottle { [weak self] in self?.save() }
    @ObservationIgnored private var delegateBridge: NavigatorDelegateBridge?
    @ObservationIgnored private var isClosed = false
    @ObservationIgnored private var settingsUpdate: Task<Void, Never>?

    init(
        book: Book,
        booksFolder: URL,
        loader: PublicationLoader = .shared,
        settingsStore: ReaderSettingsStore = ReaderSettingsStore()
    ) {
        self.book = book
        self.booksFolder = booksFolder
        self.loader = loader
        self.settingsStore = settingsStore
        // Start new readers at their Dynamic Type size.
        settings = settingsStore.load(firstRunFontScale: UIFontMetrics.default.scaledValue(for: 1))
        progression = book.progress
    }

    // MARK: - Opening and closing

    /// Opens the book's file and builds a navigator at the saved position.
    func load(in context: ModelContext) async {
        modelContext = context
        guard state != .ready else { return }
        state = .loading

        guard book.format == .epub || book.format == .pdf else {
            state = .failed(.unsupportedFormat)
            return
        }

        let publication: Publication
        do {
            publication = try await loader.open(book.fileURL(in: booksFolder))
        } catch {
            state = .failed(error)
            return
        }
        await RemoteContentBlocker.prepare()
        // The reader may have closed while the file was opening.
        guard !isClosed, !Task.isCancelled else { return }

        let bridge = NavigatorDelegateBridge(model: self)
        let initialLocation = Self.savedLocator(book.readingLocator)
        do {
            if publication.conforms(to: .pdf) {
                navigator = try PDFNavigatorViewController(
                    publication: publication,
                    initialLocation: initialLocation,
                    config: PDFNavigatorViewController.Configuration(preferences: pdfPreferences),
                    delegate: bridge
                )
            } else {
                let epub = try EPUBNavigatorViewController(
                    publication: publication,
                    initialLocation: initialLocation,
                    config: EPUBNavigatorViewController.Configuration(preferences: epubPreferences)
                )
                epub.delegate = bridge
                navigator = epub
            }
        } catch {
            state = .failed(.unreadable)
            return
        }

        self.publication = publication
        delegateBridge = bridge
        book.lastOpened = .now
        state = .ready

        // Publication isn't Sendable; Readium computes positions off the main
        // actor and the navigator only reads the publication meanwhile.
        nonisolated(unsafe) let positionsSource = publication
        positionCount = try? await positionsSource.positions().get().count
    }

    /// Saves the current position and releases the navigator and publication.
    /// Readium frees a publication's resources when it's deallocated.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        if settingsUpdate != nil { commitSettings() }
        saveThrottle.flush()
        navigator = nil
        publication = nil
        delegateBridge = nil
    }

    /// Saves now, e.g. when the app moves to the background.
    func flush() {
        if settingsUpdate != nil { commitSettings() }
        saveThrottle.flush()
    }

    // MARK: - Settings

    private var epubPreferences: EPUBPreferences {
        ReadiumPreferences.epub(
            settings,
            systemIsDark: systemIsDark,
            columns: settings.spread.columnCount,
            spread: settings.spread.pdfSpread
        )
    }

    private var pdfPreferences: PDFPreferences {
        ReadiumPreferences.pdf(settings, systemIsDark: systemIsDark, spread: settings.spread.pdfSpread)
    }

    /// Saves and applies settings shortly after the last change, so dragging
    /// a slider doesn't re-paginate the book on every tick.
    private func scheduleSettingsUpdate() {
        settingsUpdate?.cancel()
        settingsUpdate = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            self.commitSettings()
        }
    }

    /// Saves and applies any settings change still waiting.
    func commitSettings() {
        settingsUpdate?.cancel()
        settingsUpdate = nil
        settingsStore.save(settings)
        applySettings()
    }

    /// Pushes the current settings to the navigator.
    private func applySettings() {
        switch navigator {
        case let epub as EPUBNavigatorViewController:
            epub.submitPreferences(epubPreferences)
        case let pdf as PDFNavigatorViewController:
            pdf.submitPreferences(pdfPreferences)
        default:
            return
        }
        onSettingsApplied?()
    }

    // MARK: - Turning pages

    /// Called after every position change, e.g. so the page host can re-apply
    /// settings to web views Readium created for the new page.
    @ObservationIgnored var onLocationChange: (@MainActor () -> Void)?
    /// Called after settings reach the navigator, which may rebuild its pages.
    @ObservationIgnored var onSettingsApplied: (@MainActor () -> Void)?

    /// Whether the book reads right to left, which flips which side is "next".
    var isRightToLeft: Bool {
        navigator?.presentation.readingProgression == .rtl
    }

    /// Turns one page. Returns false at the start or end of the book.
    @discardableResult
    func turn(_ turn: PageTurn, animated: Bool) async -> Bool {
        guard let navigator else { return false }
        let options = NavigatorGoOptions(animated: animated && !UIAccessibility.isReduceMotionEnabled)
        switch turn {
        case .left: return await navigator.goLeft(options: options)
        case .right: return await navigator.goRight(options: options)
        case .forward: return await navigator.goForward(options: options)
        case .backward: return await navigator.goBackward(options: options)
        }
    }

    func goForward() async {
        await turn(.forward, animated: settings.pageTurn == .slide)
    }

    func goBackward() async {
        await turn(.backward, animated: settings.pageTurn == .slide)
    }

    // MARK: - Position

    func locationDidChange(_ locator: Locator) {
        progression = locator.locations.totalProgression ?? progression
        chapterTitle = locator.title
        position = locator.locations.position

        onLocationChange?()

        guard let json = try? locator.jsonString() else { return }
        book.recordReadingPosition(locatorJSON: json, progression: locator.locations.totalProgression)
        saveThrottle.request()
    }

    private func save() {
        guard let modelContext, modelContext.hasChanges else { return }
        try? modelContext.save()
    }

    /// Decodes a saved position, ignoring anything unreadable so a bad value
    /// opens the book at the start instead of failing.
    static func savedLocator(_ json: String?) -> Locator? {
        guard let json else { return nil }
        return try? Locator(jsonString: json)
    }
}

/// Receives navigator callbacks and forwards them to the model.
///
/// Navigators hold their delegate weakly, so the model keeps this alive.
@MainActor
private final class NavigatorDelegateBridge: EPUBNavigatorDelegate, PDFNavigatorDelegate {
    weak var model: ReaderModel?

    init(model: ReaderModel) {
        self.model = model
    }

    func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
        model?.locationDidChange(locator)
    }

    func navigator(_ navigator: Navigator, presentError error: NavigatorError) {
        // The only error navigators report is a copy limit set by DRM, which
        // can't happen for the DRM-free books we open.
    }

    func navigator(_ navigator: Navigator, presentExternalURL url: URL) {
        // Readium's default opens any scheme straight away. Only web and mail
        // links leave the app, and only after the reader confirms.
        guard ExternalLinkPolicy.allows(url) else { return }
        model?.pendingExternalURL = url
    }

    func navigator(_ navigator: EPUBNavigatorViewController, setupUserScripts userContentController: WKUserContentController) {
        RemoteContentBlocker.install(in: userContentController)
    }
}

extension ReaderSpread {
    var columnCount: ColumnCount {
        switch self {
        case .automatic: .auto
        case .single: .one
        case .double: .two
        }
    }

    var pdfSpread: Spread {
        switch self {
        case .automatic: .auto
        case .single: .never
        case .double: .always
        }
    }
}

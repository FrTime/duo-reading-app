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

    /// Where docked panels (settings, contents, search) start: the spine
    /// (the fold, or the middle of a flat screen), in window coordinates.
    /// Nil when the screen is too narrow to dock them, so they show as
    /// sheets. Set by the view.
    var settingsSpineX: CGFloat?

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

    /// Where the page goes for the current size and Duo pose. Set by the view.
    var layout: ReaderLayout? {
        didSet {
            if layout != oldValue { applySettings() }
        }
    }

    /// Where the reader's title bar ends, from the top of the window, last
    /// measured while it showed. Reflowable pages start below it. Set by the
    /// view; Readium reads it whenever it lays out a page.
    @ObservationIgnored var titleBarBottom: CGFloat = 0

    /// Top and bottom insets for reflowable pages, or nil for Readium's own
    /// (PDFs and fixed layouts, which fill the screen).
    func pageInsets(for navigator: VisualNavigator) -> UIEdgeInsets? {
        guard isReflowable, let view = (navigator as? UIViewController)?.view,
              let window = view.window else { return nil }
        let safe = window.safeAreaInsets
        let insets = PageInsets.resolve(
            windowTop: safe.top,
            windowBottom: safe.bottom,
            barBottom: titleBarBottom,
            compactHeight: view.traitCollection.verticalSizeClass == .compact
        )
        return UIEdgeInsets(top: insets.top, left: safe.left, bottom: insets.bottom, right: safe.right)
    }

    /// Readium's page gutter, fixed so the fold gap can be worked out from it.
    static let pageGutter: CGFloat = 20

    /// Whether the book reflows (EPUB). PDFs have fixed pages.
    var isReflowable: Bool {
        guard let publication else { return true }
        return publication.metadata.layout != .fixed && !publication.conforms(to: .pdf)
    }

    /// How far through the book the current page is, from 0 to 1.
    private(set) var progression: Double?
    /// The chapter title at the current position, when the book has one.
    private(set) var chapterTitle: String?
    /// The book's contents, flattened with nesting depth.
    private(set) var tableOfContents: [TOCEntry] = []
    /// Where the reader was before the last jump (contents, search, scrubber),
    /// so they can go back to it.
    private(set) var returnLocator: Locator?
    /// The current position.
    private(set) var currentLocator: Locator?
    /// The contents entry the reader is in.
    private(set) var currentTOCEntryID: TOCEntry.ID?
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
                    config: EPUBNavigatorViewController.Configuration(
                        preferences: epubPreferences,
                        readiumCSSRSProperties: CSSRSProperties(pageGutter: CSSPxLength(Double(Self.pageGutter)))
                    )
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
        #if DEBUG
        // `-DuoReaderHideChrome` hides the bars soon after opening, for
        // screenshots on simulators where taps don't get through.
        if ProcessInfo.processInfo.arguments.contains("-DuoReaderHideChrome") {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(3))
                self?.isChromeVisible = false
            }
        }
        #endif

        // Publication isn't Sendable; Readium computes positions off the main
        // actor and the navigator only reads the publication meanwhile.
        nonisolated(unsafe) let positionsSource = publication
        // Contents first: positions can take seconds in a long book.
        if let toc = try? await positionsSource.tableOfContents().get() {
            tableOfContents = TOCEntry.flatten(toc)
            updateCurrentTOCEntry()
        }
        positionCount = try? await positionsSource.positions().get().count
    }

    /// Saves the current position and releases the navigator and publication.
    /// Readium frees a publication's resources when it's deallocated.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        if settingsUpdate != nil { commitSettings() }
        saveThrottle.flush()
        highlightSearchResult(nil)
        returnLocator = nil
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
            columns: ReadiumPreferences.columnCount(pages: layout?.columns ?? 1),
            spread: ReadiumPreferences.spread(pages: layout?.columns ?? 1),
            extraMargin: layout?.extraMarginFactor(gutter: Self.pageGutter) ?? 0
        )
    }

    private var pdfPreferences: PDFPreferences {
        ReadiumPreferences.pdf(settings, systemIsDark: systemIsDark, spread: ReadiumPreferences.spread(pages: layout?.columns ?? 1))
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
    /// Turns a page through the page host, with its animation and feedback.
    /// Set by the host; controls outside the page use it.
    @ObservationIgnored var requestTurn: (@MainActor (PageTurn) async -> Void)?

    /// Whether the book reads right to left, which flips which side is "next".
    var isRightToLeft: Bool {
        navigator?.presentation.readingProgression == .rtl
    }

    /// Turns one page. Returns false at the start or end of the book.
    @discardableResult
    func turn(_ turn: PageTurn, animated: Bool) async -> Bool {
        guard let navigator else { return false }
        highlightSearchResult(nil)
        // Reading on for a few pages after a jump settles the reader there.
        if returnLocator != nil {
            turnsSinceJump += 1
            if turnsSinceJump >= Self.turnsToSettle { returnLocator = nil }
        }
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

    // MARK: - Jumping

    /// Whether the book can be searched (EPUBs can; most PDFs can't).
    var isSearchable: Bool {
        publication?.isSearchable ?? false
    }

    /// Goes to a contents entry, remembering where the reader was.
    func go(to link: Link) async {
        guard let navigator else { return }
        rememberReturnPoint(currentLocator)
        highlightSearchResult(nil)
        _ = await navigator.go(to: link, options: NavigatorGoOptions(animated: false))
    }

    /// Goes to a position, e.g. a search result, remembering where the reader
    /// was. Returns false if the navigator couldn't go there.
    @discardableResult
    func go(to locator: Locator) async -> Bool {
        guard let navigator else { return false }
        rememberReturnPoint(currentLocator)
        highlightSearchResult(nil)
        if await navigator.go(to: locator, options: NavigatorGoOptions(animated: false)) { return true }
        // If the exact spot won't resolve, at least open its chapter.
        guard let link = publication?.linkWithHREF(locator.href) else { return false }
        return await navigator.go(to: link, options: NavigatorGoOptions(animated: false))
    }

    /// Goes to a point through the whole book, from 0 to 1 (the scrubber).
    /// Returns false if there's nothing there to go to.
    @discardableResult
    func go(toProgression progression: Double) async -> Bool {
        guard let publication, progression.isFinite else { return false }
        nonisolated(unsafe) let source = publication
        guard let locator = await source.locate(progression: min(max(progression, 0), 1)) else { return false }
        return await go(to: locator)
    }

    /// Returns to where the reader was before the first of their recent jumps.
    func goBackToReturnPoint() async {
        guard let navigator, let target = returnLocator else { return }
        returnLocator = nil
        highlightSearchResult(nil)
        _ = await navigator.go(to: target, options: NavigatorGoOptions(animated: false))
    }

    func clearReturnPoint() {
        returnLocator = nil
    }

    /// Keeps the place before the first jump, so several jumps in a row
    /// (scrubbing, trying search results) still lead back to where reading
    /// was. Turning a page by hand settles the reader and clears it.
    private func rememberReturnPoint(_ from: Locator?) {
        turnsSinceJump = 0
        if returnLocator == nil, let from { returnLocator = from }
    }

    /// Page turns after a jump before "Back to…" goes away.
    static let turnsToSettle = 5
    @ObservationIgnored private var turnsSinceJump = 0

    private func updateCurrentTOCEntry() {
        guard let publication, let href = currentLocator?.href.string else {
            currentTOCEntryID = nil
            return
        }
        currentTOCEntryID = TOCEntry.currentID(
            in: tableOfContents,
            readingOrder: publication.readingOrder.map { $0.url().string },
            current: href
        )
    }

    // MARK: - Search

    /// Runs a full-text search, returning up to `limit` matches.
    func search(_ query: String, limit: Int = 500) async -> [Locator] {
        guard let publication, !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        nonisolated(unsafe) let source = publication
        guard case let .success(iterator) = await source.search(query: query) else { return [] }
        // The iterator frees its resources when it's released.
        nonisolated(unsafe) let pages = iterator
        var results: [Locator] = []
        while results.count < limit, !Task.isCancelled {
            guard case let .success(page?) = await pages.next() else { break }
            results += page.locators
        }
        return Task.isCancelled ? [] : Array(results.prefix(limit))
    }

    /// Underlines a search match on the page, or clears it with nil.
    func highlightSearchResult(_ locator: Locator?) {
        guard let decorator = navigator as? DecorableNavigator else { return }
        let decorations = locator.map {
            [Decoration(id: "search-result", locator: $0, style: .underline(tint: .systemOrange, isActive: true))]
        } ?? []
        decorator.apply(decorations: decorations, in: "search")
    }

    // MARK: - Position

    func locationDidChange(_ locator: Locator) {
        currentLocator = locator
        updateCurrentTOCEntry()
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

    func navigatorContentInset(_ navigator: VisualNavigator) -> UIEdgeInsets? {
        model?.pageInsets(for: navigator)
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

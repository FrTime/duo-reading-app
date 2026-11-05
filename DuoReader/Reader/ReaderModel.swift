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

    /// How far through the book the current page is, from 0 to 1.
    private(set) var progression: Double?
    /// The chapter title at the current position, when the book has one.
    private(set) var chapterTitle: String?
    /// "Page 12 of 300" style position, when positions are known.
    private(set) var position: Int?
    private(set) var positionCount: Int?

    @ObservationIgnored private let booksFolder: URL
    @ObservationIgnored private let loader: PublicationLoader
    @ObservationIgnored private var modelContext: ModelContext?
    @ObservationIgnored private lazy var saveThrottle = SaveThrottle { [weak self] in self?.save() }
    @ObservationIgnored private var delegateBridge: NavigatorDelegateBridge?
    @ObservationIgnored private var isClosed = false

    init(book: Book, booksFolder: URL, loader: PublicationLoader = .shared) {
        self.book = book
        self.booksFolder = booksFolder
        self.loader = loader
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
                    delegate: bridge
                )
            } else {
                let epub = try EPUBNavigatorViewController(
                    publication: publication,
                    initialLocation: initialLocation
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
        saveThrottle.flush()
        navigator = nil
        publication = nil
        delegateBridge = nil
    }

    /// Saves now, e.g. when the app moves to the background.
    func flush() {
        saveThrottle.flush()
    }

    // MARK: - Turning pages

    /// Page turns animate unless Reduce Motion is on.
    private var goOptions: NavigatorGoOptions {
        NavigatorGoOptions(animated: !UIAccessibility.isReduceMotionEnabled)
    }

    func goForward() async {
        _ = await navigator?.goForward(options: goOptions)
    }

    func goBackward() async {
        _ = await navigator?.goBackward(options: goOptions)
    }

    func goLeft() async {
        _ = await navigator?.goLeft(options: goOptions)
    }

    func goRight() async {
        _ = await navigator?.goRight(options: goOptions)
    }

    // MARK: - Position

    func locationDidChange(_ locator: Locator) {
        progression = locator.locations.totalProgression ?? progression
        chapterTitle = locator.title
        position = locator.locations.position

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

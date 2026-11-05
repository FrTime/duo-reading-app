import SwiftData
import SwiftUI

@main
struct DuoReaderApp: App {
    private let container: ModelContainer
    @State private var importController: ImportController
    @State private var recoveredLibrary: Bool
    private let widgetWriter: WidgetSnapshotWriter
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let opened: LibraryStore.OpenResult
        do {
            opened = try LibraryStore.openOrRecover()
        } catch {
            // Only reached if even a brand-new store can't be created (disk
            // full, container unwritable). Nothing useful can run without one.
            fatalError("Could not create the library: \(error)")
        }
        container = opened.container
        _recoveredLibrary = State(initialValue: opened.recoveredFrom != nil)
        _importController = State(initialValue: ImportController(container: opened.container))
        widgetWriter = WidgetSnapshotWriter(container: opened.container)
        if opened.recoveredFrom != nil {
            // Rebuild the shelf after launch, off the main thread.
            let container = opened.container
            Task.detached(priority: .userInitiated) {
                try? await LibraryStore.readopt(into: container)
            }
        }
        // Cover designs live outside the store, so remove them with the book.
        LibraryActions.onDelete.append { id in
            Task { await CoverLibrary.shared.deleteCovers(for: id) }
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(importController)
                // "Open in Duo Reader" from Files, Mail, Safari and the share
                // sheet. Widget links are handled by `RootView`.
                .onOpenURL { url in
                    guard !WidgetLink.isWidgetLink(url) else { return }
                    importController.importFiles([url])
                }
                // Keep the home screen widgets in step with the library.
                .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { _ in
                    widgetWriter.refreshSoon()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { refreshWidgetsInBackground() }
                }
                .task { await widgetWriter.refresh() }
                .alert("Your library was rebuilt", isPresented: $recoveredLibrary) {
                    Button("OK") {}
                } message: {
                    Text("Your library couldn't be opened, so it was rebuilt from your book files. Your books are all here, but reading positions and highlights from before couldn't be recovered.")
                }
        }
        .modelContainer(container)
    }

    /// Writes the widget snapshot as the app leaves the screen, which is when
    /// the home screen (and its widgets) come back into view.
    private func refreshWidgetsInBackground() {
        let writer = widgetWriter
        let assertion = BackgroundAssertion()
        assertion.begin(named: "Update widgets")
        Task {
            await writer.refresh()
            assertion.end()
        }
    }
}

/// The library, with the reader presented over it.
private struct RootView: View {
    @State private var openBook: Book?
    @Environment(\.modelContext) private var modelContext
    #if DEBUG
    @Query(sort: \Book.shelfOrder) private var books: [Book]
    #endif

    var body: some View {
        LibraryView(onOpen: { openBook = $0 })
            .fullScreenCover(item: $openBook) { book in
                ReaderView(book: book)
            }
            // Taps on a widget open that book where it was left.
            .onOpenURL { url in
                guard WidgetLink.isWidgetLink(url) else { return }
                guard let id = WidgetLink.bookID(from: url) else {
                    openBook = nil
                    return
                }
                var descriptor = FetchDescriptor<Book>(predicate: #Predicate { $0.id == id })
                descriptor.fetchLimit = 1
                if let book = try? modelContext.fetch(descriptor).first, book.id != openBook?.id {
                    openBook = book
                }
            }
            #if DEBUG
            // `-DuoReaderOpenFirstBook` opens the first book at launch, so the
            // reader can be screenshotted on a simulator without tapping.
            .task {
                if ProcessInfo.processInfo.arguments.contains("-DuoReaderOpenFirstBook") {
                    openBook = books.first
                }
            }
            #endif
    }
}

/// Asks for a little background time, and gives it back exactly once.
@MainActor
private final class BackgroundAssertion {
    private var identifier = UIBackgroundTaskIdentifier.invalid

    func begin(named name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            self?.end()
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

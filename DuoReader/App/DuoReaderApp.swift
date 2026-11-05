import SwiftData
import SwiftUI

@main
struct DuoReaderApp: App {
    private let container: ModelContainer
    @State private var importController: ImportController
    @State private var recoveredLibrary: Bool

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
            #if DEBUG
            if CoverSpike.isRequested {
                OuterScreenCoverSpikeView()
            } else {
                mainContent
            }
            #else
            mainContent
            #endif
        }
        .modelContainer(container)
    }

    private var mainContent: some View {
        RootView()
            .environment(importController)
            // "Open in Duo Reader" from Files, Mail, Safari and the share sheet.
            .onOpenURL { url in
                importController.importFiles([url])
            }
            .alert("Your library was rebuilt", isPresented: $recoveredLibrary) {
                Button("OK") {}
            } message: {
                Text("Your library couldn't be opened, so it was rebuilt from your book files. Your books are all here, but reading positions and highlights from before couldn't be recovered.")
            }
    }
}

/// The library, with the reader presented over it.
private struct RootView: View {
    @State private var openBook: Book?
    #if DEBUG
    @Query(sort: \Book.shelfOrder) private var books: [Book]
    #endif

    var body: some View {
        LibraryView(onOpen: { openBook = $0 })
            .fullScreenCover(item: $openBook) { book in
                ReaderView(book: book)
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

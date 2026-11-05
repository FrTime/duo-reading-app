import SwiftData
import SwiftUI

@main
struct DuoReaderApp: App {
    private let container: ModelContainer
    @State private var importController: ImportController

    init() {
        let container: ModelContainer
        do {
            container = try LibraryStore.makeContainer()
        } catch {
            // Recovery (move the broken store aside and start fresh) is #73.
            fatalError("Could not open the library: \(error)")
        }
        self.container = container
        _importController = State(initialValue: ImportController(container: container))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(importController)
                // "Open in Duo Reader" from Files, Mail, Safari and the share sheet.
                .onOpenURL { url in
                    importController.importFiles([url])
                }
        }
        .modelContainer(container)
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

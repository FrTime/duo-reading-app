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
        // Cover designs live outside the store, so remove them with the book.
        LibraryActions.onDelete.append { id in
            Task { await CoverLibrary.shared.deleteCovers(for: id) }
        }
        _importController = State(initialValue: ImportController(container: container))
    }

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environment(importController)
                // "Open in Duo Reader" from Files, Mail, Safari and the share sheet.
                .onOpenURL { url in
                    importController.importFiles([url])
                }
        }
        .modelContainer(container)
    }
}

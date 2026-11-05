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
    }

    var body: some Scene {
        WindowGroup {
            LibraryView()
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
        .modelContainer(container)
    }
}

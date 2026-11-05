import SwiftData
import SwiftUI

@main
struct DuoReaderApp: App {
    private let container: ModelContainer

    init() {
        do {
            container = try LibraryStore.makeContainer()
        } catch {
            // A store that can't open is unrecoverable at this stage. Recovery
            // (move the broken store aside and start fresh) is tracked under
            // the privacy and data epic.
            fatalError("Could not open the library: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            LibraryView()
        }
        .modelContainer(container)
    }
}

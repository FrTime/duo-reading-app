import SwiftData
import SwiftUI

/// Placeholder library until the import flow (#8) and grid (#15) land.
struct LibraryView: View {
    @Query(sort: \Book.shelfOrder) private var books: [Book]

    var body: some View {
        NavigationStack {
            Group {
                if books.isEmpty {
                    ContentUnavailableView {
                        Label("Your shelf is empty", systemImage: "books.vertical")
                    } description: {
                        Text("Books you import will appear here.")
                    }
                } else {
                    List(books) { book in
                        VStack(alignment: .leading) {
                            Text(book.title)
                                .font(.headline)
                            Text(book.displayAuthors)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .navigationTitle("Library")
        }
    }
}

#Preview("Empty") {
    LibraryView()
        .modelContainer(try! LibraryStore.makeContainer(inMemory: true))
}

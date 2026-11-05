import SwiftData
import SwiftUI

/// Placeholder library until the grid (#15) lands. Imports from the picker,
/// drag and drop, and "Open in".
struct LibraryView: View {
    @Query(sort: \Book.shelfOrder) private var books: [Book]
    @Environment(ImportController.self) private var importController
    @State private var showingPicker = false
    @State private var isDropTargeted = false

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("Library")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showingPicker = true
                        } label: {
                            Label("Import Books", systemImage: "plus")
                        }
                        .disabled(importController.isImporting)
                    }
                }
                .overlay {
                    if importController.isImporting {
                        ProgressView("Importing…")
                            .padding()
                            .background(.regularMaterial, in: .rect(cornerRadius: 12))
                    }
                }
                .overlay {
                    if isDropTargeted {
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(.tint, style: StrokeStyle(lineWidth: 3, dash: [8]))
                            .padding(8)
                            .accessibilityHidden(true)
                    }
                }
        }
        .fileImporter(
            isPresented: $showingPicker,
            allowedContentTypes: ImportController.allowedContentTypes,
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                importController.importFiles(urls)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            importController.importFiles(files)
            return !files.isEmpty
        } isTargeted: { isDropTargeted = $0 }
        .alert(
            importController.summary?.title ?? "",
            isPresented: Binding(
                get: { importController.summary.map { !$0.isQuietSuccess } ?? false },
                set: { if !$0 { importController.summary = nil } }
            ),
            presenting: importController.summary
        ) { _ in
            Button("OK") { importController.summary = nil }
        } message: { summary in
            Text(summary.message)
        }
        .sensoryFeedback(.success, trigger: importController.summary) { _, new in
            new?.isQuietSuccess == true
        }
    }

    @ViewBuilder
    private var content: some View {
        if books.isEmpty {
            ContentUnavailableView {
                Label("Your shelf is empty", systemImage: "books.vertical")
            } description: {
                Text("Import EPUB or PDF files from Files, or drag them here.")
            } actions: {
                Button("Import Books") { showingPicker = true }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            List(books) { book in
                VStack(alignment: .leading) {
                    Text(book.title)
                        .font(.headline)
                    Text(book.displayAuthors)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let fandoms = book.ao3?.fandoms, !fandoms.isEmpty {
                        Text(fandoms.formatted(.list(type: .and)))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

#Preview("Empty") {
    let container = try! LibraryStore.makeContainer(inMemory: true)
    LibraryView()
        .environment(ImportController(container: container))
        .modelContainer(container)
}

import SwiftData
import SwiftUI

enum LibraryLayout: String, CaseIterable, Identifiable {
    case shelf, grid, list
    var id: String { rawValue }
}

/// The library as a 3D shelf (the default), a grid or a list, with search,
/// sorting, delete and import. The shelf always shows the user's own
/// arrangement; while searching, results show in the grid.
struct LibraryView: View {
    @Query private var allBooks: [Book]
    @Environment(\.modelContext) private var modelContext
    @Environment(ImportController.self) private var importController

    @AppStorage("library.sort") private var sort: LibrarySort = .shelf
    @AppStorage("library.layout") private var layout: LibraryLayout = .shelf
    @State private var searchText = ""
    @State private var showingPicker = false
    @State private var isDropTargeted = false
    @State private var bookPendingDelete: Book?
    @State private var deleteError: String?
    @State private var editingBook: Book?

    /// Called when a book is tapped. The reader (#17) plugs in here.
    var onOpen: (Book) -> Void = { _ in }

    // Explicit because the private @State properties make the memberwise
    // initializer fileprivate.
    init(onOpen: @escaping (Book) -> Void = { _ in }) {
        self.onOpen = onOpen
    }

    private var books: [Book] {
        LibraryQuery.sort(LibraryQuery.filter(allBooks, matching: searchText), by: sort)
    }

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("Library")
                .searchable(text: $searchText, prompt: "Title, author, fandom or tag")
                .toolbar { toolbar }
                .overlay { importOverlay }
                .overlay { dropHighlight }
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
                set: { if !$0, importController.summary != nil { importController.dismissSummary() } }
            ),
            presenting: importController.summary
        ) { _ in
            Button("OK") { importController.dismissSummary() }
        } message: { summary in
            Text(summary.message)
        }
        .sensoryFeedback(.success, trigger: importController.summary) { _, new in
            new?.isQuietSuccess == true
        }
        // An alert rather than a confirmation dialog: on the wide display a
        // dialog becomes a popover anchored to the whole library, with no Cancel.
        .alert(
            "Delete “\(bookPendingDelete?.title ?? "")”?",
            isPresented: Binding(get: { bookPendingDelete != nil }, set: { if !$0 { bookPendingDelete = nil } }),
            presenting: bookPendingDelete
        ) { book in
            Button("Delete Book", role: .destructive) { delete(book) }
            Button("Cancel", role: .cancel) { bookPendingDelete = nil }
        } message: { _ in
            Text("The book, its file and its highlights will be removed from this iPhone.")
        }
        .fullScreenCover(item: $editingBook) { book in
            CoverEditorView(book: book)
        }
        .alert("Couldn't delete the book", isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
            Button("OK") { deleteError = nil }
        } message: {
            Text(deleteError ?? "")
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if allBooks.isEmpty {
            ContentUnavailableView {
                Label("Your shelf is empty", systemImage: "books.vertical")
            } description: {
                Text("Import books from Files, or drag them here. EPUB, PDF, Kindle, Word, FictionBook, comics, text and web pages all work.")
            } actions: {
                Button("Import Books") { showingPicker = true }
                    .buttonStyle(.borderedProminent)
            }
        } else if books.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            switch layout {
            case .shelf where showsShelf:
                ShelfView(onOpen: open, onEditCover: { editingBook = $0 }, onDelete: { bookPendingDelete = $0 })
                    .ignoresSafeArea(edges: .bottom)
                    // Light title and buttons over the dark wood.
                    .toolbarColorScheme(.dark, for: .navigationBar)
            case .shelf, .grid: grid
            case .list: list
            }
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104, maximum: 160), spacing: 20, alignment: .top)], spacing: 24) {
                ForEach(books) { book in
                    Button { open(book) } label: {
                        BookGridCell(book: book)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { bookMenu(for: book) }
                }
            }
            .padding()
        }
    }

    private var list: some View {
        List(books) { book in
            Button { open(book) } label: {
                BookListRow(book: book)
            }
            .buttonStyle(.plain)
            .contextMenu { bookMenu(for: book) }
            .swipeActions {
                Button("Delete", systemImage: "trash", role: .destructive) { bookPendingDelete = book }
            }
        }
        .listStyle(.plain)
    }

    @ViewBuilder
    private func bookMenu(for book: Book) -> some View {
        Button("Open", systemImage: "book") { open(book) }
        Button("Edit Cover", systemImage: "paintbrush") { editingBook = book }
        Divider()
        Button("Delete…", systemImage: "trash", role: .destructive) { bookPendingDelete = book }
    }

    // MARK: - Toolbar and overlays

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                showingPicker = true
            } label: {
                Label("Import Books", systemImage: "plus")
            }
            .disabled(importController.isImporting)
        }
        ToolbarItem(placement: .secondaryAction) {
            Menu {
                if showsShelf {
                    // The shelf always shows the user's own order, so here
                    // sorting rearranges the books on it (they can still be
                    // dragged around afterwards).
                    Menu("Arrange Shelf By", systemImage: "arrow.up.arrow.down") {
                        ForEach(LibrarySort.allCases.filter { $0 != .shelf }) { option in
                            Button(option.label) { arrangeShelf(by: option) }
                        }
                    }
                } else {
                    Picker("Sort By", selection: $sort) {
                        ForEach(LibrarySort.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                }
                Picker("View As", selection: $layout) {
                    Label("Shelf", systemImage: "books.vertical").tag(LibraryLayout.shelf)
                    Label("Grid", systemImage: "square.grid.2x2").tag(LibraryLayout.grid)
                    Label("List", systemImage: "list.bullet").tag(LibraryLayout.list)
                }
            } label: {
                Label("Sort and View", systemImage: "arrow.up.arrow.down")
            }
        }
    }

    /// The 3D shelf is showing (it gives way to the grid while searching).
    private var showsShelf: Bool { layout == .shelf && searchText.isEmpty }

    private func arrangeShelf(by option: LibrarySort) {
        withAnimation {
            guard LibraryQuery.arrangeShelf(allBooks, by: option) else { return }
            try? modelContext.save()
        }
    }

    @ViewBuilder
    private var importOverlay: some View {
        if importController.isImporting {
            Group {
                if let progress = importController.progress, progress.total > 1 {
                    ProgressView(value: progress.fractionDone) {
                        Text(progress.label)
                    } currentValueLabel: {
                        Text(progress.fileName).lineLimit(1).truncationMode(.middle)
                    }
                    .frame(maxWidth: 320)
                } else {
                    ProgressView(importController.progress?.label ?? String(localized: "Importing…"))
                }
            }
            .padding()
            .background(.regularMaterial, in: .rect(cornerRadius: 12))
        }
    }

    @ViewBuilder
    private var dropHighlight: some View {
        if isDropTargeted {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.tint, style: StrokeStyle(lineWidth: 3, dash: [8]))
                .padding(8)
                .accessibilityHidden(true)
        }
    }

    // MARK: - Actions

    private func open(_ book: Book) {
        onOpen(book)
    }

    private func delete(_ book: Book) {
        do {
            try LibraryActions.delete(book, in: modelContext)
        } catch {
            deleteError = error.localizedDescription
        }
    }
}

// MARK: - Cells

struct BookGridCell: View {
    let book: Book

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            BookCoverView(book: book)
            Text(book.title)
                .font(.footnote.weight(.medium))
                .lineLimit(2)
            if book.progress > 0 {
                ProgressView(value: book.progress)
                    .tint(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(book.accessibilitySummary)
        .accessibilityAddTraits(.isButton)
    }
}

struct BookListRow: View {
    let book: Book

    var body: some View {
        HStack(spacing: 12) {
            BookCoverView(book: book, maxPixel: 160)
                .frame(width: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(book.title)
                    .font(.headline)
                    .lineLimit(2)
                Text(book.displayAuthors)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let fandoms = book.ao3?.fandoms, !fandoms.isEmpty {
                    Text(fandoms.formatted(.list(type: .and)))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if book.progress > 0 {
                Text(book.progress, format: .percent.precision(.fractionLength(0)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(book.accessibilitySummary)
        .accessibilityAddTraits(.isButton)
    }
}

extension Book {
    /// "Title, by Author, 40% read" for VoiceOver.
    var accessibilitySummary: String {
        var parts = [title, String(localized: "by \(displayAuthors)")]
        if progress > 0 {
            parts.append(String(localized: "\(progress.formatted(.percent.precision(.fractionLength(0)))) read"))
        }
        return parts.joined(separator: ", ")
    }
}

extension LibrarySort {
    var label: LocalizedStringKey {
        switch self {
        case .shelf: "My Order"
        case .title: "Title"
        case .author: "Author"
        case .recentlyAdded: "Recently Added"
        case .recentlyOpened: "Recently Read"
        }
    }
}

#Preview("Empty") {
    let container = try! LibraryStore.makeContainer(inMemory: true)
    LibraryView()
        .environment(ImportController(container: container))
        .modelContainer(container)
}

#Preview("Books") {
    let container = try! LibraryStore.makeContainer(inMemory: true)
    for (i, title) in ["The Long Way Round", "A Fic Title", "Notes on Light", "Harbour"].enumerated() {
        let book = Book(relativeFilePath: "\(i)", contentHash: "\(i)", format: .epub, title: title,
                        authors: ["Ada Writer"], shelfOrder: i)
        book.progress = Double(i) / 4
        container.mainContext.insert(book)
    }
    return LibraryView()
        .environment(ImportController(container: container))
        .modelContainer(container)
}

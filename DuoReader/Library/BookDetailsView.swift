import SwiftData
import SwiftUI

/// Edits a book's title, authors and series, and tidies a title that came
/// from the file name. Changes apply on Save; Cancel leaves the book as it was.
struct BookDetailsView: View {
    let book: Book
    var covers: CoverLibrary = .shared

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var authors: String
    @State private var series: String
    @State private var seriesIndex: Double?
    @State private var saveError: String?

    init(book: Book, covers: CoverLibrary = .shared) {
        self.book = book
        self.covers = covers
        _title = State(initialValue: book.title)
        _authors = State(initialValue: book.authors.joined(separator: ", "))
        _series = State(initialValue: book.series ?? "")
        _seriesIndex = State(initialValue: book.seriesIndex)
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title, axis: .vertical)
                    TextField("Authors", text: $authors, prompt: Text("Separate names with commas"))
                        .textContentType(.name)
                } footer: {
                    if trimmedTitle.isEmpty {
                        Text("A book needs a title.")
                            .foregroundStyle(.red)
                    }
                }

                Section("Series") {
                    TextField("Series", text: $series)
                    TextField("Number", value: $seriesIndex, format: .number, prompt: Text("Volume or issue"))
                        .keyboardType(.decimalPad)
                }

                Section {
                    LabeledContent("File name") {
                        Text(book.titleSourceName)
                            .textSelection(.enabled)
                            .multilineTextAlignment(.trailing)
                    }
                    Button("Clean Up Title", systemImage: "wand.and.stars") { cleanUp() }
                    Button("Use File Name", systemImage: "arrow.uturn.backward") {
                        title = book.plainFileNameTitle
                    }
                    .disabled(title == book.plainFileNameTitle)
                } header: {
                    Text("From the File")
                } footer: {
                    Text("Clean Up removes release tags such as group names, years and “Digital”, and reads the series and volume from the file name.")
                }
            }
            .navigationTitle("Book Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(trimmedTitle.isEmpty)
                }
            }
            .alert("Couldn't save the details", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button("OK") { saveError = nil }
            } message: {
                Text(saveError ?? "")
            }
        }
    }

    /// Fills the fields from the file name. Nothing is saved until Save.
    private func cleanUp() {
        let cleanup = book.cleanedTitle
        title = cleanup.title
        if series.trimmingCharacters(in: .whitespaces).isEmpty, let newSeries = cleanup.series {
            series = newSeries
            seriesIndex = cleanup.seriesIndex
        }
    }

    private func save() {
        let newSeries = series.trimmingCharacters(in: .whitespacesAndNewlines)
        // Keep the name the title was made from before the title changes.
        if book.originalFileName == nil { book.originalFileName = book.title }
        book.title = trimmedTitle
        // Only when edited: a name such as "Tolkien, J. R. R." would
        // otherwise be split in two just by opening and saving.
        if authors != book.authors.joined(separator: ", ") {
            book.authors = authors.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        book.series = newSeries.isEmpty ? nil : newSeries
        book.seriesIndex = newSeries.isEmpty ? nil : seriesIndex
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            saveError = error.localizedDescription
            return
        }
        let book = book
        Task { await covers.metadataDidChange(for: book) }
        dismiss()
    }
}

/// Every title in the library that still looks like a file name, with the
/// cleaned-up version, so the user can pick which to change.
struct TitleCleanupView: View {
    var covers: CoverLibrary = .shared

    @Query(sort: [SortDescriptor(\Book.shelfOrder)]) private var books: [Book]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    /// Worked out once when the sheet opens, so the list doesn't change under
    /// the user's finger while they choose.
    @State private var suggestions: [Suggestion]?
    @State private var skipped: Set<UUID> = []
    @State private var saveError: String?

    struct Suggestion: Identifiable {
        let book: Book
        let cleanup: TitleCleanup
        var id: UUID { book.id }
    }

    private var chosen: [Suggestion] {
        (suggestions ?? []).filter { !skipped.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let suggestions, suggestions.isEmpty {
                    ContentUnavailableView(
                        "Titles Look Tidy",
                        systemImage: "checkmark.circle",
                        description: Text("No titles look like file names. To change one book, choose Edit Details on it.")
                    )
                } else {
                    List(suggestions ?? []) { suggestion in
                        row(suggestion)
                    }
                }
            }
            .navigationTitle("Clean Up Titles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(chosen.count == 1 ? "Change 1" : "Change \(chosen.count)") { apply() }
                        .disabled(chosen.isEmpty)
                }
            }
            .alert("Couldn't change the titles", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button("OK") { saveError = nil }
            } message: {
                Text(saveError ?? "")
            }
        }
        .onAppear {
            if suggestions == nil {
                suggestions = books.compactMap { book in
                    book.suggestedTitleCleanup.map { Suggestion(book: book, cleanup: $0) }
                }
            }
        }
    }

    private func row(_ suggestion: Suggestion) -> some View {
        let isOn = Binding(
            get: { !skipped.contains(suggestion.id) },
            set: { on in
                if on { skipped.remove(suggestion.id) } else { skipped.insert(suggestion.id) }
            }
        )
        return Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion.cleanup.title)
                    .font(.body)
                Text(suggestion.book.title)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private func apply() {
        let changes = chosen
        for change in changes { change.book.apply(change.cleanup) }
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            saveError = error.localizedDescription
            return
        }
        let books = changes.map(\.book)
        Task {
            for book in books { await covers.metadataDidChange(for: book) }
        }
        dismiss()
    }
}

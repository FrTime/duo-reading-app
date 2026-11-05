import SwiftUI

/// Searches Open Library and Google Books for a cover and hands back the
/// chosen image. Searching only happens when the user opens this sheet or
/// taps Search, and sends only the title, author and ISBN.
struct CoverSearchSheet: View {
    var onPick: (Data, CoverSearchResult) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var author: String
    private let isbn: String?
    @State private var outcome: CoverSearchOutcome?
    @State private var isSearching = false
    @State private var downloadingID: String?
    @State private var errorMessage: String?
    private let service = CoverSearchService()

    init(query: CoverSearchQuery, onPick: @escaping (Data, CoverSearchResult) -> Void) {
        self.onPick = onPick
        _title = State(initialValue: query.title)
        _author = State(initialValue: query.author ?? "")
        isbn = query.isbn
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    fields
                    results
                    Text("Searching sends the title and author to Open Library and Google Books. Nothing else leaves your phone.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle("Find a cover")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert("Couldn't use that cover", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .task {
                if !title.trimmingCharacters(in: .whitespaces).isEmpty {
                    await search()
                }
            }
        }
    }

    private var fields: some View {
        VStack(spacing: 8) {
            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.search)
                .onSubmit { Task { await search() } }
            TextField("Author", text: $author)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.search)
                .onSubmit { Task { await search() } }
            Button {
                Task { await search() }
            } label: {
                Label("Search", systemImage: "magnifyingglass")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isSearching || title.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    @ViewBuilder
    private var results: some View {
        if isSearching {
            ProgressView("Searching…")
                .frame(maxWidth: .infinity)
                .padding()
        } else if let outcome {
            if outcome.results.isEmpty {
                ContentUnavailableView {
                    Label("No covers found", systemImage: "magnifyingglass")
                } description: {
                    Text(outcome.failedProviders.count == CoverSearchProvider.allCases.count
                         ? "Couldn't reach the cover services. Check your connection and try again."
                         : "Try a shorter title, or leave out the author.")
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 12)], spacing: 16) {
                    ForEach(outcome.results) { result in
                        resultButton(result)
                    }
                }
                if !outcome.failedProviders.isEmpty {
                    Text("Couldn't reach \(outcome.failedProviders.map(\.displayName).formatted(.list(type: .and))), so some covers may be missing.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func resultButton(_ result: CoverSearchResult) -> some View {
        Button {
            Task { await pick(result) }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                AsyncImage(url: result.thumbnailURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    case .failure:
                        Image(systemName: "photo")
                            .font(.title)
                            .foregroundStyle(.secondary)
                    default:
                        ProgressView()
                    }
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(CoverDesign.frontAspectRatio, contentMode: .fit)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay {
                    if downloadingID == result.id {
                        ProgressView()
                            .padding(10)
                            .background(.thinMaterial, in: Circle())
                    }
                }
                Text(result.title)
                    .font(.caption)
                    .lineLimit(2)
                Text(result.year.map { "\(result.provider.displayName) · \(String($0))" } ?? result.provider.displayName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .disabled(downloadingID != nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(result.title), \(result.authors.formatted(.list(type: .and))), from \(result.provider.displayName)"))
        .accessibilityHint(Text("Uses this image for the front cover."))
        .accessibilityAddTraits(.isButton)
    }

    private func search() async {
        let query = CoverSearchQuery(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            author: author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : author,
            isbn: isbn
        )
        guard !query.isEmpty, !isSearching else { return }
        isSearching = true
        outcome = await service.search(query)
        isSearching = false
    }

    private func pick(_ result: CoverSearchResult) async {
        downloadingID = result.id
        defer { downloadingID = nil }
        // The large image first; the thumbnail if the large one isn't there.
        for url in [result.imageURL, result.thumbnailURL] {
            if let data = try? await CoverSearchService.downloadImage(url) {
                onPick(data, result)
                dismiss()
                return
            }
        }
        errorMessage = String(localized: "That cover couldn't be downloaded. Try another one.")
    }
}

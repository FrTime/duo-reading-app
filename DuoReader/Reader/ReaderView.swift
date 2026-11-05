import SwiftData
import SwiftUI

/// Full-screen reader for one book.
///
/// The bars are system toolbars on a navigation stack, so on iPhone Duo the
/// system can present them vertically beside the page when it wants to.
struct ReaderView: View {
    @State private var model: ReaderModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    init(book: Book, booksFolder: URL = LibraryImporter.defaultBooksFolder) {
        _model = State(initialValue: ReaderModel(book: book, booksFolder: booksFolder))
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(model.book.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
                .toolbarVisibility(chromeVisibility, for: .navigationBar, .bottomBar)
        }
        .statusBarHidden(!model.isChromeVisible)
        .animation(.easeInOut(duration: 0.2), value: model.isChromeVisible)
        .task { await model.load(in: modelContext) }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model.flush() }
        }
        .onDisappear { model.close() }
        .confirmationDialog(
            "Open This Link?",
            isPresented: Binding(
                get: { model.pendingExternalURL != nil },
                set: { if !$0 { model.pendingExternalURL = nil } }
            ),
            titleVisibility: .visible,
            presenting: model.pendingExternalURL
        ) { url in
            Button("Open in \(url.scheme == "mailto" ? String(localized: "Mail") : String(localized: "Safari"))") {
                openURL(url)
                model.pendingExternalURL = nil
            }
            Button("Cancel", role: .cancel) { model.pendingExternalURL = nil }
        } message: { url in
            Text(url.host() ?? url.absoluteString)
        }
    }

    private var chromeVisibility: Visibility {
        model.isChromeVisible || model.state != .ready ? .visible : .hidden
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView("Opening \(model.book.title)…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let error):
            ContentUnavailableView {
                Label(String(localized: error.title), systemImage: "book.closed")
            } description: {
                Text(error.message)
            } actions: {
                Button("Back to Library") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        case .ready:
            NavigatorHost(model: model)
                // Readium insets the page for the top and bottom safe areas
                // itself, but not the sides. On the Duo's outer screen the
                // status bar is a column on the side, so keep the side insets.
                .ignoresSafeArea(.container, edges: .vertical)
                // VoiceOver reads the book as one scrolling chapter (Readium
                // switches to scroll mode for it), so these move by chapter.
                .accessibilityAction(named: Text("Next Chapter")) {
                    Task { await model.goForward() }
                }
                .accessibilityAction(named: Text("Previous Chapter")) {
                    Task { await model.goBackward() }
                }
                .accessibilityAction(named: Text(model.isChromeVisible ? "Hide Controls" : "Show Controls")) {
                    model.isChromeVisible.toggle()
                }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button {
                dismiss()
            } label: {
                Label("Close", systemImage: "xmark")
            }
        }
        ToolbarItem(placement: .bottomBar) {
            ReaderProgressLabel(
                progression: model.progression,
                chapterTitle: model.chapterTitle,
                position: model.position,
                positionCount: model.positionCount
            )
        }
    }
}

/// "Chapter 3 · 42%" under the page.
struct ReaderProgressLabel: View {
    let progression: Double?
    let chapterTitle: String?
    let position: Int?
    let positionCount: Int?

    var body: some View {
        VStack(spacing: 2) {
            if let chapterTitle, !chapterTitle.isEmpty {
                Text(chapterTitle)
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
            }
            Text(ReaderProgressText.summary(progression: progression, position: position, positionCount: positionCount))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

/// Formats the reading position for the bottom bar.
enum ReaderProgressText {
    static func summary(progression: Double?, position: Int?, positionCount: Int?) -> String {
        let percent = progression.map { min(max($0, 0), 1) }?.formatted(.percent.precision(.fractionLength(0)))
        switch (position, positionCount, percent) {
        case let (position?, count?, percent?) where count > 0:
            return String(localized: "Location \(position) of \(count) · \(percent)")
        case let (_, _, percent?):
            return percent
        default:
            return ""
        }
    }
}

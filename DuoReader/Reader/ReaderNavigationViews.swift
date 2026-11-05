@preconcurrency import ReadiumShared
import SwiftUI

/// The table of contents. Tapping a chapter jumps there.
struct ReaderContentsView: View {
    let model: ReaderModel
    /// Closes the panel when it's docked beside the page. Nil when a sheet.
    var onDone: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ReaderPanelContainer(title: "Contents", onDone: onDone) {
            Group {
                if model.tableOfContents.isEmpty {
                    ContentUnavailableView(
                        "No Contents",
                        systemImage: "list.bullet",
                        description: Text("This book doesn't list its chapters.")
                    )
                } else {
                    let current = model.currentTOCEntryID
                    ScrollViewReader { proxy in
                        List(model.tableOfContents) { entry in
                            Button {
                                Task {
                                    await model.go(to: entry.link)
                                    close()
                                }
                            } label: {
                                HStack {
                                    Text(entry.title)
                                        .font(entry.depth == 0 ? .body : .subheadline)
                                        .padding(.leading, CGFloat(min(entry.depth, 4)) * 16)
                                    Spacer()
                                    if entry.id == current {
                                        Image(systemName: "bookmark.fill")
                                            .foregroundStyle(.tint)
                                            .accessibilityHidden(true)
                                    }
                                }
                                .contentShape(.rect)
                            }
                            .foregroundStyle(.primary)
                            .id(entry.id)
                            .accessibilityAddTraits(entry.id == current ? .isSelected : [])
                        }
                        .onAppear {
                            if let current {
                                proxy.scrollTo(current, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
    }

    private func close() {
        if let onDone { onDone() } else { dismiss() }
    }
}

/// Full-text search with each match shown in context.
struct ReaderSearchView: View {
    let model: ReaderModel
    /// Closes the panel when it's docked beside the page. Nil when a sheet.
    var onDone: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @FocusState private var fieldFocused: Bool
    @State private var query = ""
    @State private var results: [Locator] = []
    @State private var isSearching = false
    @State private var searchedQuery = ""
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        ReaderPanelContainer(title: "Search", onDone: onDone) {
            VStack(spacing: 0) {
                if onDone != nil {
                    // Docked, there's no navigation bar to hold the system
                    // search field.
                    TextField("Words or a phrase", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.search)
                        .autocorrectionDisabled()
                        .focused($fieldFocused)
                        .onSubmit { runSearch() }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                        .task {
                            // Focus once the panel has slid in; asking while
                            // it's still arriving is ignored.
                            try? await Task.sleep(for: .milliseconds(400))
                            fieldFocused = true
                        }
                }
                resultsList
            }
            .modifier(SystemSearchField(isEnabled: onDone == nil, query: $query, onSubmit: runSearch))
            .onChange(of: query) { _, text in
                // Clearing the field goes back to the start screen.
                if text.isEmpty { cancelSearch(); searchedQuery = ""; results = [] }
            }
            .onDisappear { cancelSearch() }
        }
    }

    @ViewBuilder
    private var resultsList: some View {
        if isSearching {
            ProgressView("Searching…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if searchedQuery.isEmpty {
            ContentUnavailableView(
                "Search This Book",
                systemImage: "magnifyingglass",
                description: Text("Find every place a word or phrase appears.")
            )
        } else if results.isEmpty {
            ContentUnavailableView.search(text: searchedQuery)
        } else {
            List(Array(results.enumerated()), id: \.offset) { _, locator in
                Button {
                    Task {
                        await model.go(to: locator)
                        model.highlightSearchResult(locator)
                        close()
                    }
                } label: {
                    SearchResultRow(locator: locator)
                }
                .foregroundStyle(.primary)
            }
            .safeAreaInset(edge: .top) {
                Text("^[\(results.count) result](inflect: true)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 4)
                    .background(.bar)
            }
        }
    }

    private func close() {
        if let onDone { onDone() } else { dismiss() }
    }

    private func runSearch() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // A new search replaces any still running, so a slow older one
        // can't overwrite newer results.
        searchTask?.cancel()
        isSearching = true
        searchTask = Task {
            let found = await model.search(text)
            guard !Task.isCancelled else { return }
            results = found
            searchedQuery = text
            isSearching = false
        }
    }

    private func cancelSearch() {
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
    }
}

/// The system search field in the navigation bar, for the sheet.
private struct SystemSearchField: ViewModifier {
    let isEnabled: Bool
    @Binding var query: String
    let onSubmit: () -> Void

    @ViewBuilder
    func body(content: Self.Content) -> some View {
        if isEnabled {
            content
                .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Words or a phrase")
                .onSubmit(of: .search) { onSubmit() }
        } else {
            content
        }
    }
}

/// "…before **match** after…", with the chapter title above.
private struct SearchResultRow: View {
    let locator: Locator

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title = locator.title, !title.isEmpty {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(snippet)
                .font(.subheadline)
                .lineLimit(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }

    private var snippet: AttributedString {
        var before = AttributedString("…" + (locator.text.before ?? "").suffix(60))
        var match = AttributedString(locator.text.highlight ?? "")
        var after = AttributedString((locator.text.after ?? "").prefix(80) + "…")
        before.foregroundColor = .secondary
        after.foregroundColor = .secondary
        match.inlinePresentationIntent = .stronglyEmphasized
        return before + match + after
    }
}

/// A slider through the whole book. Moving it previews the percentage;
/// letting go, or pausing, jumps there.
struct ReaderScrubber: View {
    let model: ReaderModel
    @State private var draft: Double?
    @State private var pendingJump: Task<Void, Never>?
    /// True while the thumb is moving and shortly after, so "Back" doesn't
    /// appear and shorten the track under the finger.
    @State private var isInteracting = false
    @State private var interactionEnd: Task<Void, Never>?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// VoiceOver swipes up or down move this far through the book.
    static let accessibilityStep = 0.05
    /// A pause this long jumps. The slider's end-of-drag report can't be
    /// relied on (it never arrives in the simulator), so this is the main path.
    static let settleDelay: Duration = .milliseconds(450)

    var body: some View {
        let value = draft ?? model.progression ?? 0
        HStack(spacing: 12) {
            VStack(spacing: 2) {
                Slider(value: Binding(get: { value }, set: { setDraft($0) }), in: 0 ... 1) { editing in
                    if !editing { jumpToDraft() }
                }
                .accessibilityLabel("Position in Book")
                .accessibilityValue(value.formatted(.percent.precision(.fractionLength(0))))
                .accessibilityAdjustableAction { direction in
                    let step = direction == .increment ? Self.accessibilityStep : -Self.accessibilityStep
                    let target = min(max((model.progression ?? 0) + step, 0), 1)
                    Task { await model.go(toProgression: target) }
                }

                if !dynamicTypeSize.isAccessibilitySize {
                    // Both stacked, one hidden, so the bar keeps its height
                    // while dragging. (At the largest text sizes the slider
                    // shows alone; the bar can't grow.)
                    ZStack {
                        ReaderProgressLabel(
                            progression: model.progression,
                            chapterTitle: model.chapterTitle,
                            position: model.position,
                            positionCount: model.positionCount
                        )
                        .opacity(draft == nil ? 1 : 0)
                        Text((draft ?? 0).formatted(.percent.precision(.fractionLength(0))))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .opacity(draft == nil ? 0 : 1)
                    }
                }
            }
            .frame(maxWidth: 520)

            if !isInteracting {
                ReturnToPlaceButton(model: model)
            }
        }
        .onChange(of: model.progression) { if !isInteracting { draft = nil } }
    }

    private func setDraft(_ value: Double) {
        draft = value
        isInteracting = true
        interactionEnd?.cancel()
        interactionEnd = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            isInteracting = false
            // The page has arrived by now; show its real position.
            draft = nil
        }
        pendingJump?.cancel()
        pendingJump = Task {
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled else { return }
            jumpToDraft()
        }
    }

    private func jumpToDraft() {
        pendingJump?.cancel()
        pendingJump = nil
        guard let target = draft else { return }
        Task {
            // Keep showing the target until the page arrives (the onChange
            // above clears it), unless the jump went nowhere.
            if !(await model.go(toProgression: target)) { draft = nil }
        }
    }
}

/// "Back to 42%" after a jump, like Kindle's return arrow.
struct ReturnToPlaceButton: View {
    let model: ReaderModel

    var body: some View {
        if let target = model.returnLocator {
            Button {
                Task { await model.goBackToReturnPoint() }
            } label: {
                let percent = target.locations.totalProgression?.formatted(.percent.precision(.fractionLength(0)))
                Label(
                    percent.map { String(localized: "Back to \($0)") } ?? String(localized: "Back"),
                    systemImage: "arrow.uturn.backward"
                )
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(minHeight: 44)
                .background(.regularMaterial, in: .capsule)
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Returns to where you were before jumping")
        }
    }
}

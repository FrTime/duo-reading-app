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
    @Environment(\.colorScheme) private var colorScheme
    @State private var showingSettings = false

    init(book: Book, booksFolder: URL = LibraryImporter.defaultBooksFolder) {
        _model = State(initialValue: ReaderModel(book: book, booksFolder: booksFolder))
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(model.book.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
                .toolbarVisibility(chromeVisibility, for: .navigationBar)
                .toolbarVisibility(bottomBarVisibility, for: .bottomBar)
                .toolbarColorScheme(pageColorScheme, for: .navigationBar, .bottomBar)
                // Bars take the page colour so a theme doesn't show a band
                // of system material behind the title.
                .toolbarBackground(pageColor, for: .navigationBar, .bottomBar)
                .background(pageColor.ignoresSafeArea())
        }
        // On a wide screen (an open Duo) settings dock at the side so the page
        // stays visible and live; at compact width the inspector shows as a
        // sheet. One presenter, so folding or unfolding with settings open
        // doesn't close them. It sits outside the reader's navigation stack:
        // inside it, the settings' own title and Done button took over the
        // reader's bar.
        .inspector(isPresented: $showingSettings) {
            ReaderSettingsView(settings: $model.settings, isReflowable: model.isReflowable)
                .inspectorColumnWidth(min: 320, ideal: 360, max: 420)
                .presentationDetents([.medium, .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        }
        .statusBarHidden(!model.isChromeVisible)
        .animation(.easeInOut(duration: 0.2), value: model.isChromeVisible)
        .task {
            model.systemIsDark = colorScheme == .dark
            await model.load(in: modelContext)
        }
        .onChange(of: colorScheme) { _, scheme in
            model.systemIsDark = scheme == .dark
        }
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

    private var pageColor: Color {
        Color(uiColor: model.palette.background.uiColor)
    }

    private var pageColorScheme: ColorScheme {
        model.palette.isDark ? .dark : .light
    }

    private var chromeVisibility: Visibility {
        model.isChromeVisible || model.state != .ready ? .visible : .hidden
    }

    /// The bottom bar's progress moves into the side panel when the pose
    /// gives the controls their own space.
    private var bottomBarVisibility: Visibility {
        model.layout?.controlsFrame != nil ? .hidden : chromeVisibility
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView("Opening \(model.book.title)…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .foregroundStyle(Color(uiColor: model.palette.text.uiColor))
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
            ReaderSurface(model: model) { showingSettings = true }
                // Edge to edge: Readium insets the page for the top and bottom
                // safe areas itself, and the layout keeps the page clear of
                // the side rail while centring a spread on the hinge.
                .ignoresSafeArea(.container)
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
        ToolbarItem(placement: .primaryAction) {
            Button {
                showingSettings = true
            } label: {
                Label("Reading Settings", systemImage: "textformat.size")
            }
            .disabled(model.state != .ready)
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

/// Lays the page out for the current Duo pose, from the reader's size and the
/// fold's division region.
private struct ReaderSurface: View {
    let model: ReaderModel
    let showSettings: () -> Void
    @Environment(\.layoutDirection) private var layoutDirection

    /// The layout works in physical left and right, the way the Duo's panels are.
    private func sideInsets(_ insets: EdgeInsets) -> ReaderLayout.SideInsets {
        layoutDirection == .rightToLeft
            ? ReaderLayout.SideInsets(left: insets.trailing, right: insets.leading)
            : ReaderLayout.SideInsets(left: insets.leading, right: insets.trailing)
    }

    var body: some View {
        GeometryReader { proxy in
            let fold = proxy.reservedRegions(kind: .division).first?.frame
            let layout = ReaderLayout.resolve(
                size: proxy.size,
                fold: fold,
                insets: sideInsets(proxy.safeAreaInsets),
                spread: model.settings.spread,
                flow: model.settings.flow
            )
            ZStack(alignment: .topLeading) {
                NavigatorHost(model: model, settings: model.settings)
                    .frame(width: layout.pageFrame.width, height: layout.pageFrame.height)
                    .offset(x: layout.pageFrame.minX, y: layout.pageFrame.minY)

                if let controls = layout.controlsFrame {
                    ReaderSidePanel(model: model, pose: layout.pose, showSettings: showSettings)
                        .frame(width: controls.width, height: controls.height)
                        .offset(x: controls.minX, y: controls.minY)
                        .transition(.opacity)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            // Fade the panel in and out, but don't animate the page's frame:
            // the web view would repaginate and then slide.
            .animation(.easeInOut(duration: 0.25), value: layout.controlsFrame != nil)
            .onChange(of: layout, initial: true) { _, new in
                model.layout = new
            }
        }
    }
}

/// Controls that get their own space instead of overlaying the page: on the
/// lower half in tabletop pose, or beside a single page in book pose.
struct ReaderSidePanel: View {
    let model: ReaderModel
    let pose: ReaderLayout.Pose
    let showSettings: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)
            ReaderProgressLabel(
                progression: model.progression,
                chapterTitle: model.chapterTitle,
                position: model.position,
                positionCount: model.positionCount
            )
            if let progression = model.progression {
                ProgressView(value: min(max(progression, 0), 1))
                    .frame(maxWidth: 360)
                    .accessibilityHidden(true)
            }
            HStack(spacing: 32) {
                Button {
                    // Through the page host, so turns use the chosen animation.
                    Task { await model.requestTurn?(.backward) }
                } label: {
                    Label("Previous Page", systemImage: "chevron.backward")
                        .frame(minWidth: 44, minHeight: 44)
                }
                Button(action: showSettings) {
                    Label("Reading Settings", systemImage: "textformat.size")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityHint(Text("Theme, font and layout"))
                Button {
                    Task { await model.requestTurn?(.forward) }
                } label: {
                    Label("Next Page", systemImage: "chevron.forward")
                        .frame(minWidth: 44, minHeight: 44)
                }
            }
            .labelStyle(.iconOnly)
            .font(.title2)
            .buttonStyle(.borderless)
            Spacer(minLength: 0)
        }
        .padding()
        // The reader ignores the vertical safe area, so keep the buttons
        // clear of the home indicator when the panel is at the bottom.
        .padding(.bottom, pose == .tabletop ? 20 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Reader Controls"))
        .foregroundStyle(Color(uiColor: model.palette.text.uiColor))
        .background(Color(uiColor: model.palette.background.uiColor))
    }
}

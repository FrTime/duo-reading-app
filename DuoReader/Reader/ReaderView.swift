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
    @AppStorage(OuterCoverSettingsSection.storageKey) private var showsCoverOnOutside = false
    @State private var hinge: OuterCoverPolicy.Hinge = .none
    @State private var outerCoverCamera = OuterCoverCamera.shared
    @State private var showingContents = false
    @State private var showingSearch = false

    init(book: Book, booksFolder: URL = LibraryImporter.defaultBooksFolder) {
        _model = State(initialValue: ReaderModel(book: book, booksFolder: booksFolder))
    }

    var body: some View {
        NavigationStack {
            content
                // Pages start below the title bar (see PageInsets), so measure
                // where it ends. Only while it shows: hiding it mustn't reflow.
                // It shows while the book opens, so this is known before the
                // first page is laid out.
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.frame(in: .global).minY + proxy.safeAreaInsets.top
                } action: { barBottom in
                    if chromeVisibility == .visible { model.titleBarBottom = barBottom }
                }
                // The scrubber is a bar of its own, not a toolbar item: on the
                // Duo the system can fold toolbars into the side rail, where
                // a slider gets squeezed and its drag lost.
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if showsScrubber {
                        ReaderScrubber(model: model)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity)
                            .background(pageColor)
                            .transition(.opacity)
                    }
                }
                .navigationTitle(model.book.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
                .toolbarVisibility(chromeVisibility, for: .navigationBar)
                .toolbarColorScheme(pageColorScheme, for: .navigationBar)
                // Bars take the page colour so a theme doesn't show a band
                // of system material behind the title.
                .toolbarBackground(pageColor, for: .navigationBar)
                // Always drawn, not only once content scrolls under it, so a
                // line never shows faded through the bar's material.
                .toolbarBackgroundVisibility(.visible, for: .navigationBar)
                .background(pageColor.ignoresSafeArea())
        }
        .sheet(isPresented: $showingContents) {
            ReaderContentsView(model: model)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showingSearch) {
            ReaderSearchView(model: model)
                .presentationDetents([.large])
        }
        // On a wide screen (an open Duo) settings dock at the side so the page
        // stays visible and live; at compact width the inspector shows as a
        // sheet. One presenter, so folding or unfolding with settings open
        // doesn't close them. It sits outside the reader's navigation stack:
        // inside it, the settings' own title and Done button took over the
        // reader's bar.
        .inspector(isPresented: $showingSettings) {
            ReaderSettingsView(
                settings: $model.settings,
                isReflowable: model.isReflowable,
                outerCoverStatus: OuterCoverPolicy.status(outerCoverInputs)
            )
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
            if phase == .active { outerCoverCamera.refreshAccess() }
        }
        .onDisappear {
            model.close()
            outerCoverCamera.setRunning(false)
        }
        .modifier(OuterCoverCameraControl(
            hinge: $hinge,
            camera: outerCoverCamera,
            shouldRunCamera: OuterCoverPolicy.shouldRunCamera(outerCoverInputs)
        ))
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

    private var outerCoverInputs: OuterCoverPolicy.Inputs {
        OuterCoverPolicy.Inputs(
            isEnabled: showsCoverOnOutside,
            cameraAccess: outerCoverCamera.access,
            hinge: hinge,
            isActive: scenePhase == .active,
            isReaderReady: model.state == .ready
        )
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

    /// The scrubber shows with the bars, unless the pose gives the
    /// controls a panel of their own.
    private var showsScrubber: Bool {
        model.isChromeVisible && model.state == .ready && model.layout?.controlsFrame == nil
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
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                // One panel at a time: settings may be open as a sheet.
                showingSettings = false
                showingContents = true
            } label: {
                Label("Contents", systemImage: "list.bullet")
            }
            .disabled(model.state != .ready)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                model.highlightSearchResult(nil)
                showingSettings = false
                showingSearch = true
            } label: {
                Label("Search", systemImage: "magnifyingglass")
            }
            .disabled(model.state != .ready || !model.isSearchable)
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
                // Bars propose a narrow width; show the whole line.
                .fixedSize()
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
    /// The side space to keep clear, as the difference between the safe frame
    /// and the edge-to-edge frame. (A view that ignores the safe area reports
    /// zero insets, so they're measured this way.) Global coordinates are
    /// physical left to right, as the Duo's panels are.
    private static func sideInsets(safe: CGRect, full: CGRect) -> ReaderLayout.SideInsets {
        ReaderLayout.SideInsets(left: max(0, safe.minX - full.minX), right: max(0, full.maxX - safe.maxX))
    }

    /// The widest side insets seen at the current size. The rail holds the
    /// bars, so it comes and goes as the bars show and hide; keeping the
    /// widest means the page doesn't re-paginate on every tap, and text never
    /// ends up under the rail when the bars come back.
    @State private var railInsets: RailInsets?

    struct RailInsets: Equatable {
        var size: CGSize
        var insets: ReaderLayout.SideInsets
    }

    var body: some View {
        GeometryReader { safe in
            // Edge to edge: Readium insets the page for the top and bottom
            // safe areas itself, and the layout keeps the page clear of the
            // side rail while centring a spread on the hinge.
            GeometryReader { full in
                let measured = Self.sideInsets(safe: safe.frame(in: .global), full: full.frame(in: .global))
                let kept = railInsets?.size == full.size ? railInsets?.insets : nil
                let insets = Self.widest(measured, kept)
                surface(in: full, insets: insets)
                    .onChange(of: RailInsets(size: full.size, insets: insets), initial: true) { _, new in
                        railInsets = new
                    }
            }
            .ignoresSafeArea(.container)
        }
    }

    static func widest(_ a: ReaderLayout.SideInsets, _ b: ReaderLayout.SideInsets?) -> ReaderLayout.SideInsets {
        guard let b else { return a }
        return ReaderLayout.SideInsets(left: max(a.left, b.left), right: max(a.right, b.right))
    }

    private func surface(in proxy: GeometryProxy, insets: ReaderLayout.SideInsets) -> some View {
        Group {
            let fold = proxy.reservedRegions(kind: .division).first?.frame
            let layout = ReaderLayout.resolve(
                size: proxy.size,
                fold: fold,
                insets: insets,
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
            ReturnToPlaceButton(model: model)
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

import SwiftUI

/// Builds a book's 3D cover: pick or find an image, choose a template for the
/// spine and back, place text, and turn the book in 3D. Starts from the
/// book's current cover (its own artwork the first time).
///
/// When the window is wide (the open Duo) or in landscape, the cover and the
/// tools sit side by side; otherwise the tools sit under the cover.
struct CoverEditorView: View {
    @State private var model: CoverEditorModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var confirmingDiscard = false
    @State private var confirmingReset = false
    @State private var panelPickerWidth: CGFloat = .infinity
    @State private var panelNamesWidth: CGFloat = 0

    init(book: Book) {
        _model = State(initialValue: CoverEditorModel(book: book))
    }

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                if Self.isSideBySide(sizeClass: sizeClass, size: proxy.size) {
                    // On the open Duo the cover sits on the left screen and the
                    // tools on the right, with nothing on the hinge. Landscape
                    // on the closed Duo is side by side too: stacked, the
                    // cover shrank to a thumbnail and the tools to a sliver.
                    // There the tools get the wider share: the cover is
                    // tall and narrow, and fits in less.
                    let fold = Self.usableFold(in: proxy)
                    HStack(spacing: 0) {
                        stageArea
                            .frame(width: fold?.minX ?? proxy.size.width * (sizeClass == .regular ? 0.55 : 0.45))
                        Divider()
                            .frame(width: fold?.width ?? 1)
                        panelArea
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                } else {
                    VStack(spacing: 0) {
                        stageArea
                        Divider()
                        panelArea
                            .frame(maxHeight: .infinity)
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
            .navigationTitle("Edit cover")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .interactiveDismissDisabled(model.hasChanges)
            .confirmationDialog("Discard your changes to this cover?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
                Button("Discard changes", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) {}
            }
            .confirmationDialog("Go back to the original cover?", isPresented: $confirmingReset, titleVisibility: .visible) {
                Button("Use original cover", role: .destructive) {
                    Task { await model.resetToDefault() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your image, text and colours for this book will be replaced.")
            }
            .alert("Something went wrong", isPresented: errorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
        }
        .task { await model.load() }
        .onChange(of: model.design) { _, _ in model.designDidChange() }
    }

    // MARK: - Areas

    private var stageArea: some View {
        VStack(spacing: 12) {
            Picker("Show", selection: $model.stage) {
                ForEach(CoverFace.allCases) { face in
                    Text(face.displayName).tag(CoverEditorModel.Stage.face(face))
                }
                Text("3D").tag(CoverEditorModel.Stage.threeD)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            ZStack {
                if !model.isLoaded {
                    ProgressView()
                } else {
                    switch model.stage {
                    case .face(let face):
                        CoverCanvasView(model: model, face: face)
                            .padding(.horizontal, 24)
                    case .threeD:
                        CoverPreview3DView(
                            rendered: model.rendered,
                            revision: model.renderRevision,
                            thickness: model.design.thickness,
                            heightScale: model.sizeScale
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.secondarySystemBackground))
    }

    private var panelArea: some View {
        VStack(spacing: 0) {
            // Names when they fit; icons on narrow panels (landscape on the
            // closed Duo), where the equal-width segments cut "Template"
            // short.
            panelPicker(iconsOnly: panelNamesWidth > panelPickerWidth)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { panelPickerWidth = $0 }
                .background {
                    // The names side by side at the segmented control's
                    // text size, plus each segment's padding, measured out
                    // of sight. (A fixed-size copy of the picker itself
                    // overstates it: it sizes every segment to the widest.)
                    HStack(spacing: 0) {
                        ForEach(CoverEditorModel.Panel.allCases) { panel in
                            Text(panel.title)
                                .font(.footnote.weight(.semibold))
                                .padding(.horizontal, 10)
                        }
                    }
                    .fixedSize()
                    .hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { panelNamesWidth = $0 }
                }
                .padding()

            ScrollView {
                Group {
                    switch model.panel {
                    case .image: CoverImagePanel(model: model)
                    case .template: CoverTemplatePanel(model: model)
                    case .text: CoverTextPanel(model: model)
                    case .book: CoverBookPanel(model: model)
                    }
                }
                .padding([.horizontal, .bottom])
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .disabled(!model.isLoaded)
        }
        .frame(maxWidth: .infinity)
    }

    private func panelPicker(iconsOnly: Bool) -> some View {
        Picker("Tools", selection: $model.panel) {
            ForEach(CoverEditorModel.Panel.allCases) { panel in
                Group {
                    if iconsOnly {
                        Image(systemName: panel.systemImage)
                            .accessibilityLabel(Text(panel.title))
                    } else {
                        Text(panel.title)
                    }
                }
                .tag(panel)
            }
        }
        .pickerStyle(.segmented)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") {
                if model.hasChanges {
                    confirmingDiscard = true
                } else {
                    dismiss()
                }
            }
        }
        // On the leading side: the trailing edge of the open Duo is the
        // system's status column, where extra items get pushed.
        ToolbarItem(placement: .topBarLeading) {
            Menu("More", systemImage: "ellipsis") {
                Button("Use original cover", systemImage: "arrow.uturn.backward") {
                    confirmingReset = true
                }
            }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Save") {
                Task {
                    if await model.save() { dismiss() }
                }
            }
            .disabled(!model.isLoaded || model.isSaving)
        }
    }

    /// Cover and tools side by side: on wide windows (the open Duo) and in
    /// landscape, where stacking them leaves neither enough height.
    nonisolated static func isSideBySide(sizeClass: UserInterfaceSizeClass?, size: CGSize) -> Bool {
        sizeClass == .regular || size.width > size.height
    }

    /// The hinge, when there's room for the stage on one side of it and
    /// the tools on the other.
    nonisolated static func usableFold(in proxy: GeometryProxy) -> CGRect? {
        guard let fold = ShelfView.verticalFold(in: proxy),
              fold.minX > 200, proxy.size.width - fold.maxX > 280
        else { return nil }
        return fold
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    }
}

import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Image

struct CoverImagePanel: View {
    @Bindable var model: CoverEditorModel

    @State private var showingSearch = false
    @State private var showingFiles = false
    @State private var showingWebSearch = false
    @State private var photo: PhotosPickerItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button {
                showingSearch = true
            } label: {
                Label("Search for a cover", systemImage: "magnifyingglass")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button {
                showingWebSearch = true
            } label: {
                Label("Search the web for any image", systemImage: "globe")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            // Side by side when the labels fit on one line each; stacked on
            // narrow panels (the tools half of the open Duo), where three
            // across squeezed the words into one letter per line.
            ViewThatFits(in: .horizontal) {
                HStack { imageSourceButtons }
                VStack { imageSourceButtons }
            }
            .buttonStyle(.bordered)
            .lineLimit(1)

            if model.hasEmbeddedCover, model.design.imageSource != .embedded {
                Button {
                    Task { await model.useEmbeddedCover() }
                } label: {
                    Label("Use the cover from the file", systemImage: "doc.richtext")
                }
            }

            if model.design.hasImage {
                if let source = sourceDescription {
                    Text(source)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if model.design.template.showsImageOnFront {
                    VStack(alignment: .leading) {
                        Text("Zoom")
                            .font(.subheadline)
                        Slider(value: $model.design.imageZoom, in: 1...4) {
                            Text("Zoom")
                        } minimumValueLabel: {
                            Image(systemName: "minus.magnifyingglass")
                        } maximumValueLabel: {
                            Image(systemName: "plus.magnifyingglass")
                        }
                        Text("Drag the front to move the image, or pinch to zoom.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Toggle("Show the whole image", isOn: Binding(
                        get: { model.design.fitsWholeImage == true },
                        set: { model.design.fitsWholeImage = $0 ? true : nil }
                    ))
                    Text("Off fills the front and crops the edges. On fits the whole picture, with a soft blur of it behind.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Reset position", systemImage: "arrow.counterclockwise") {
                        model.resetCrop()
                    }
                } else {
                    Text("The Text only template doesn't show the image. Pick another template to see it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button("Remove image", systemImage: "trash", role: .destructive) {
                    model.removeImage()
                }
            }
        }
        .sheet(isPresented: $showingSearch) {
            CoverSearchSheet(query: searchQuery) { data, result in
                Task {
                    await model.setImage(data, source: .search(provider: result.provider.rawValue, url: result.imageURL))
                }
            }
        }
        .fullScreenCover(isPresented: $showingWebSearch) {
            WebCoverSearchView(initialQuery: WebImageSearch.defaultQuery(title: searchQuery.title, authors: searchQuery.author.map { [$0] } ?? [])) { data, url in
                Task {
                    let source: CoverImageSource = url.map { .search(provider: WebImageSearch.providerName, url: $0) } ?? .userImage
                    await model.setImage(data, source: source)
                }
            }
        }
        .fileImporter(isPresented: $showingFiles, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            Task { await importFile(url) }
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    await model.setImage(data, source: .userImage)
                } else {
                    model.errorMessage = String(localized: "That photo couldn't be loaded.")
                }
                photo = nil
            }
        }
    }

    /// Title and author as the user sees them, cleaned up when the title is
    /// really a file name.
    private var searchQuery: CoverSearchQuery {
        let book = model.book
        return CoverSearchQuery.make(
            title: book.authors.isEmpty ? nil : book.title,
            authors: book.authors,
            identifiers: book.identifiers,
            fileName: book.title
        )
    }

    private var sourceDescription: String? {
        switch model.design.imageSource {
        case .none: nil
        case .embedded: String(localized: "From the book's file.")
        case .userImage: String(localized: "Your own image.")
        case .search(let provider, let url) where provider == WebImageSearch.providerName:
            String(localized: "From \(url.host() ?? "the web").")
        case .search(let provider, _):
            String(localized: "From \(CoverSearchProvider(rawValue: provider)?.displayName ?? provider).")
        }
    }

    @ViewBuilder
    private var imageSourceButtons: some View {
        PhotosPicker(selection: $photo, matching: .images) {
            Label("Photos", systemImage: "photo.on.rectangle")
                .frame(maxWidth: .infinity)
        }
        Button {
            showingFiles = true
        } label: {
            Label("Files", systemImage: "folder")
                .frame(maxWidth: .infinity)
        }
        PasteButton(supportedContentTypes: [.image]) { providers in
            paste(providers)
        }
        .labelStyle(.titleAndIcon)
        .buttonBorderShape(.roundedRectangle)
        .tint(.secondary)
    }

    private func importFile(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= 30 * 1024 * 1024, let data = try? Data(contentsOf: url) else {
            model.errorMessage = String(localized: "That image is too large or couldn't be read.")
            return
        }
        await model.setImage(data, source: .userImage)
    }

    /// An image copied from Safari, Photos or anywhere else.
    private func paste(_ providers: [NSItemProvider]) {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }) else { return }
        let model = model
        provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
            Task { @MainActor in
                guard let data, data.count <= 30 * 1024 * 1024 else {
                    model.errorMessage = String(localized: "That image couldn't be pasted.")
                    return
                }
                await model.setImage(data, source: .userImage)
            }
        }
    }
}

// MARK: - Template

struct CoverTemplatePanel: View {
    @Bindable var model: CoverEditorModel

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 12)], spacing: 12) {
            ForEach(CoverTemplate.allCases.filter { $0.isAvailable(hasImage: model.design.hasImage) }) { template in
                TemplateTile(model: model, template: template)
            }
        }
    }
}

private struct TemplateTile: View {
    @Bindable var model: CoverEditorModel
    let template: CoverTemplate
    @State private var thumbnail: UIImage?

    var body: some View {
        let isCurrent = model.design.template == template
        Button {
            model.apply(template)
        } label: {
            VStack(spacing: 6) {
                Group {
                    if let thumbnail {
                        Image(uiImage: thumbnail).resizable()
                    } else {
                        Rectangle().fill(.quaternary)
                    }
                }
                .aspectRatio(CoverDesign.frontAspectRatio, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(isCurrent ? Color.accentColor : .clear, lineWidth: 3)
                }
                Text(template.displayName)
                    .font(.caption)
                    .foregroundStyle(isCurrent ? Color.accentColor : .primary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(template.displayName))
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
        .task(id: model.design) {
            thumbnail = await model.thumbnail(for: template)
        }
    }
}

// MARK: - Text

struct CoverTextPanel: View {
    @Bindable var model: CoverEditorModel

    var body: some View {
        if let box = model.selectedBox {
            TextBoxInspector(model: model, box: box)
        } else {
            boxList
        }
    }

    private var boxList: some View {
        VStack(alignment: .leading, spacing: 12) {
            let face = model.face ?? .front
            let boxes = model.design.textBoxes(on: face)
            if boxes.isEmpty {
                Text("No text on the \(face.displayName.localizedLowercase).")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(boxes) { box in
                    Button {
                        model.selectedBoxID = box.id
                    } label: {
                        HStack {
                            Image(systemName: box.isVertical ? "textformat.size.larger" : "textformat")
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            Text(box.text)
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 4)
                }
            }
            Button("Add text to the \(face.displayName.localizedLowercase)", systemImage: "plus") {
                model.addTextBox(on: face)
            }
            .buttonStyle(.bordered)
            Text("Tap a text box on the cover to edit it. Drag to move it, or drag its corner to resize.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

private struct TextBoxInspector: View {
    @Bindable var model: CoverEditorModel
    let box: CoverTextBox

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button("All text", systemImage: "chevron.left") {
                    model.selectedBoxID = nil
                }
                Spacer()
                Button("Delete", systemImage: "trash", role: .destructive) {
                    model.deleteTextBox(box.id)
                }
                .labelStyle(.iconOnly)
            }

            TextField("Text", text: binding(\.text), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...6)

            ViewThatFits(in: .horizontal) {
                HStack { fontPickers }
                VStack(alignment: .leading) { fontPickers }
            }
            .pickerStyle(.menu)
            .lineLimit(1)

            VStack(alignment: .leading) {
                Text("Size")
                    .font(.subheadline)
                Slider(value: binding(\.fontSize), in: CoverTextBox.fontSizeRange) {
                    Text("Size")
                } minimumValueLabel: {
                    Image(systemName: "textformat.size.smaller")
                } maximumValueLabel: {
                    Image(systemName: "textformat.size.larger")
                }
            }

            ColorPicker("Colour", selection: colorBinding, supportsOpacity: false)

            Picker("Alignment", selection: binding(\.alignment)) {
                Image(systemName: "text.alignleft").tag(CoverTextAlignment.leading)
                    .accessibilityLabel(Text("Left"))
                Image(systemName: "text.aligncenter").tag(CoverTextAlignment.center)
                    .accessibilityLabel(Text("Centre"))
                Image(systemName: "text.alignright").tag(CoverTextAlignment.trailing)
                    .accessibilityLabel(Text("Right"))
            }
            .pickerStyle(.segmented)

            Toggle("Run down the spine", isOn: binding(\.isVertical))
            Toggle("Capitals", isOn: binding(\.isUppercased))
            Toggle("Shadow", isOn: binding(\.hasShadow))
        }
    }

    @ViewBuilder
    private var fontPickers: some View {
        Picker("Font", selection: binding(\.font)) {
            ForEach(CoverFont.allCases) { font in
                Text(font.displayName)
                    .font(font.familyName.map { Font.custom($0, size: 17) } ?? .body)
                    .tag(font)
            }
        }
        Picker("Weight", selection: binding(\.weight)) {
            ForEach(CoverFontWeight.allCases) { weight in
                Text(weight.displayName).tag(weight)
            }
        }
    }

    private func current() -> CoverTextBox {
        model.design.textBoxes.first { $0.id == box.id } ?? box
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<CoverTextBox, Value>) -> Binding<Value> {
        Binding(
            get: { current()[keyPath: keyPath] },
            set: { value in model.update(box.id) { $0[keyPath: keyPath] = value } }
        )
    }

    private var colorBinding: Binding<CGColor> {
        Binding(
            get: { current().color.cgColor },
            set: { color in
                if let rgba = RGBAColor(cgColor: color) {
                    model.update(box.id) { $0.color = rgba }
                }
            }
        )
    }
}

// MARK: - Book

struct CoverBookPanel: View {
    @Bindable var model: CoverEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading) {
                Text("Spine thickness")
                    .font(.subheadline)
                Slider(value: Binding(
                    get: { model.design.thickness },
                    set: {
                        model.design.thickness = $0
                        // From now on the spine stays as the user set it.
                        model.design.isThicknessCustom = true
                    }
                ), in: CoverDesign.thicknessRange) {
                    Text("Spine thickness")
                } minimumValueLabel: {
                    Text("Thin").font(.caption)
                } maximumValueLabel: {
                    Text("Thick").font(.caption)
                }
                Text("Starts from the book's length. A thicker spine has room for larger text.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading) {
                Text("Book size")
                    .font(.subheadline)
                Slider(value: Binding(
                    get: { model.sizeScale },
                    set: { model.design.heightScale = $0 }
                ), in: CoverDesign.heightScaleRange) {
                    Text("Book size")
                } minimumValueLabel: {
                    Image(systemName: "book.closed").font(.caption)
                } maximumValueLabel: {
                    Image(systemName: "book.closed").font(.title3)
                }
                Text("Taller or shorter than its neighbours on the shelf, like real books.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if !model.design.hasImage {
                ColorPicker("Front colour", selection: colorBinding(for: .front), supportsOpacity: false)
            }
            ColorPicker("Spine colour", selection: colorBinding(for: .spine), supportsOpacity: false)
            ColorPicker("Back colour", selection: colorBinding(for: .back), supportsOpacity: false)
        }
    }

    private func colorBinding(for face: CoverFace) -> Binding<CGColor> {
        Binding(
            get: { model.color(of: face).cgColor },
            set: { color in
                if let rgba = RGBAColor(cgColor: color) {
                    model.setColor(rgba, of: face)
                }
            }
        )
    }
}

extension RGBAColor {
    /// Converts any CGColor (say, from a ColorPicker) to sRGB.
    init?(cgColor: CGColor) {
        guard
            let srgb = CGColorSpace(name: CGColorSpace.sRGB),
            let converted = cgColor.converted(to: srgb, intent: .defaultIntent, options: nil),
            let c = converted.components, c.count >= 3
        else { return nil }
        self.init(red: Double(c[0]), green: Double(c[1]), blue: Double(c[2]), alpha: Double(c.count > 3 ? c[3] : 1))
    }
}

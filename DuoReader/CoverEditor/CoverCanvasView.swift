import SwiftUI

/// One face of the cover, drawn live, with handles for its text boxes.
/// On the front, with the Image panel open, drag pans the image and pinch zooms.
struct CoverCanvasView: View {
    @Bindable var model: CoverEditorModel
    let face: CoverFace

    @State private var panStart: (x: Double, y: Double)?
    @State private var zoomStart: Double?

    var body: some View {
        GeometryReader { proxy in
            let size = Self.fit(aspect: aspect, in: proxy.size)
            ZStack(alignment: .topLeading) {
                Group {
                    if let image = model.rendered?.image(for: face) {
                        Image(uiImage: image)
                            .resizable()
                            .interpolation(.high)
                    } else {
                        Rectangle().fill(.quaternary)
                    }
                }
                .frame(width: size.width, height: size.height)
                .accessibilityLabel(Text("\(face.displayName) of the cover"))
                .accessibilityAddTraits(.isImage)

                ForEach(model.design.textBoxes(on: face)) { box in
                    TextBoxHandle(model: model, box: box, canvas: size)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .onTapGesture { model.selectedBoxID = nil }
            .gesture(panGesture(canvas: size), including: canPanImage ? .all : .subviews)
            .simultaneousGesture(zoomGesture, including: canPanImage ? .all : .subviews)
            .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
    }

    /// Width over height of the face.
    private var aspect: CGFloat {
        switch face {
        case .front, .back: CoverDesign.frontAspectRatio
        case .spine: model.design.thickness * CoverDesign.frontAspectRatio
        }
    }

    private var canPanImage: Bool {
        face == .front && model.panel == .image && model.design.hasImage && model.design.template.showsImageOnFront
    }

    static func fit(aspect: CGFloat, in bounds: CGSize) -> CGSize {
        guard bounds.width > 0, bounds.height > 0, aspect > 0 else { return .zero }
        let width = min(bounds.width, bounds.height * aspect)
        return CGSize(width: width, height: width / aspect)
    }

    private func panGesture(canvas: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard let image = model.image else { return }
                let start = panStart ?? (model.design.imageOffsetX, model.design.imageOffsetY)
                panStart = start
                let bounds = CGRect(origin: .zero, size: canvas)
                let filled = CoverRenderer.fillRect(imageSize: image.size, in: bounds, zoom: model.design.imageZoom, offsetX: 0, offsetY: 0)
                let spareX = (filled.width - bounds.width) / 2
                let spareY = (filled.height - bounds.height) / 2
                if spareX > 0 {
                    model.design.imageOffsetX = min(max(start.x - value.translation.width / spareX, -1), 1)
                }
                if spareY > 0 {
                    model.design.imageOffsetY = min(max(start.y - value.translation.height / spareY, -1), 1)
                }
            }
            .onEnded { _ in panStart = nil }
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = zoomStart ?? model.design.imageZoom
                zoomStart = start
                model.design.imageZoom = min(max(start * value.magnification, 1), 4)
            }
            .onEnded { _ in zoomStart = nil }
    }
}

/// The outline of one text box: tap to select, drag to move, drag the
/// corner to resize.
private struct TextBoxHandle: View {
    @Bindable var model: CoverEditorModel
    let box: CoverTextBox
    let canvas: CGSize

    @State private var moveStart: CoverTextBox?
    @State private var resizeStart: CoverTextBox?

    private var isSelected: Bool { model.selectedBoxID == box.id }

    var body: some View {
        let rect = CoverRenderer.rect(for: box, in: canvas)
        Rectangle()
            .strokeBorder(
                isSelected ? Color.accentColor : Color.white.opacity(0.6),
                style: StrokeStyle(lineWidth: isSelected ? 2 : 1, dash: isSelected ? [] : [4, 3])
            )
            .background(Color.white.opacity(0.001))
            .frame(width: max(rect.width, 8), height: max(rect.height, 8))
            .overlay(alignment: .bottomTrailing) {
                if isSelected {
                    Circle()
                        .fill(Color.accentColor)
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                        .frame(width: 22, height: 22)
                        .offset(x: 11, y: 11)
                        .gesture(resizeGesture)
                        .accessibilityHidden(true)
                }
            }
            .offset(x: rect.minX, y: rect.minY)
            .onTapGesture { select() }
            .gesture(moveGesture)
            .accessibilityElement()
            .accessibilityLabel(Text(box.text))
            .accessibilityHint(Text("Text box. Double-tap to edit."))
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { select() }
    }

    private func select() {
        model.selectedBoxID = box.id
        model.panel = .text
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let start = moveStart ?? box
                moveStart = start
                if model.selectedBoxID != box.id { model.selectedBoxID = box.id }
                model.update(box.id) {
                    $0.centerX = start.centerX + value.translation.width / max(canvas.width, 1)
                    $0.centerY = start.centerY + value.translation.height / max(canvas.height, 1)
                }
            }
            .onEnded { _ in moveStart = nil }
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = resizeStart ?? box
                resizeStart = start
                model.update(box.id) {
                    // Grow from the top-left corner, which stays put.
                    let width = start.width + value.translation.width / max(canvas.width, 1)
                    let height = start.height + value.translation.height / max(canvas.height, 1)
                    $0.width = max(width, CoverTextBox.minimumSide)
                    $0.height = max(height, CoverTextBox.minimumSide)
                    $0.centerX = start.centerX - start.width / 2 + $0.width / 2
                    $0.centerY = start.centerY - start.height / 2 + $0.height / 2
                }
            }
            .onEnded { _ in resizeStart = nil }
    }
}

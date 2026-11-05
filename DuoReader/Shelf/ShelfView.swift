import RealityKit
import SwiftData
import SwiftUI

/// The main library view: every book standing on a 3D bookcase.
///
/// Tap a book to pull it out and see its cover, tap again (or Read) to open
/// it. Long-press to pick a book up and drag it to a new place; the order is
/// saved to `Book.shelfOrder`. Drag on the case to scroll between shelves.
/// Shelves are as wide as the screen, so the open Duo holds more per shelf.
struct ShelfView: View {
    var onOpen: (Book) -> Void
    var onEditCover: ((Book) -> Void)?
    var onDelete: ((Book) -> Void)?
    var covers: CoverLibrary = .shared

    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(sort: [SortDescriptor(\Book.shelfOrder), SortDescriptor(\Book.dateAdded)]) private var books: [Book]
    @AppStorage("shelf.displayMode") private var mode: ShelfDisplayMode = .spines

    @State private var scene = ShelfScene()
    @State private var viewSize: CGSize = .zero
    @State private var centerY: Float = 0
    @State private var scrollStart: Float?
    @State private var thicknesses: [UUID: Double] = [:]
    @State private var selectedID: UUID?
    @State private var held: Held?
    @State private var pickups = 0

    /// A book being dragged to a new place.
    struct Held: Equatable {
        var id: UUID
        var location: CGPoint
        /// Where it would land, as an index into the order without it.
        var insertion: Int
    }

    private struct SyncKey: Equatable {
        var order: [UUID]
        var thicknesses: [UUID: Double]
        var revisions: [Int]
        var mode: ShelfDisplayMode
        var selected: UUID?
        var held: Held?
        var size: CGSize
    }

    var body: some View {
        GeometryReader { proxy in
            RealityView { content in
                content.camera = .virtual
                content.add(scene.root)
            }
            .accessibilityHidden(true)
            .onAppear { resize(to: proxy.size) }
            .onChange(of: proxy.size) { _, size in resize(to: size) }
        }
        .background(Color(cgColor: ShelfTextures.wall.darkened(0.45).cgColor))
        .contentShape(Rectangle())
        .onTapGesture(coordinateSpace: .local) { location in tap(at: location) }
        .gesture(LongPressDragGesture { phase, location in longPress(phase, at: location) })
        .simultaneousGesture(scrollGesture)
        // VoiceOver reads invisible stand-ins laid over the books. They sit
        // in an overlay, not in `accessibilityChildren` on the container:
        // that modifier stops the RealityView from ever drawing.
        .overlay {
            accessibleBooks
                .allowsHitTesting(false)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Text("Bookshelf"))
                .accessibilityScrollAction { edge in
                    switch edge {
                    case .top: scroll(by: camera.halfHeight * 1.6, animated: true)
                    case .bottom: scroll(by: -camera.halfHeight * 1.6, animated: true)
                    default: break
                    }
                }
        }
        .overlay {
            if books.isEmpty {
                ContentUnavailableView {
                    Label("Your shelf is empty", systemImage: "books.vertical")
                } description: {
                    Text("Books you import will appear here.")
                }
                .foregroundStyle(.white)
            }
        }
        .overlay(alignment: .bottom) {
            if let book = selectedBook {
                ShelfBookCard(
                    book: book,
                    onRead: { open(book) },
                    onEditCover: onEditCover.map { edit in { edit(book) } },
                    onDelete: onDelete.map { delete in { select(nil); delete(book) } },
                    onClose: { select(nil) }
                )
                .padding()
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Show", selection: $mode) {
                        ForEach(ShelfDisplayMode.allCases) { mode in
                            Label(mode.displayName, systemImage: mode == .spines ? "books.vertical" : "rectangle.grid.2x2")
                                .tag(mode)
                        }
                    }
                } label: {
                    Label("Shelf display", systemImage: mode == .spines ? "books.vertical" : "rectangle.grid.2x2")
                }
            }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: pickups)
        .sensoryFeedback(.selection, trigger: held?.insertion)
        .onChange(of: syncKey) { old, new in
            // Resizes jump; everything else animates.
            refresh(animated: old.size == new.size)
        }
        .onChange(of: reduceMotion) { _, _ in refresh(animated: false) }
        .task(id: thicknessKey) { await loadThicknesses() }
    }

    // MARK: - State

    private var order: [UUID] { books.map(\.id) }

    private var displayOrder: [UUID] {
        guard let held else { return order }
        return order.moving(held.id, to: held.insertion)
    }

    private var selectedBook: Book? {
        guard let selectedID else { return nil }
        return books.first { $0.id == selectedID }
    }

    private var camera: ShelfCamera { ShelfCamera(viewSize: viewSize, centerY: centerY) }

    private var syncKey: SyncKey {
        SyncKey(
            order: displayOrder,
            thicknesses: thicknesses,
            revisions: books.map { covers.revision(for: $0.id) },
            mode: mode,
            selected: selectedID,
            held: held,
            size: viewSize
        )
    }

    private var thicknessKey: [Int] {
        books.map { covers.revision(for: $0.id) } + [books.count]
    }

    private func spec(_ id: UUID) -> ShelfBookSpec {
        ShelfBookSpec(id: id, thickness: thicknesses[id] ?? 0.12)
    }

    private func layout(for ids: [UUID]) -> ShelfLayout {
        ShelfLayout(books: ids.map(spec), mode: mode, shelfWidth: camera.shelfWidth)
    }

    private var scrollRange: ClosedRange<Float> {
        let layout = layout(for: order)
        return ShelfCamera.scrollRange(top: layout.contentTop + layout.metrics.boardThickness, bottom: layout.contentBottom, halfHeight: camera.halfHeight)
    }

    // MARK: - Scene

    private func resize(to size: CGSize) {
        guard size.width > 0, size.height > 0, size != viewSize else { return }
        let firstLayout = viewSize == .zero
        viewSize = size
        let range = scrollRange
        centerY = firstLayout ? range.upperBound : min(max(centerY, range.lowerBound), range.upperBound)
        scene.setCamera(camera, animated: false)
        refresh(animated: false)
    }

    private func refresh(animated: Bool) {
        guard viewSize.width > 0 else { return }
        scene.reduceMotion = reduceMotion
        let ids = displayOrder
        let layout = layout(for: ids)
        let states = ids.map { ShelfScene.BookState(spec: spec($0), revision: covers.revision(for: $0)) }
        let heldPoint = held.map { ShelfScene.Held(id: $0.id, point: camera.scenePoint(for: $0.location, atZ: 0.06)) }
        let byID = Dictionary(books.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        scene.sync(
            books: states,
            layout: layout,
            selected: selectedID,
            held: heldPoint,
            coverFor: { byID[$0] },
            animated: animated
        )
    }

    /// Spine widths come from each book's cover design.
    private func loadThicknesses() async {
        for book in books {
            let design = await covers.design(for: book)
            guard !Task.isCancelled else { return }
            if thicknesses[book.id] != design.thickness {
                thicknesses[book.id] = design.thickness
            }
        }
    }

    // MARK: - Gestures

    private func bookID(at location: CGPoint) -> UUID? {
        let point = camera.scenePoint(for: location, atZ: -0.01)
        return layout(for: order).book(atX: point.x, y: point.y)
    }

    private func tap(at location: CGPoint) {
        guard held == nil else { return }
        let hit = bookID(at: location)
        if let hit, hit == selectedID, let book = selectedBook {
            open(book)
        } else {
            select(hit)
        }
    }

    private func select(_ id: UUID?) {
        withAnimation(reduceMotion ? nil : .snappy) {
            selectedID = id
        }
    }

    private func longPress(_ phase: LongPressDragGesture.Phase, at location: CGPoint) {
        switch phase {
        case .began:
            guard let id = bookID(at: location), let index = order.firstIndex(of: id) else { return }
            select(nil)
            held = Held(id: id, location: location, insertion: index)
            pickups += 1
        case .changed:
            guard var current = held else { return }
            autoScroll(near: location)
            let others = layout(for: order.filter { $0 != current.id })
            let point = camera.scenePoint(for: location, atZ: -0.01)
            current.location = location
            current.insertion = others.insertionIndex(x: point.x, y: point.y)
            held = current
        case .ended:
            guard let current = held else { return }
            commitMove(current.id, to: current.insertion)
            held = nil
        case .cancelled:
            held = nil
        }
    }

    private var scrollGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard held == nil else { return }
                let start = scrollStart ?? centerY
                scrollStart = start
                setCenter(start + Float(value.translation.height) / ShelfCamera.pointsPerUnit, animated: false)
            }
            .onEnded { value in
                guard let start = scrollStart else { return }
                scrollStart = nil
                let flick = reduceMotion ? value.translation.height : value.predictedEndTranslation.height
                setCenter(start + Float(flick) / ShelfCamera.pointsPerUnit, animated: !reduceMotion)
            }
    }

    private func scroll(by delta: Float, animated: Bool) {
        setCenter(centerY + delta, animated: animated)
    }

    private func setCenter(_ y: Float, animated: Bool) {
        let range = scrollRange
        let clamped = min(max(y, range.lowerBound), range.upperBound)
        guard clamped != centerY else { return }
        centerY = clamped
        scene.setCamera(camera, animated: animated)
    }

    /// Scrolls while a held book is near the top or bottom edge.
    private func autoScroll(near location: CGPoint) {
        let edge: CGFloat = 70
        if location.y < edge {
            scroll(by: 0.012, animated: false)
        } else if location.y > viewSize.height - edge {
            scroll(by: -0.012, animated: false)
        }
    }

    // MARK: - Actions

    private func commitMove(_ id: UUID, to index: Int) {
        let newOrder = order.moving(id, to: index)
        guard newOrder != order else { return }
        let byID = Dictionary(books.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (position, bookID) in newOrder.enumerated() {
            if let book = byID[bookID], book.shelfOrder != position {
                book.shelfOrder = position
            }
        }
        try? modelContext.save()
    }

    private func move(_ id: UUID, by offset: Int) {
        guard let index = order.firstIndex(of: id) else { return }
        commitMove(id, to: index + offset)
    }

    private func open(_ book: Book) {
        guard !reduceMotion else {
            onOpen(book)
            return
        }
        scene.animateOpen(book.id, camera: camera)
        Task {
            try? await Task.sleep(for: .milliseconds(330))
            onOpen(book)
            selectedID = nil
            refresh(animated: false)
        }
    }

    // MARK: - Accessibility

    /// One element per book on screen, framed where the book is drawn.
    private var accessibleBooks: some View {
        let layout = layout(for: order)
        let camera = camera
        let frames: [AccessibleBook] = books.compactMap { book in
            guard let slot = layout.slot(for: book.id) else { return nil }
            let z: Float = -0.008
            let topLeft = camera.screenPoint(for: SIMD3(slot.x - slot.footprint / 2, slot.baseY + layout.metrics.bookHeight, z))
            let bottomRight = camera.screenPoint(for: SIMD3(slot.x + slot.footprint / 2, slot.baseY, z))
            let frame = CGRect(x: topLeft.x, y: topLeft.y, width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y)
            guard frame.intersects(CGRect(origin: .zero, size: viewSize)) else { return nil }
            return AccessibleBook(book: book, frame: frame)
        }
        return ZStack(alignment: .topLeading) {
            ForEach(frames) { item in
                let book = item.book
                let frame = item.frame
                Color.clear
                    .frame(width: max(frame.width, 1), height: max(frame.height, 1))
                    .position(x: frame.midX, y: frame.midY)
                    .accessibilityElement()
                    .accessibilityLabel(Text("\(book.title), by \(book.displayAuthors)"))
                    .accessibilityValue(book.progress > 0 ? Text("\(Int((book.progress * 100).rounded())) percent read") : Text(""))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint(Text("Shows the cover and options."))
                    .accessibilityAction { select(book.id) }
                    .accessibilityAction(named: Text("Open")) { onOpen(book) }
                    .accessibilityAction(named: Text("Move earlier")) { move(book.id, by: -1) }
                    .accessibilityAction(named: Text("Move later")) { move(book.id, by: 1) }
            }
        }
        .frame(width: viewSize.width, height: viewSize.height, alignment: .topLeading)
    }
}

private struct AccessibleBook: Identifiable {
    var book: Book
    var frame: CGRect
    var id: UUID { book.id }
}

/// The card shown under a book that's been pulled off the shelf.
struct ShelfBookCard: View {
    let book: Book
    var onRead: () -> Void
    var onEditCover: (() -> Void)?
    var onDelete: (() -> Void)?
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                BookCoverView(book: book, maxPixel: 180)
                    .frame(width: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(book.title)
                        .font(.headline)
                        .lineLimit(3)
                    Text(book.displayAuthors)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if book.progress > 0 {
                        ProgressView(value: book.progress) {
                            Text("\(Int((book.progress * 100).rounded()))% read")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 0)
                if let onDelete {
                    Menu {
                        Button("Delete…", systemImage: "trash", role: .destructive, action: onDelete)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel(Text("More"))
                }
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Put back"))
            }
            HStack {
                Button(action: onRead) {
                    Label("Read", systemImage: "book")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                if let onEditCover {
                    Button(action: onEditCover) {
                        Label("Edit cover", systemImage: "paintbrush")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .controlSize(.large)
        }
        .padding()
        .frame(maxWidth: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

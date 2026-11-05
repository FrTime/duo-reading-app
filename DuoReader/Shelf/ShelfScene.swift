import RealityKit
import SwiftUI
import UIKit

/// The RealityKit side of the shelf: the bookcase, one box per book, and the
/// camera. `ShelfView` owns the state and calls `sync` whenever it changes;
/// the scene only moves entities to match.
@MainActor
final class ShelfScene {
    /// What one book should look like right now.
    struct BookState: Equatable {
        var spec: ShelfBookSpec
        var revision: Int
    }

    /// A book held under the user's finger.
    struct Held: Equatable {
        var id: UUID
        var point: SIMD2<Float>
    }

    let root = Entity()
    private let camera = PerspectiveCamera()
    private let caseRoot = Entity()
    private var books: [UUID: ModelEntity] = [:]
    private var bookStates: [UUID: BookState] = [:]
    private var targets: [UUID: Transform] = [:]
    private var textureTasks: [UUID: Task<Void, Never>] = [:]
    /// The front texture size each book was last loaded at.
    private var frontSizes: [UUID: Int] = [:]
    private var caseKey: CaseKey?
    private var caseMaterials: (board: PhysicallyBasedMaterial, upright: PhysicallyBasedMaterial, back: PhysicallyBasedMaterial, wall: PhysicallyBasedMaterial)?

    private struct CaseKey: Equatable {
        var rows: Int
        var width: Float
        var divider: ClosedRange<Float>?
    }

    var reduceMotion = false
    /// Called whenever the scene changes, so a view that stops drawing a
    /// still scene (`ShelfRenderView`) knows to draw again.
    var onActivity: (() -> Void)?

    init() {
        camera.camera.fieldOfViewInDegrees = ShelfCamera.fieldOfViewDegrees
        camera.camera.near = 0.01
        camera.camera.far = 50
        root.addChild(camera)
        root.addChild(caseRoot)
        addLights()
    }

    /// A warm key light from the upper left that casts shadows (books onto
    /// the boards and the back of the case), and a soft cool fill from the
    /// right. Both ride on the camera, so every shelf is lit the same way as
    /// you scroll.
    private func addLights() {
        Self.addLights(to: camera, lookingAt: 1.2)
    }

    /// A warm key light that casts shadows, a cool fill and a soft front
    /// light, all riding on the camera so the lighting stays put as it moves.
    /// `distance` is how far ahead of the camera the subject sits.
    static func addLights(to camera: Entity, lookingAt distance: Float) {
        let target = SIMD3<Float>(0, 0, -distance)
        let key = DirectionalLight()
        key.light.color = UIColor(red: 1, green: 0.95, blue: 0.86, alpha: 1)
        key.light.intensity = 2600
        key.shadow = DirectionalLightComponent.Shadow(maximumDistance: max(3, distance * 2.5), depthBias: 1.5)
        camera.addChild(key)
        key.look(at: target, from: SIMD3(-0.7, 0.9, 0.2), relativeTo: camera)

        let fill = DirectionalLight()
        fill.light.color = UIColor(red: 0.85, green: 0.9, blue: 1, alpha: 1)
        fill.light.intensity = 900
        camera.addChild(fill)
        fill.look(at: target, from: SIMD3(0.8, -0.2, 0.4), relativeTo: camera)

        let front = DirectionalLight()
        front.light.color = .white
        front.light.intensity = 700
        camera.addChild(front)
        front.look(at: target, from: SIMD3(0, 0.1, 0.5), relativeTo: camera)
    }

    // MARK: - Camera

    func setCamera(_ state: ShelfCamera, animated: Bool) {
        onActivity?()
        let transform = Transform(translation: state.position)
        if animated, !reduceMotion {
            camera.move(to: transform, relativeTo: root, duration: 0.45, timingFunction: .easeOut)
        } else {
            camera.stopAllAnimations()
            camera.transform = transform
        }
    }

    // MARK: - Sync

    /// Moves every book to where the layout puts it.
    func sync(
        books states: [BookState],
        layout: ShelfLayout,
        selected: UUID?,
        held: Held?,
        visibleHalfWidth: Float? = nil,
        coverFor: (UUID) -> Book?,
        animated: Bool
    ) {
        onActivity?()
        Task { await buildCaseIfNeeded(layout) }

        let ids = Set(states.map(\.spec.id))
        for (id, entity) in books where !ids.contains(id) {
            entity.removeFromParent()
            books[id] = nil
            bookStates[id] = nil
            targets[id] = nil
            textureTasks[id]?.cancel()
            textureTasks[id] = nil
            frontSizes[id] = nil
        }

        let metrics = layout.metrics
        for state in states {
            let id = state.spec.id
            let entity = entity(for: state, metrics: metrics)
            let frontSize = id == selected ? Self.selectedFrontPixels : Self.frontPixels
            if bookStates[id]?.revision != state.revision || textureTasks[id] == nil || frontSizes[id] != frontSize,
               let book = coverFor(id) {
                loadTextures(for: book, into: entity, id: id, frontPixels: frontSize)
            }
            bookStates[id] = state

            let transform: Transform
            if let held, held.id == id {
                transform = Self.heldTransform(at: held.point, spec: state.spec, metrics: metrics, mode: layout.mode)
                entity.stopAllAnimations()
                entity.transform = transform
                targets[id] = transform
                continue
            } else if let slot = layout.slot(for: id) {
                transform = id == selected
                    ? Self.selectedTransform(slot: slot, spec: state.spec, layout: layout, visibleHalfWidth: visibleHalfWidth)
                    : Self.restingTransform(slot: slot, spec: state.spec, metrics: metrics, mode: layout.mode)
            } else {
                continue
            }
            if let current = targets[id], Self.same(current, transform) { continue }
            targets[id] = transform
            if animated, !reduceMotion {
                entity.move(to: transform, relativeTo: root, duration: 0.3, timingFunction: .easeInOut)
            } else {
                entity.stopAllAnimations()
                entity.transform = transform
            }
        }
    }

    /// Brings a book right up to the camera, as if opening it.
    func animateOpen(_ id: UUID, camera state: ShelfCamera) {
        onActivity?()
        guard let entity = books[id], !reduceMotion else { return }
        let target = Transform(
            scale: SIMD3(repeating: 1.6),
            rotation: simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)),
            translation: SIMD3(0, state.centerY, state.distance * 0.45)
        )
        entity.move(to: target, relativeTo: root, duration: 0.35, timingFunction: .easeIn)
        targets[id] = nil
    }

    // MARK: - Poses

    private static func same(_ a: Transform, _ b: Transform) -> Bool {
        a.translation == b.translation && a.rotation == b.rotation && a.scale == b.scale
    }

    /// Spine out, rotated so the spine (the box's -x face) points at the camera.
    static func restingTransform(slot: ShelfLayout.Slot, spec: ShelfBookSpec, metrics: ShelfMetrics, mode: ShelfDisplayMode) -> Transform {
        let y = slot.baseY + slot.height / 2
        switch mode {
        case .spines:
            // Spines line up along the front edge, whatever the book's width.
            return Transform(
                scale: .one,
                rotation: simd_quatf(angle: .pi / 2, axis: SIMD3(0, 1, 0)),
                translation: SIMD3(slot.x, y, -metrics.width(of: spec) / 2 - 0.006)
            )
        case .covers:
            return Transform(
                scale: .one,
                rotation: simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)),
                translation: SIMD3(slot.x, y, -metrics.depth(of: spec) / 2 - 0.01)
            )
        }
    }

    /// Pulled forward and turned to show the front cover, angled a little so
    /// the spine shows too.
    static let selectedScale: Float = 1.25
    static let selectedAngle: Float = 0.35

    /// How far toward the camera a pulled-out book comes.
    static let selectedZ: Float = 0.12

    static func selectedTransform(slot: ShelfLayout.Slot, spec: ShelfBookSpec, layout: ShelfLayout, visibleHalfWidth: Float?) -> Transform {
        // Turned to face the camera and enlarged, but kept inside the case
        // so a book at either end doesn't slide off the screen.
        let m = layout.metrics
        let halfExtent = selectedScale * (m.width(of: spec) * cos(selectedAngle) + m.depth(of: spec) * sin(selectedAngle)) / 2
        return Transform(
            scale: SIMD3(repeating: selectedScale),
            rotation: simd_quatf(angle: selectedAngle, axis: SIMD3(0, 1, 0)),
            translation: SIMD3(
                layout.clampedX(slot.x, halfExtent: halfExtent, visibleHalfWidth: visibleHalfWidth),
                slot.baseY + slot.height / 2 + 0.02,
                selectedZ
            )
        )
    }

    static func heldTransform(at point: SIMD2<Float>, spec: ShelfBookSpec, metrics: ShelfMetrics, mode: ShelfDisplayMode) -> Transform {
        let angle: Float = mode == .spines ? .pi / 2 - 0.25 : 0.2
        return Transform(
            scale: SIMD3(repeating: 1.1),
            rotation: simd_quatf(angle: angle, axis: SIMD3(0, 1, 0)),
            translation: SIMD3(point.x, point.y, 0.06)
        )
    }

    // MARK: - Entities

    private func entity(for state: BookState, metrics: ShelfMetrics) -> ModelEntity {
        let id = state.spec.id
        if let existing = books[id], bookStates[id]?.spec == state.spec {
            return existing
        }
        let mesh = MeshResource.generateBox(
            width: metrics.width(of: state.spec),
            height: metrics.height(of: state.spec),
            depth: metrics.depth(of: state.spec),
            splitFaces: true
        )
        if let existing = books[id] {
            // Same book, new size: swap the mesh, keep the materials.
            existing.model?.mesh = mesh
            return existing
        }
        let entity = ModelEntity(mesh: mesh, materials: Self.placeholderMaterials())
        entity.name = id.uuidString
        root.addChild(entity)
        books[id] = entity
        return entity
    }

    /// Material order for a split box: front, top, back, bottom, right, left.
    /// The front is the cover (+z), the left (-x) is the spine.
    static func materials(front: PhysicallyBasedMaterial, spine: PhysicallyBasedMaterial, back: PhysicallyBasedMaterial) -> [any RealityKit.Material] {
        let pages = ShelfTextures.solid(.cream, roughness: 0.9)
        return [front, pages, back, pages, pages, spine]
    }

    private static func placeholderMaterials() -> [any RealityKit.Material] {
        let cover = ShelfTextures.solid(RGBAColor(red: 0.4, green: 0.37, blue: 0.33))
        return materials(front: cover, spine: cover, back: cover)
    }

    /// Texture sizes, longest side in pixels. A face-out cover is about
    /// 115 pt wide on screen, a spine a few tens of points; backs are only
    /// seen when a book is turned in the hand. The pulled-out book gets a
    /// sharper front. This keeps a few hundred books to roughly 100 MB.
    static let frontPixels = 384
    static let selectedFrontPixels = 900
    static let spinePixels = 512
    static let backPixels = 192

    private func loadTextures(for book: Book, into entity: ModelEntity, id: UUID, frontPixels: Int) {
        textureTasks[id]?.cancel()
        frontSizes[id] = frontPixels
        let covers = CoverLibrary.shared
        textureTasks[id] = Task { [weak self, weak entity] in
            let front = await covers.image(.front, for: book, maxPixels: frontPixels)
            let spine = await covers.image(.spine, for: book, maxPixels: Self.spinePixels)
            let back = await covers.image(.back, for: book, maxPixels: Self.backPixels)
            guard !Task.isCancelled else { return }
            let frontMaterial = await ShelfTextures.material(from: front.cgImage, fallback: .cream)
            let spineMaterial = await ShelfTextures.material(from: spine.cgImage, fallback: .cream)
            let backMaterial = await ShelfTextures.material(from: back.cgImage, fallback: .cream)
            let materials = Self.materials(front: frontMaterial, spine: spineMaterial, back: backMaterial)
            guard !Task.isCancelled, let entity else { return }
            entity.model?.materials = materials
            self?.onActivity?()
        }
    }

    // MARK: - Bookcase

    private func buildCaseIfNeeded(_ layout: ShelfLayout) async {
        let key = CaseKey(rows: layout.caseRowCount, width: layout.shelfWidth, divider: layout.divider)
        guard key != caseKey else { return }
        caseKey = key

        if caseMaterials == nil {
            let board = await ShelfTextures.material(from: ShelfTextures.boardImage(), fallback: ShelfTextures.wood, roughness: 0.45)
            let back = await ShelfTextures.material(from: ShelfTextures.backPanelImage(), fallback: ShelfTextures.wall, roughness: 0.7)
            let wall = ShelfTextures.solid(ShelfTextures.wall.darkened(0.45), roughness: 0.9)
            let upright = await ShelfTextures.material(from: ShelfTextures.uprightImage(), fallback: ShelfTextures.wood, roughness: 0.45)
            caseMaterials = (board, upright, back, wall)
        }
        guard let materials = caseMaterials, caseKey == key else { return }

        for child in Array(caseRoot.children) {
            child.removeFromParent()
        }
        let m = layout.metrics
        let width = layout.shelfWidth
        let depth = m.shelfDepth

        // A wall far behind, so the edges of the scene never show.
        let wall = ModelEntity(mesh: .generatePlane(width: 40, height: 40), materials: [materials.wall])
        wall.position = SIMD3(0, (layout.contentTop + layout.caseBottom) / 2, -depth - 0.02)
        caseRoot.addChild(wall)

        for row in 0..<layout.caseRowCount {
            let base = ShelfLayout.baseY(row: row, metrics: m)
            let board = ModelEntity(
                mesh: .generateBox(width: width, height: m.boardThickness, depth: depth),
                materials: [materials.board]
            )
            board.position = SIMD3(0, base - m.boardThickness / 2, -depth / 2)
            caseRoot.addChild(board)

            let back = ModelEntity(mesh: .generatePlane(width: width, height: m.rowHeight), materials: [materials.back])
            back.position = SIMD3(0, base + (m.rowHeight - m.boardThickness) / 2, -depth)
            caseRoot.addChild(back)
        }

        // An upright over the fold, splitting every shelf into two bays.
        if let divider = layout.divider {
            let height = layout.contentTop - layout.caseBottom
            let upright = ModelEntity(
                mesh: .generateBox(width: divider.upperBound - divider.lowerBound, height: height, depth: depth),
                materials: [materials.upright]
            )
            upright.position = SIMD3((divider.lowerBound + divider.upperBound) / 2, (layout.contentTop + layout.caseBottom) / 2, -depth / 2)
            caseRoot.addChild(upright)
        }

        // The case's top and sides.
        let height = layout.contentTop - layout.caseBottom + m.boardThickness
        let midY = (layout.contentTop + layout.caseBottom) / 2
        for side: Float in [-1, 1] {
            let panel = ModelEntity(
                mesh: .generateBox(width: m.boardThickness, height: height, depth: depth),
                materials: [materials.upright]
            )
            panel.position = SIMD3(side * (width / 2 + m.boardThickness / 2), midY, -depth / 2)
            caseRoot.addChild(panel)
        }
        let top = ModelEntity(
            mesh: .generateBox(width: width + 2 * m.boardThickness, height: m.boardThickness, depth: depth),
            materials: [materials.board]
        )
        top.position = SIMD3(0, layout.contentTop + m.boardThickness / 2, -depth / 2)
        caseRoot.addChild(top)
        onActivity?()
    }
}

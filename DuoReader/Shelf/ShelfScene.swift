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
    private var caseKey: CaseKey?
    private var caseMaterials: (board: PhysicallyBasedMaterial, back: PhysicallyBasedMaterial, wall: PhysicallyBasedMaterial)?

    private struct CaseKey: Equatable {
        var rows: Int
        var width: Float
    }

    var reduceMotion = false

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
        let key = DirectionalLight()
        key.light.color = UIColor(red: 1, green: 0.95, blue: 0.86, alpha: 1)
        key.light.intensity = 2600
        key.shadow = DirectionalLightComponent.Shadow(maximumDistance: 3, depthBias: 1.5)
        camera.addChild(key)
        key.look(at: SIMD3(0, 0, -1.2), from: SIMD3(-0.7, 0.9, 0.2), relativeTo: camera)

        let fill = DirectionalLight()
        fill.light.color = UIColor(red: 0.85, green: 0.9, blue: 1, alpha: 1)
        fill.light.intensity = 900
        camera.addChild(fill)
        fill.look(at: SIMD3(0, 0, -1.2), from: SIMD3(0.8, -0.2, 0.4), relativeTo: camera)

        let front = DirectionalLight()
        front.light.color = .white
        front.light.intensity = 700
        camera.addChild(front)
        front.look(at: SIMD3(0, 0, -1.2), from: SIMD3(0, 0.1, 0.5), relativeTo: camera)
    }

    // MARK: - Camera

    func setCamera(_ state: ShelfCamera, animated: Bool) {
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
        coverFor: (UUID) -> Book?,
        animated: Bool
    ) {
        Task { await buildCaseIfNeeded(layout) }

        let ids = Set(states.map(\.spec.id))
        for (id, entity) in books where !ids.contains(id) {
            entity.removeFromParent()
            books[id] = nil
            bookStates[id] = nil
            targets[id] = nil
            textureTasks[id]?.cancel()
            textureTasks[id] = nil
        }

        let metrics = layout.metrics
        for state in states {
            let id = state.spec.id
            let entity = entity(for: state, metrics: metrics)
            if bookStates[id]?.revision != state.revision || textureTasks[id] == nil, let book = coverFor(id) {
                loadTextures(for: book, into: entity, id: id)
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
                    ? Self.selectedTransform(slot: slot, spec: state.spec, metrics: metrics)
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
        let y = slot.baseY + metrics.bookHeight / 2
        switch mode {
        case .spines:
            return Transform(
                scale: .one,
                rotation: simd_quatf(angle: .pi / 2, axis: SIMD3(0, 1, 0)),
                translation: SIMD3(slot.x, y, -metrics.bookWidth / 2 - 0.006)
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
    static func selectedTransform(slot: ShelfLayout.Slot, spec: ShelfBookSpec, metrics: ShelfMetrics) -> Transform {
        Transform(
            scale: SIMD3(repeating: 1.25),
            rotation: simd_quatf(angle: 0.35, axis: SIMD3(0, 1, 0)),
            translation: SIMD3(slot.x, slot.baseY + metrics.bookHeight / 2 + 0.02, 0.12)
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
        if let existing = books[id], bookStates[id]?.spec.thickness == state.spec.thickness {
            return existing
        }
        let mesh = MeshResource.generateBox(
            width: metrics.bookWidth,
            height: metrics.bookHeight,
            depth: metrics.depth(of: state.spec),
            splitFaces: true
        )
        if let existing = books[id] {
            // Same book, new thickness: swap the mesh, keep the materials.
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

    private func loadTextures(for book: Book, into entity: ModelEntity, id: UUID) {
        textureTasks[id]?.cancel()
        let covers = CoverLibrary.shared
        textureTasks[id] = Task { [weak entity] in
            // Small textures: a spine is tens of points wide on screen, a
            // face-out cover about 100 pt. 512 px keeps a big library light.
            let front = await covers.image(.front, for: book, maxPixels: 512)
            let spine = await covers.image(.spine, for: book, maxPixels: 512)
            let back = await covers.image(.back, for: book, maxPixels: 512)
            guard !Task.isCancelled else { return }
            let frontMaterial = await ShelfTextures.material(from: front.cgImage, fallback: .cream)
            let spineMaterial = await ShelfTextures.material(from: spine.cgImage, fallback: .cream)
            let backMaterial = await ShelfTextures.material(from: back.cgImage, fallback: .cream)
            let materials = Self.materials(front: frontMaterial, spine: spineMaterial, back: backMaterial)
            guard !Task.isCancelled, let entity else { return }
            entity.model?.materials = materials
        }
    }

    // MARK: - Bookcase

    private func buildCaseIfNeeded(_ layout: ShelfLayout) async {
        let key = CaseKey(rows: layout.rowCount, width: layout.shelfWidth)
        guard key != caseKey else { return }
        caseKey = key

        if caseMaterials == nil {
            let board = await ShelfTextures.material(from: ShelfTextures.boardImage(), fallback: ShelfTextures.wood, roughness: 0.45)
            let back = await ShelfTextures.material(from: ShelfTextures.backPanelImage(), fallback: ShelfTextures.wall, roughness: 0.7)
            let wall = ShelfTextures.solid(ShelfTextures.wall.darkened(0.45), roughness: 0.9)
            caseMaterials = (board, back, wall)
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
        wall.position = SIMD3(0, (layout.contentTop + layout.contentBottom) / 2, -depth - 0.02)
        caseRoot.addChild(wall)

        for row in 0..<layout.rowCount {
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

        // The case's top and sides.
        let height = layout.contentHeight + m.boardThickness
        let midY = (layout.contentTop + layout.contentBottom) / 2
        for side: Float in [-1, 1] {
            let panel = ModelEntity(
                mesh: .generateBox(width: m.boardThickness, height: height, depth: depth),
                materials: [materials.board]
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
    }
}

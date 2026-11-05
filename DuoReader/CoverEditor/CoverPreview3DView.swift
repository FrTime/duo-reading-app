import RealityKit
import SwiftUI

/// The book as it will stand on the shelf: drag to turn it over.
struct CoverPreview3DView: View {
    let rendered: RenderedCover?
    /// Changes whenever `rendered` does, so textures reload.
    let revision: Int
    let thickness: Double
    /// The book's size on the shelf (`CoverDesign.sizeScale`).
    var heightScale: Double = 1

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scene = BookPreviewScene()
    /// Turned to show the spine, the side most people design last.
    @State private var yaw: Float = 0.55
    @State private var pitch: Float = 0.12
    @State private var dragStart: (yaw: Float, pitch: Float)?

    var body: some View {
        RealityView { content in
            content.camera = .virtual
            content.add(scene.root)
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let start = dragStart ?? (yaw, pitch)
                    dragStart = start
                    yaw = start.yaw + Float(value.translation.width) / 120
                    pitch = min(max(start.pitch + Float(value.translation.height) / 200, -0.9), 0.9)
                    scene.setRotation(yaw: yaw, pitch: pitch, animated: false)
                }
                .onEnded { _ in dragStart = nil }
        )
        .task(id: TextureKey(revision: revision, thickness: thickness, heightScale: heightScale)) {
            guard let rendered else { return }
            await scene.show(rendered, thickness: thickness, heightScale: heightScale)
            scene.setRotation(yaw: yaw, pitch: pitch, animated: false)
        }
        .accessibilityElement()
        .accessibilityLabel(Text("3D preview of the book"))
        .accessibilityHint(Text("Swipe up or down to turn the book."))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: yaw += .pi / 4
            case .decrement: yaw -= .pi / 4
            @unknown default: break
            }
            scene.setRotation(yaw: yaw, pitch: pitch, animated: !reduceMotion)
        }
    }

    private struct TextureKey: Equatable {
        var revision: Int
        var thickness: Double
        var heightScale: Double
    }
}

/// One book on its own in front of a camera.
@MainActor
final class BookPreviewScene {
    let root = Entity()
    private let pivot = Entity()
    private var book: ModelEntity?
    private let metrics = ShelfMetrics()

    init() {
        let camera = PerspectiveCamera()
        camera.camera.fieldOfViewInDegrees = 30
        camera.position = SIMD3(0, 0, 0.72)
        root.addChild(camera)
        ShelfScene.addLights(to: camera, lookingAt: 0.72)
        root.addChild(pivot)
        // A soft, light backdrop, and a floor the book casts its shadow on,
        // so it reads as an object standing on a table.
        let backdrop = ModelEntity(
            mesh: .generatePlane(width: 20, height: 20),
            materials: [UnlitMaterial(color: UIColor(white: 0.82, alpha: 1))]
        )
        backdrop.position = SIMD3(0, 0, -1.5)
        root.addChild(backdrop)
        var floorMaterial = PhysicallyBasedMaterial()
        floorMaterial.baseColor = .init(tint: UIColor(white: 0.86, alpha: 1))
        floorMaterial.roughness = 0.9
        let floor = ModelEntity(mesh: .generatePlane(width: 4, depth: 4), materials: [floorMaterial])
        floor.position = SIMD3(0, -metrics.maxBookHeight / 2 - 0.004, 0)
        root.addChild(floor)
    }

    func show(_ rendered: RenderedCover, thickness: Double, heightScale: Double) async {
        let front = await ShelfTextures.material(from: rendered.front.cgImage, fallback: .cream)
        let spine = await ShelfTextures.material(from: rendered.spine.cgImage, fallback: .cream)
        let back = await ShelfTextures.material(from: rendered.back.cgImage, fallback: .cream)
        let spec = ShelfBookSpec(id: UUID(), thickness: thickness, heightScale: heightScale)
        let mesh = MeshResource.generateBox(
            width: metrics.width(of: spec),
            height: metrics.height(of: spec),
            depth: metrics.depth(of: spec),
            splitFaces: true
        )
        let materials = ShelfScene.materials(front: front, spine: spine, back: back)
        if let book {
            book.model?.mesh = mesh
            book.model?.materials = materials
        } else {
            let entity = ModelEntity(mesh: mesh, materials: materials)
            pivot.addChild(entity)
            book = entity
        }
        // Stand it on the floor whatever its size.
        book?.position.y = (metrics.height(of: spec) - metrics.maxBookHeight) / 2
    }

    func setRotation(yaw: Float, pitch: Float, animated: Bool) {
        let rotation = simd_quatf(angle: pitch, axis: SIMD3(1, 0, 0)) * simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0))
        let transform = Transform(scale: .one, rotation: rotation, translation: .zero)
        if animated {
            pivot.move(to: transform, relativeTo: root, duration: 0.3, timingFunction: .easeInOut)
        } else {
            pivot.transform = transform
        }
    }
}

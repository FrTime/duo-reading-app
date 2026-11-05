import CoreGraphics
import Foundation
import simd

/// The shelf's camera: straight on, looking down -z, panned up and down
/// between shelves. Converts between screen points and scene positions so
/// touches can be matched to books without RealityKit hit testing.
public struct ShelfCamera: Equatable, Sendable {
    /// Vertical field of view.
    public static let fieldOfViewDegrees: Float = 40
    /// Screen points per scene unit, so a book is about 173 pt tall on any
    /// screen (spine titles stay legible) and wider screens (the open Duo)
    /// show more books per shelf.
    public static let pointsPerUnit: Float = 720

    public var viewSize: CGSize
    /// Height of the point the camera looks at.
    public var centerY: Float

    public init(viewSize: CGSize, centerY: Float = 0) {
        self.viewSize = viewSize
        self.centerY = centerY
    }

    private var halfFOVTangent: Float { tan(Self.fieldOfViewDegrees * .pi / 360) }

    /// Half the visible height at z = 0 (the front edge of the shelves).
    public var halfHeight: Float { Float(max(viewSize.height, 1)) / 2 / Self.pointsPerUnit }
    public var halfWidth: Float { Float(max(viewSize.width, 1)) / 2 / Self.pointsPerUnit }

    /// How far in front of z = 0 the camera sits for that scale.
    public var distance: Float { halfHeight / halfFOVTangent }

    public var position: SIMD3<Float> { SIMD3(0, centerY, distance) }

    /// Shelf width that fits the screen with a little wall either side.
    public var shelfWidth: Float { halfWidth * 2 * 0.94 }

    /// The scene position under a screen point, on the plane at depth `z`.
    public func scenePoint(for point: CGPoint, atZ z: Float = 0) -> SIMD2<Float> {
        let scale = (distance - z) * halfFOVTangent / (Float(max(viewSize.height, 1)) / 2)
        let dx = Float(point.x - viewSize.width / 2) * scale
        let dy = Float(point.y - viewSize.height / 2) * scale
        return SIMD2(dx, centerY - dy)
    }

    /// The screen point a scene position projects to.
    public func screenPoint(for position: SIMD3<Float>) -> CGPoint {
        let depth = max(distance - position.z, 0.0001)
        let scale = (Float(max(viewSize.height, 1)) / 2) / (depth * halfFOVTangent)
        return CGPoint(
            x: viewSize.width / 2 + CGFloat(position.x * scale),
            y: viewSize.height / 2 - CGFloat((position.y - centerY) * scale)
        )
    }

    /// The range `centerY` may scroll over to show a layout of this height.
    /// When everything fits, the top shelf stays at the top of the screen.
    public static func scrollRange(top: Float, bottom: Float, halfHeight: Float, padding: Float = 0.03) -> ClosedRange<Float> {
        let highest = top + padding - halfHeight
        let lowest = bottom - padding + halfHeight
        return lowest < highest ? lowest...highest : highest...highest
    }
}

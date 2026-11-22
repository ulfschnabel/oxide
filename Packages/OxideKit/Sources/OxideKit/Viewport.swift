import CoreGraphics

/// Zooming into the remote picture. The picture is drawn at `scale` times
/// its fitted size, with the picture point `center` (0…1 on each axis) at the
/// middle of the view where the edges allow. Kept in picture terms, so it
/// still looks at the same place after a rotation or a new resolution.
public struct Viewport: Equatable, Sendable {
    public static let maxScale: CGFloat = 4

    public private(set) var scale: CGFloat = 1
    public private(set) var center = CGPoint(x: 0.5, y: 0.5)

    public init() {}

    public var isZoomed: Bool { scale > 1.001 }

    /// Where the picture is drawn, given where it fits unzoomed.
    public func rect(fitted: CGRect, in bounds: CGRect) -> CGRect {
        let size = CGSize(width: fitted.width * scale, height: fitted.height * scale)
        return CGRect(x: Self.origin(size.width, center.x, bounds.minX, bounds.width),
                      y: Self.origin(size.height, center.y, bounds.minY, bounds.height),
                      width: size.width, height: size.height)
    }

    /// Along one axis: centred if the picture fits, otherwise at `center`
    /// but never leaving a gap at an edge.
    private static func origin(_ length: CGFloat, _ center: CGFloat, _ start: CGFloat, _ span: CGFloat) -> CGFloat {
        let mid = start + span / 2
        guard length > span else { return mid - length / 2 }
        return min(max(mid - center * length, start + span - length), start)
    }

    /// Zooms by `factor`, keeping the picture point under `anchor` (a view
    /// point, the pinch's centre) where it is.
    public mutating func zoom(by factor: CGFloat, at anchor: CGPoint, fitted: CGRect, in bounds: CGRect) {
        guard factor > 0, fitted.width > 0, fitted.height > 0 else { return }
        let r = rect(fitted: fitted, in: bounds)
        let u = CGPoint(x: (anchor.x - r.minX) / r.width, y: (anchor.y - r.minY) / r.height)
        scale = min(max(scale * factor, 1), Self.maxScale)
        let size = CGSize(width: fitted.width * scale, height: fitted.height * scale)
        let origin = CGPoint(x: anchor.x - u.x * size.width, y: anchor.y - u.y * size.height)
        place(origin: origin, size: size, in: bounds)
    }

    /// Moves the picture with a finger.
    public mutating func pan(by translation: CGPoint, fitted: CGRect, in bounds: CGRect) {
        guard fitted.width > 0, fitted.height > 0 else { return }
        let r = rect(fitted: fitted, in: bounds)
        place(origin: CGPoint(x: r.minX + translation.x, y: r.minY + translation.y), size: r.size, in: bounds)
    }

    /// Moves the picture just enough that `point` (a view point, such as the
    /// cursor) is at least `margin` inside the view.
    public mutating func reveal(_ point: CGPoint, margin: CGFloat, fitted: CGRect, in bounds: CGRect) {
        let inner = bounds.insetBy(dx: margin, dy: margin)
        func shift(_ p: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
            p > hi ? hi - p : p < lo ? lo - p : 0
        }
        let dx = shift(point.x, inner.minX, inner.maxX)
        let dy = shift(point.y, inner.minY, inner.maxY)
        guard dx != 0 || dy != 0 else { return }
        pan(by: CGPoint(x: dx, y: dy), fitted: fitted, in: bounds)
    }

    public mutating func reset() {
        self = Viewport()
    }

    /// Stores the picture point at the view's middle, after the edges had their say.
    private mutating func place(origin: CGPoint, size: CGSize, in bounds: CGRect) {
        center = CGPoint(x: (bounds.midX - origin.x) / size.width, y: (bounds.midY - origin.y) / size.height)
        let clamped = rect(fitted: CGRect(origin: .zero, size: CGSize(width: size.width / scale, height: size.height / scale)),
                           in: bounds)
        center = CGPoint(x: (bounds.midX - clamped.minX) / size.width, y: (bounds.midY - clamped.minY) / size.height)
    }
}

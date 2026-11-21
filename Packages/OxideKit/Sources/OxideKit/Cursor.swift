import CoreGraphics
import Foundation

/// A host display in the host's virtual-desktop pixels (the origin can be
/// negative on multi-monitor hosts).
public struct DisplayRect: Sendable, Equatable {
    public var x, y, width, height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(_ info: Hbb_DisplayInfo) {
        self.init(x: Int(info.x), y: Int(info.y), width: Int(info.width), height: Int(info.height))
    }
}

/// The cursor the client keeps in trackpad mode, in host pixels. The host
/// only takes absolute positions from mobile clients' point of view.
public struct VirtualCursor: Sendable, Equatable {
    public var display: DisplayRect {
        didSet { clamp() }
    }
    public private(set) var x: Double
    public private(set) var y: Double

    public init(display: DisplayRect) {
        self.display = display
        x = Double(display.x) + Double(display.width) / 2
        y = Double(display.y) + Double(display.height) / 2
    }

    public mutating func move(by dx: Double, dy: Double) {
        x += dx
        y += dy
        clamp()
    }

    public mutating func move(to point: (Int32, Int32)) {
        x = Double(point.0)
        y = Double(point.1)
        clamp()
    }

    /// The right and bottom edges are inside: Windows snaps to them.
    private mutating func clamp() {
        x = min(max(x, Double(display.x)), Double(display.x + display.width))
        y = min(max(y, Double(display.y)), Double(display.y + display.height))
    }

    public var hostPoint: (Int32, Int32) {
        (Int32(x.rounded()), Int32(y.rounded()))
    }
}

/// From points on the phone to pixels on the host, through the picture's
/// aspect-fit rectangle in the view.
public enum ViewMapping {
    public static func contentRect(videoSize: CGSize, in bounds: CGRect) -> CGRect {
        guard videoSize.width > 0, videoSize.height > 0 else { return bounds }
        let scale = min(bounds.width / videoSize.width, bounds.height / videoSize.height)
        let size = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    public static func hostPoint(_ point: CGPoint, content: CGRect, display: DisplayRect) -> (Int32, Int32) {
        guard content.width > 0, content.height > 0 else { return (Int32(display.x), Int32(display.y)) }
        let nx = min(max((point.x - content.minX) / content.width, 0), 1)
        let ny = min(max((point.y - content.minY) / content.height, 0), 1)
        return (Int32((Double(display.x) + nx * Double(display.width)).rounded()),
                Int32((Double(display.y) + ny * Double(display.height)).rounded()))
    }

    public static func viewPoint(_ host: (Int32, Int32), content: CGRect, display: DisplayRect) -> CGPoint {
        guard display.width > 0, display.height > 0 else { return content.origin }
        return CGPoint(x: content.minX + CGFloat(Double(host.0 - Int32(display.x)) / Double(display.width)) * content.width,
                       y: content.minY + CGFloat(Double(host.1 - Int32(display.y)) / Double(display.height)) * content.height)
    }

    /// Host pixels per view point, so a finger moves the cursor as far as it
    /// moves on the picture.
    public static func hostPixelsPerPoint(content: CGRect, display: DisplayRect) -> Double {
        content.width > 0 ? Double(display.width) / content.width : 1
    }
}

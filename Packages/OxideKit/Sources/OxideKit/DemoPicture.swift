import CoreGraphics
import CoreMedia
import CoreText
import CoreVideo
import Foundation
import VideoToolbox

public enum DemoPictureError: Error, Equatable {
    case pixelBuffer(CVReturn)
    case encoder(OSStatus)
}

/// The demo computer's screen: its desktop drawn with Core Graphics and
/// encoded to H.264 by VideoToolbox, as Annex B with the parameter sets in
/// key frames (the way a RustDesk host sends it). One frame at a time; the
/// encoder is remade when the resolution changes.
public final class DemoPicture {
    static let strokeColor = (255, 204, 0)
    private static let background = (24, 38, 64)

    private var encoder: VTCompressionSession?
    private var size: (Int, Int) = (0, 0)
    private var frameCount: Int64 = 0

    public init() {}

    deinit {
        if let encoder { VTCompressionSessionInvalidate(encoder) }
    }

    /// The desktop as the next frame; a key frame when asked for, and always
    /// after a resolution change. Nil if the encoder dropped the frame.
    public func frame(of desktop: DemoDesktop, forceKey: Bool) throws -> (data: Data, key: Bool)? {
        let image = try Self.render(desktop)
        var key = forceKey
        if size != (desktop.width, desktop.height) || encoder == nil {
            try makeEncoder(width: desktop.width, height: desktop.height)
            key = true
        }
        guard let encoder else { return nil }
        let options = key ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
        let pts = CMTime(value: frameCount, timescale: 30)
        frameCount += 1
        nonisolated(unsafe) var output: CMSampleBuffer?
        let status = VTCompressionSessionEncodeFrame(
            encoder, imageBuffer: image, presentationTimeStamp: pts, duration: CMTime(value: 1, timescale: 30),
            frameProperties: options, infoFlagsOut: nil
        ) { status, _, sample in
            if status == noErr { output = sample }
        }
        guard status == noErr else { throw DemoPictureError.encoder(status) }
        VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid)
        guard let output else { return nil }
        return Self.annexB(output)
    }

    private func makeEncoder(width: Int, height: Int) throws {
        if let encoder { VTCompressionSessionInvalidate(encoder) }
        encoder = nil
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard status == noErr, let session else { throw DemoPictureError.encoder(status) }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: kVTProfileLevel_H264_Main_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        // Key frames only when asked for (start, refresh, resolution change).
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 0 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,
                             value: max(2_000_000, width * height * 2) as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(session)
        encoder = session
        size = (width, height)
    }

    /// An encoded sample as Annex B: SPS and PPS first in a key frame, then
    /// each NAL unit behind a 4-byte start code.
    static func annexB(_ sample: CMSampleBuffer) -> (data: Data, key: Bool) {
        let startCode = Data([0, 0, 0, 1])
        var out = Data()
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        let key = !notSync
        if key, let format = CMSampleBufferGetFormatDescription(sample) {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            for i in 0..<count {
                var pointer: UnsafePointer<UInt8>?
                var length = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: i, parameterSetPointerOut: &pointer, parameterSetSizeOut: &length,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let pointer {
                    out.append(startCode)
                    out.append(pointer, count: length)
                }
            }
        }
        if let block = CMSampleBufferGetDataBuffer(sample) {
            let total = CMBlockBufferGetDataLength(block)
            var bytes = Data(count: total)
            bytes.withUnsafeMutableBytes {
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: total, destination: $0.baseAddress!)
            }
            // AVCC: 4-byte big-endian lengths.
            var i = 0
            while i + 4 <= bytes.count {
                let n = bytes[i..<i + 4].reduce(0) { $0 << 8 | Int($1) }
                guard n > 0, i + 4 + n <= bytes.count else { break }
                out.append(startCode)
                out.append(bytes[i + 4..<i + 4 + n])
                i += 4 + n
            }
        }
        return (out, key)
    }

    // MARK: Drawing

    /// The desktop as a BGRA image at its resolution.
    static func render(_ desktop: DemoDesktop) throws -> CVPixelBuffer {
        let w = desktop.width, h = desktop.height
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        let status = CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attributes, &buffer)
        guard status == kCVReturnSuccess, let buffer else { throw DemoPictureError.pixelBuffer(status) }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { throw DemoPictureError.pixelBuffer(kCVReturnError) }
        // Top-left origin, like the host's pixels.
        context.translateBy(x: 0, y: CGFloat(h))
        context.scaleBy(x: 1, y: -1)
        draw(desktop, in: context, width: CGFloat(w), height: CGFloat(h))
        return buffer
    }

    private static func color(_ c: (Int, Int, Int), alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat(c.0) / 255, green: CGFloat(c.1) / 255, blue: CGFloat(c.2) / 255, alpha: alpha)
    }

    private static func draw(_ desktop: DemoDesktop, in context: CGContext, width: CGFloat, height: CGFloat) {
        context.setFillColor(color(background))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Everything is sized to the screen, so it reads the same at any
        // resolution (and at a phone's scale).
        let unit = min(width, height) / 24

        // A grid, to see the picture move when zoomed.
        context.setStrokeColor(color((255, 255, 255), alpha: 0.06))
        context.setLineWidth(1)
        for x in stride(from: 0, to: width, by: unit * 3) {
            context.move(to: CGPoint(x: x + 0.5, y: 0)); context.addLine(to: CGPoint(x: x + 0.5, y: height))
        }
        for y in stride(from: 0, to: height, by: unit * 3) {
            context.move(to: CGPoint(x: 0, y: y + 0.5)); context.addLine(to: CGPoint(x: width, y: y + 0.5))
        }
        context.strokePath()

        // The card with what to try, as tall as its text.
        let pad = unit * 0.6
        let cardWidth = min(width - 2 * unit, unit * 26)
        let inner = cardWidth - 2 * pad
        let blocks: [(String, CGFloat, Bool, CGFloat)] = [
            ("Oxide demo computer", unit * 1.1, true, 1),
            ("This computer is part of the app, to try Oxide out. To control a real computer, "
                + "install RustDesk on it and add it to your list.", unit * 0.75, false, 0.8),
            ("Click or drag to draw  ·  Right-click to mark  ·  Type to write  ·  Esc to clear\n"
                + "Screen: \(desktop.width) × \(desktop.height)\(scrollNote(desktop))"
                + (desktop.lastKey.map { "  ·  Last key: \($0)" } ?? ""), unit * 0.75, false, 1),
        ]
        let gap = unit * 0.3
        let heights = blocks.map { measure($0.0, size: $0.1, bold: $0.2, width: inner) }
        let card = CGRect(x: unit, y: unit, width: cardWidth,
                          height: heights.reduce(0, +) + gap * CGFloat(blocks.count - 1) + 2 * pad)
        context.setFillColor(color((255, 255, 255), alpha: 0.1))
        context.addPath(CGPath(roundedRect: card, cornerWidth: unit / 2, cornerHeight: unit / 2, transform: nil))
        context.fillPath()
        var y = card.minY + pad
        for block in blocks {
            y = text(block.0, at: CGPoint(x: card.minX + pad, y: y), size: block.1, bold: block.2,
                     width: inner, in: context, alpha: block.3) + gap
        }

        // What was typed.
        if !desktop.text.isEmpty {
            _ = text(desktop.text, at: CGPoint(x: unit, y: card.maxY + unit), size: unit,
                     width: width - 2 * unit, in: context)
        }

        // Marks: rings where the other buttons were pressed.
        for mark in desktop.marks {
            let (px, py) = desktop.pixel(mark.point)
            let ring = mark.button == .right ? (255, 90, 90) : mark.button == .middle ? (90, 170, 255) : (190, 120, 255)
            context.setStrokeColor(color(ring))
            context.setLineWidth(unit / 6)
            context.strokeEllipse(in: CGRect(x: CGFloat(px) - unit / 2, y: CGFloat(py) - unit / 2,
                                             width: unit, height: unit))
        }

        // The drawing.
        context.setStrokeColor(color(strokeColor))
        context.setFillColor(color(strokeColor))
        context.setLineWidth(max(4, unit / 4))
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for stroke in desktop.strokes {
            let points = stroke.points.map { p in
                let (px, py) = desktop.pixel(p)
                return CGPoint(x: CGFloat(px) + 0.5, y: CGFloat(py) + 0.5)
            }
            if points.count == 1 {
                let r = max(4, unit / 4)
                context.fillEllipse(in: CGRect(x: points[0].x - r, y: points[0].y - r, width: 2 * r, height: 2 * r))
            } else {
                context.addLines(between: points)
                context.strokePath()
            }
        }
    }

    private static func scrollNote(_ desktop: DemoDesktop) -> String {
        guard desktop.scrolled != 0 else { return "" }
        let notches = Double(desktop.scrolled) / 120
        return "  ·  Scrolled: " + String(format: "%+.1f", notches)
    }

    private static func setter(_ string: String, size: CGFloat, bold: Bool, alpha: CGFloat) -> CTFramesetter {
        let font = CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: color((255, 255, 255), alpha: alpha),
        ]
        return CTFramesetterCreateWithAttributedString(
            CFAttributedStringCreate(nil, string as CFString, attributes as CFDictionary)!)
    }

    private static func measure(_ string: String, size: CGFloat, bold: Bool, width: CGFloat) -> CGFloat {
        ceil(CTFramesetterSuggestFrameSizeWithConstraints(
            setter(string, size: size, bold: bold, alpha: 1), CFRange(location: 0, length: 0), nil,
            CGSize(width: width, height: .greatestFiniteMagnitude), nil).height)
    }

    /// Wrapped text with its top-left at `origin` in the flipped context;
    /// returns where the text ends.
    private static func text(_ string: String, at origin: CGPoint, size: CGFloat, bold: Bool = false,
                             width: CGFloat, in context: CGContext, alpha: CGFloat = 1) -> CGFloat {
        let setter = setter(string, size: size, bold: bold, alpha: alpha)
        let height = measure(string, size: size, bold: bold, width: width)
        // Core Text draws bottom-up: flip just this block back.
        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y + height)
        context.scaleBy(x: 1, y: -1)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0),
                                             CGPath(rect: CGRect(x: 0, y: 0, width: width, height: height),
                                                    transform: nil), nil)
        CTFrameDraw(frame, context)
        context.restoreGState()
        return origin.y + height
    }
}

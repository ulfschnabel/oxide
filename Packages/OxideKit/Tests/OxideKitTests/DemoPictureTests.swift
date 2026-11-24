import CoreVideo
import Foundation
import Testing

@testable import OxideKit

/// The demo computer's picture: the desktop drawn, then encoded to H.264 as
/// a RustDesk host sends it (Annex B, parameter sets in key frames).
struct DemoPictureTests {
    private func drawn() -> DemoDesktop {
        var desktop = DemoDesktop()
        // A thick scribble across (1000, 700).
        desktop.handle(Input.move(900, 700).mouseEvent)
        desktop.handle(Input.button(.left, down: true).mouseEvent)
        for x in stride(from: 900, through: 1100, by: 5) { desktop.handle(Input.move(Int32(x), 700).mouseEvent) }
        desktop.handle(Input.button(.left, down: false).mouseEvent)
        return desktop
    }

    /// Red, green, blue at a pixel of a BGRA image.
    private func color(_ image: CVPixelBuffer, _ x: Int, _ y: Int) -> (Int, Int, Int) {
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        let row = CVPixelBufferGetBytesPerRow(image)
        let p = CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to: UInt8.self) + y * row + x * 4
        return (Int(p[2]), Int(p[1]), Int(p[0]))
    }

    private func near(_ a: (Int, Int, Int), _ b: (Int, Int, Int), within tolerance: Int) -> Bool {
        abs(a.0 - b.0) <= tolerance && abs(a.1 - b.1) <= tolerance && abs(a.2 - b.2) <= tolerance
    }

    @Test func drawsTheDesktopAtItsResolution() throws {
        let image = try DemoPicture.render(drawn())
        #expect(CVPixelBufferGetWidth(image) == 1920)
        #expect(CVPixelBufferGetHeight(image) == 1080)
        #expect(near(color(image, 1000, 700), DemoPicture.strokeColor, within: 8))
        #expect(!near(color(image, 1000, 1000), DemoPicture.strokeColor, within: 60))
    }

    @Test func keyFrameCarriesParameterSets() throws {
        let picture = DemoPicture()
        let frame = try #require(try picture.frame(of: drawn(), forceKey: true))
        #expect(frame.key)
        let types = AnnexB.nalUnits(in: frame.data).map { Int($0[0] & 0x1F) }
        #expect(types.contains(7) && types.contains(8) && types.contains(5))
    }

    @Test func framesDecodeToTheDesktop() throws {
        let picture = DemoPicture()
        var desktop = drawn()
        var builder = VideoSampleBuilder(codec: .h264)
        var samples = [try picture.frame(of: desktop, forceKey: true)!]
        desktop.handle(Input.typed("x").keyEvent)
        samples.append(try picture.frame(of: desktop, forceKey: false)!)
        #expect(!samples[1].key)
        let buffers = try samples.enumerated().compactMap { i, f in
            try builder.sampleBuffer(for: f.data, isKey: f.key, pts: Int64(i * 33))
        }
        let images = try decode(buffers)
        #expect(images.count == 2)
        #expect(CVPixelBufferGetWidth(images[0]) == 1920)
    }

    @Test func aNewResolutionStartsWithAKeyFrame() throws {
        let picture = DemoPicture()
        var desktop = drawn()
        _ = try picture.frame(of: desktop, forceKey: true)
        desktop.resize(width: 1024, height: 768)
        let frame = try #require(try picture.frame(of: desktop, forceKey: false))
        #expect(frame.key)
        var builder = VideoSampleBuilder(codec: .h264)
        let sample = try #require(try builder.sampleBuffer(for: frame.data, isKey: true, pts: 0))
        let images = try decode([sample])
        #expect(CVPixelBufferGetWidth(images[0]) == 1024)
        #expect(CVPixelBufferGetHeight(images[0]) == 768)
    }
}

import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Writes a sample picture to $DEMO_PNG, to look at by eye (skipped otherwise).
@Test(.enabled(if: ProcessInfo.processInfo.environment["DEMO_PNG"] != nil))
func demoPictureSample() throws {
    var desktop = DemoDesktop()
    desktop.handle(Input.move(700, 600).mouseEvent)
    desktop.handle(Input.button(.left, down: true).mouseEvent)
    for i in 0...60 {
        let t = Double(i) / 60 * .pi * 2
        desktop.handle(Input.move(Int32(900 + 200 * cos(t)), Int32(650 + 120 * sin(2 * t))).mouseEvent)
    }
    desktop.handle(Input.button(.left, down: false).mouseEvent)
    for m in Input.click(.right, at: (1500, 500)) { desktop.handle(m.mouseEvent) }
    for c in "Hello from Oxide!" { desktop.handle(Input.typed(String(c)).keyEvent) }
    desktop.handle(Input.typed("c", modifiers: [.control]).keyEvent)
    desktop.handle(Input.scroll(dx: 0, dy: 240).mouseEvent)
    let image = CIImage(cvPixelBuffer: try DemoPicture.render(desktop))
    let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DEMO_PNG"]!)
    try CIContext().writePNGRepresentation(of: image, to: url, format: .RGBA8,
                                           colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
}

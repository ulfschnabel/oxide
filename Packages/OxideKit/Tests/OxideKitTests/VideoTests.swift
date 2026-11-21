import CoreMedia
import Foundation
import Testing
import VideoToolbox

@testable import OxideKit

/// Ten 1920×1080 H.264 frames of a test pattern, laid out like a RustDesk
/// host sends them: a keyframe with SPS/PPS in-band, then P-frames
/// (tools/make_fixtures.py).
func fixtureFrames() throws -> [(data: Data, key: Bool)] {
    let dir = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
    let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasPrefix("h264-") }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    return try files.map { (try Data(contentsOf: $0), $0.lastPathComponent.contains("-key")) }
}

struct AnnexBTests {
    @Test func splitsOnThreeAndFourByteStartCodes() {
        let stream = Data([0, 0, 0, 1, 0x67, 1, 2, 0, 0, 1, 0x68, 3, 0, 0, 0, 1, 0x65, 4, 5])
        #expect(AnnexB.nalUnits(in: stream) == [Data([0x67, 1, 2]), Data([0x68, 3]), Data([0x65, 4, 5])])
    }

    @Test func avccPrefixesEachUnitWithItsLength() {
        let avcc = AnnexB.avcc([Data([0x65, 1, 2]), Data([0x41])])
        #expect(avcc == Data([0, 0, 0, 3, 0x65, 1, 2, 0, 0, 0, 1, 0x41]))
    }

    @Test func hostKeyframeCarriesParameterSetsInBand() throws {
        let key = try fixtureFrames()[0]
        #expect(key.key)
        let types = AnnexB.nalUnits(in: key.data).map { $0[$0.startIndex] & 0x1F }
        #expect(types.contains(7))  // SPS
        #expect(types.contains(8))  // PPS
        #expect(types.contains(5))  // IDR slice
    }
}

struct SampleBuilderTests {
    @Test func waitsForAKeyframeWithParameterSets() throws {
        let frames = try fixtureFrames()
        var builder = VideoSampleBuilder(codec: .h264)
        #expect(try builder.sampleBuffer(for: frames[1].data, isKey: false, pts: 33) == nil)
        let sample = try #require(try builder.sampleBuffer(for: frames[0].data, isKey: true, pts: 0))
        let format = try #require(CMSampleBufferGetFormatDescription(sample))
        let size = CMVideoFormatDescriptionGetDimensions(format)
        #expect(size.width == 1920 && size.height == 1080)
        #expect(sample.isKeyframe)
    }

    @Test func everyRecordedFrameDecodes() throws {
        var builder = VideoSampleBuilder(codec: .h264)
        let samples = try fixtureFrames().enumerated().map { i, frame in
            try #require(try builder.sampleBuffer(for: frame.data, isKey: frame.key, pts: Int64(i) * 33))
        }
        let images = try decode(samples)
        #expect(images.count == samples.count)
        #expect(images.allSatisfy { CVPixelBufferGetWidth($0) == 1920 && CVPixelBufferGetHeight($0) == 1080 })
    }
}

/// Collects decoder output, which arrives on VideoToolbox's threads.
final class ImageBox: @unchecked Sendable {
    private let lock = NSLock()
    private var images: [CVPixelBuffer] = []

    func append(_ image: CVPixelBuffer) { lock.withLock { images.append(image) } }
    var all: [CVPixelBuffer] { lock.withLock { images } }
}

/// Decodes with VideoToolbox, as the display layer will.
func decode(_ samples: [CMSampleBuffer]) throws -> [CVPixelBuffer] {
    let format = try #require(CMSampleBufferGetFormatDescription(samples[0]))
    var session: VTDecompressionSession?
    #expect(VTDecompressionSessionCreate(
        allocator: nil, formatDescription: format, decoderSpecification: nil,
        imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &session) == noErr)
    let decoder = try #require(session)
    defer { VTDecompressionSessionInvalidate(decoder) }
    let images = ImageBox()
    for sample in samples {
        let status = VTDecompressionSessionDecodeFrame(
            decoder, sampleBuffer: sample, flags: [], infoFlagsOut: nil
        ) { status, _, image, _, _ in
            if status == noErr, let image { images.append(image) }
        }
        #expect(status == noErr)
    }
    VTDecompressionSessionWaitForAsynchronousFrames(decoder)
    return images.all
}

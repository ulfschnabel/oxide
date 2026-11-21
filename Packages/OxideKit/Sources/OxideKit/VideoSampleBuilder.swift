import CoreMedia
import Foundation

public enum VideoCodec: String, Sendable, Equatable {
    case h264, h265
}

public enum VideoError: Error, Equatable {
    case formatDescription(OSStatus)
    case sampleBuffer(OSStatus)
}

/// Turns the host's Annex-B frames into compressed sample buffers that
/// VideoToolbox (or AVSampleBufferDisplayLayer) decodes. The format
/// description comes from the parameter sets the host sends in-band with
/// each keyframe, and is rebuilt whenever they change (new resolution).
public struct VideoSampleBuilder {
    public let codec: VideoCodec
    private var parameterSets: [Data] = []
    private var format: CMVideoFormatDescription?

    public init(codec: VideoCodec) {
        self.codec = codec
    }

    /// A sample buffer for one frame, or nil while no keyframe has given the
    /// parameter sets yet (frames before that cannot be decoded).
    public mutating func sampleBuffer(for frame: Data, isKey: Bool, pts: Int64) throws -> CMSampleBuffer? {
        let units = AnnexB.nalUnits(in: frame)
        let sets = units.filter(isParameterSet)
        if !sets.isEmpty, sets != parameterSets {
            format = try makeFormat(sets)
            parameterSets = sets
        }
        guard let format else { return nil }
        let slices = units.filter { !isParameterSet($0) }
        guard !slices.isEmpty else { return nil }
        return try makeSample(AnnexB.avcc(slices), format: format, isKey: isKey, pts: pts)
    }

    private func nalType(_ unit: Data) -> UInt8 {
        let first = unit[unit.startIndex]
        return codec == .h264 ? first & 0x1F : (first >> 1) & 0x3F
    }

    private func isParameterSet(_ unit: Data) -> Bool {
        guard !unit.isEmpty else { return false }
        let type = nalType(unit)
        // H.264: SPS 7, PPS 8. H.265: VPS 32, SPS 33, PPS 34.
        return codec == .h264 ? (type == 7 || type == 8) : (32...34).contains(type)
    }

    private func makeFormat(_ sets: [Data]) throws -> CMVideoFormatDescription {
        // Order the host may vary; the API wants SPS before PPS (VPS first for HEVC).
        let ordered = sets.sorted { nalType($0) < nalType($1) }
        let buffers = ordered.map { [UInt8]($0) }
        var format: CMFormatDescription?
        let status: OSStatus = withUnsafePointers(buffers) { pointers, sizes in
            switch codec {
            case .h264:
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: nil, parameterSetCount: buffers.count, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &format)
            case .h265:
                CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: nil, parameterSetCount: buffers.count, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil,
                    formatDescriptionOut: &format)
            }
        }
        guard status == noErr, let format else { throw VideoError.formatDescription(status) }
        return format
    }

    private func makeSample(_ data: Data, format: CMVideoFormatDescription, isKey: Bool, pts: Int64) throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: data.count, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: data.count, flags: 0, blockBufferOut: &block)
        guard status == noErr, let block else { throw VideoError.sampleBuffer(status) }
        status = data.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count)
        }
        guard status == noErr else { throw VideoError.sampleBuffer(status) }

        var timing = CMSampleTimingInfo(
            duration: .invalid, presentationTimeStamp: CMTime(value: pts, timescale: 1000), decodeTimeStamp: .invalid)
        var size = data.count
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
            sampleSizeArray: &size, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw VideoError.sampleBuffer(status) }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            // Show frames as soon as they are decoded; a remote desktop has no clock to keep.
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            if !isKey {
                CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
        }
        return sample
    }
}

/// Calls body with C pointers to each buffer and their sizes.
private func withUnsafePointers<R>(
    _ buffers: [[UInt8]], _ body: (UnsafePointer<UnsafePointer<UInt8>>, UnsafePointer<Int>) -> R
) -> R {
    let copies = buffers.map { buffer -> UnsafeMutablePointer<UInt8> in
        let p = UnsafeMutablePointer<UInt8>.allocate(capacity: buffer.count)
        p.initialize(from: buffer, count: buffer.count)
        return p
    }
    defer { copies.forEach { $0.deallocate() } }
    let pointers = copies.map { UnsafePointer($0) }
    let sizes = buffers.map(\.count)
    return pointers.withUnsafeBufferPointer { p in
        sizes.withUnsafeBufferPointer { s in body(p.baseAddress!, s.baseAddress!) }
    }
}

extension CMSampleBuffer {
    public var isKeyframe: Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(self, createIfNecessary: false),
              CFArrayGetCount(attachments) > 0 else { return true }
        let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFDictionary.self)
        return !CFDictionaryContainsKey(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque())
    }
}

// Appended to the current production CaptureController.swift by the runner.
// No duplicate production implementation or device permission request.
@main struct CaptureEncodingChecks {
    static func videoSample(at time: CMTime) throws -> CMSampleBuffer {
        var pixel: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, 320, 180, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel) == kCVReturnSuccess, let pixel else { throw CaptureFailure(message: "pixel buffer create") }
        CVPixelBufferLockBaseAddress(pixel, [])
        memset(CVPixelBufferGetBaseAddress(pixel), 64, CVPixelBufferGetDataSize(pixel))
        CVPixelBufferUnlockBaseAddress(pixel, [])
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel, formatDescriptionOut: &format) == noErr, let format else { throw CaptureFailure(message: "video format") }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { throw CaptureFailure(message: "video sample") }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true)! as NSArray
        (attachments[0] as! NSMutableDictionary)[SCStreamFrameInfo.status.rawValue] = SCFrameStatus.complete.rawValue
        return sample
    }
    static func audioSample(at time: CMTime) throws -> CMSampleBuffer {
        let frames = 4800
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: frames * 8, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: frames * 8, flags: 0, blockBufferOut: &block) == kCMBlockBufferNoErr, let block else { throw CaptureFailure(message: "audio block") }
        _ = CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: frames * 8)
        var description = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr, let format else { throw CaptureFailure(message: "audio format") }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000), presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sampleSize = 8
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sample) == noErr, let sample else { throw CaptureFailure(message: "audio sample") }
        return sample
    }
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("capture-encoding-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for codec in [AVVideoCodecType.h264, .hevc] {
            let file = directory.appendingPathComponent(codec.rawValue + ".mov")
            let sink = try ScreenCaptureSink(outputURL: file, width: 320, height: 180, codec: codec, frameRate: 30, capturesAudio: true, onPreview: { _ in }, onFailure: { print("CAPTURE FAILURE " + $0) })
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                sink.queue.async {
                    do {
                        sink.consume(try videoSample(at: .zero), of: .screen)
                        sink.consume(try audioSample(at: .zero), of: .audio)
                        continuation.resume()
                    } catch { continuation.resume(throwing: error) }
                }
            }
            try await Task.sleep(nanoseconds: 300_000_000)
            try await sink.finishRecording()
            let asset = AVURLAsset(url: file)
            let duration = try await asset.load(.duration)
            let tracks = try await asset.load(.tracks)
            guard CMTimeGetSeconds(duration) >= 0.25, tracks.contains(where: { $0.mediaType == .video }), tracks.contains(where: { $0.mediaType == .audio }) else { throw CaptureFailure(message: "missing video/audio/duration") }
            print("PASS \(codec.rawValue) MOV + AAC and static-frame duration \(CMTimeGetSeconds(duration))")
        }
        let empty = try ScreenCaptureSink(outputURL: directory.appendingPathComponent("empty.mov"), width: 320, height: 180, codec: .h264, frameRate: 30, capturesAudio: false, onPreview: { _ in }, onFailure: { _ in })
        do { try await empty.finishRecording(); preconditionFailure("empty recording should fail") }
        catch { print("PASS no-frame recording rejected: \(error.localizedDescription)") }
        print("3 real encoding test groups passed; no screen/camera permission requested")
    }
}

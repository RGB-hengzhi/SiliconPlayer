// Appended by run_module_boundaries.py to the actual CaptureController.swift.
// CaptureSampleFactory is extracted from the repository's synthetic helpers.
private struct CaptureCheckFailure: Error, CustomStringConvertible {
    let description: String
}

// The samples are constructed and attachments finalized before this handoff.
// The test never touches them again outside the capture serial queue.
private struct CaptureSampleBatch: @unchecked Sendable {
    let samples: [(CMSampleBuffer, SCStreamOutputType)]
}

extension CaptureController {
    // These hooks reach only filesystem publication/cleanup. Source discovery,
    // stream creation, camera sessions, and permission methods are never called.
    fileprivate func publishFixture(target: URL, staging: URL) throws {
        targetURL = target
        stagingURL = staging
        try publishRecording()
    }
    fileprivate func cleanFailedFixture() async { await clearFailedCapture("synthetic fixture failure") }
}

@main struct CaptureBoundaryChecks {
    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw CaptureCheckFailure(description: message) }
    }
    private static func feed(_ sink: ScreenCaptureSink, _ samples: [(CMSampleBuffer, SCStreamOutputType)]) async throws {
        let batch = CaptureSampleBatch(samples: samples)
        await withCheckedContinuation { continuation in
            sink.queue.async {
                for (sample, type) in batch.samples { sink.consume(sample, of: type) }
                continuation.resume()
            }
        }
    }
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("capture-boundaries-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var failures = 0
        let cases: [(String, () async throws -> Void)] = [
            ("video-only nonzero source timestamps preserve elapsed gaps and decode real frames", {
                let file = directory.appendingPathComponent("video-only.mov")
                let sink = try ScreenCaptureSink(outputURL: file, width: 320, height: 180, codec: .h264,
                    frameRate: 30, capturesAudio: false, onPreview: { _ in }, onFailure: { print("CALLBACK " + $0) })
                try await feed(sink, [(CaptureSampleFactory.videoSample(at: CMTime(seconds: 1200, preferredTimescale: 600)), .screen),
                    (CaptureSampleFactory.videoSample(at: CMTime(seconds: 1202, preferredTimescale: 600)), .screen)])
                try await sink.finishRecording()
                let asset = AVURLAsset(url: file)
                let duration = CMTimeGetSeconds(try await asset.load(.duration))
                let tracks = try await asset.load(.tracks)
                try expect(duration > 2 && duration < 2.1 && tracks.count == 1 && tracks[0].mediaType == .video, "video-only duration/tracks incorrect")
                let reader = try AVAssetReader(asset: asset)
                let output = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                reader.add(output)
                try expect(reader.startReading(), "could not decode encoded MOV")
                var decoded = 0
                while let sample = output.copyNextSampleBuffer() {
                    try expect(sample.imageBuffer != nil, "decoded video has no image")
                    decoded += 1
                }
                try expect(reader.status == .completed && decoded >= 2, "encoded MOV has fewer than two decodable frames")
            }),
            ("incomplete ScreenCaptureKit frames cannot produce a successful recording", {
                let sink = try ScreenCaptureSink(outputURL: directory.appendingPathComponent("idle.mov"), width: 320, height: 180,
                    codec: .h264, frameRate: 30, capturesAudio: false, onPreview: { _ in }, onFailure: { _ in })
                let sample = try CaptureSampleFactory.videoSample(at: .zero)
                let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true)! as NSArray
                (attachments[0] as! NSMutableDictionary)[SCStreamFrameInfo.status.rawValue] = SCFrameStatus.idle.rawValue
                try await feed(sink, [(sample, .screen)])
                var failed = false
                do { try await sink.finishRecording() } catch { failed = true }
                try expect(failed, "incomplete frame was accepted as a recording")
            }),
            ("audio before the first video frame is discarded without a negative recording timeline", {
                let file = directory.appendingPathComponent("audio-order.mov")
                let sink = try ScreenCaptureSink(outputURL: file, width: 320, height: 180, codec: .h264,
                    frameRate: 30, capturesAudio: true, onPreview: { _ in }, onFailure: { print("CALLBACK " + $0) })
                try await feed(sink, [(CaptureSampleFactory.audioSample(at: CMTime(seconds: 4.9, preferredTimescale: 48000)), .audio),
                    (CaptureSampleFactory.videoSample(at: CMTime(seconds: 5, preferredTimescale: 600)), .screen),
                    (CaptureSampleFactory.audioSample(at: CMTime(seconds: 5.05, preferredTimescale: 48000)), .audio),
                    (CaptureSampleFactory.videoSample(at: CMTime(seconds: 6, preferredTimescale: 600)), .screen)])
                try await sink.finishRecording()
                let asset = AVURLAsset(url: file)
                let tracks = try await asset.load(.tracks)
                guard let audio = tracks.first(where: { $0.mediaType == .audio }) else { throw CaptureCheckFailure(description: "valid audio was lost") }
                let audioRange = try await audio.load(.timeRange)
                try expect(CMTimeGetSeconds(audioRange.start) >= 0 && CMTimeGetSeconds(audioRange.duration) > 0, "audio timeline is negative or empty")
                let duration = CMTimeGetSeconds(try await asset.load(.duration))
                try expect(duration < 1.2, "early audio extended output duration")
            }),
            ("canceled writer rejects finalization and ignores later frames promptly", {
                let sink = try ScreenCaptureSink(outputURL: directory.appendingPathComponent("cancelled.mov"), width: 320, height: 180,
                    codec: .h264, frameRate: 30, capturesAudio: false, onPreview: { _ in }, onFailure: { print("CALLBACK " + $0) })
                await sink.cancelRecording()
                try await feed(sink, [(CaptureSampleFactory.videoSample(at: .zero), .screen)])
                let started = Date()
                var failed = false
                do { try await sink.finishRecording() } catch { failed = true }
                try expect(failed && Date().timeIntervalSince(started) < 2, "cancelled writer resumed or hung")
            }),
            ("existing capture destination and invalid output directory retain original data", {
                let previous = Data("existing destination must remain".utf8)
                for file in [directory.appendingPathComponent("existing.mov"), directory.appendingPathComponent("blocked").appendingPathComponent("output.mov")] {
                    let blocker = file.lastPathComponent == "existing.mov" ? file : file.deletingLastPathComponent()
                    try previous.write(to: blocker)
                    var failed = false
                    do {
                        let sink = try ScreenCaptureSink(outputURL: file, width: 320, height: 180, codec: .h264,
                            frameRate: 30, capturesAudio: false, onPreview: { _ in }, onFailure: { _ in })
                        try await feed(sink, [(CaptureSampleFactory.videoSample(at: .zero), .screen)])
                        try await sink.finishRecording()
                    } catch { failed = true }
                    try expect(failed && (try Data(contentsOf: blocker)) == previous, "capture destination was damaged")
                }
            }),
            ("controller publishes completed MOV atomically and cleans failed empty staging files", {
                let target = directory.appendingPathComponent("published.mov")
                let staging = directory.appendingPathComponent(".staging.mov")
                let previous = Data("existing saved recording".utf8)
                try previous.write(to: target)
                let sink = try ScreenCaptureSink(outputURL: staging, width: 320, height: 180, codec: .h264,
                    frameRate: 30, capturesAudio: false, onPreview: { _ in }, onFailure: { _ in })
                try await feed(sink, [(CaptureSampleFactory.videoSample(at: .zero), .screen)])
                try await sink.finishRecording()
                let controller = CaptureController()
                try controller.publishFixture(target: target, staging: staging)
                try expect(controller.lastRecordingURL == target && !FileManager.default.fileExists(atPath: staging.path), "publication metadata/staging incorrect")
                let tracks = try await AVURLAsset(url: target).load(.tracks)
                try expect(tracks.contains(where: { $0.mediaType == .video }), "published file has no video track")
                let emptyTarget = directory.appendingPathComponent("keep-existing.mov")
                let emptyStaging = directory.appendingPathComponent(".empty-staging.mov")
                try previous.write(to: emptyTarget)
                try Data().write(to: emptyStaging)
                let failedController = CaptureController()
                var failed = false
                do { try failedController.publishFixture(target: emptyTarget, staging: emptyStaging) } catch { failed = true }
                try expect(failed && (try Data(contentsOf: emptyTarget)) == previous, "empty staging replaced original recording")
                await failedController.cleanFailedFixture()
                try expect(!FileManager.default.fileExists(atPath: emptyStaging.path) && !failedController.isBusy && !failedController.isRecording && failedController.lastRecordingURL == nil, "failed staging or capture state leaked")
            })
        ]
        for (name, body) in cases {
            do { try await body(); print("PASS " + name) }
            catch { failures += 1; print("FAIL " + name + ": " + String(describing: error)) }
        }
        print("\(cases.count - failures)/\(cases.count) capture boundary groups passed; synthetic samples, real MOV encoding/decoding, no privacy APIs called")
        if failures > 0 { exit(1) }
    }
}

#!/usr/bin/env swift

import AppKit
import AVFoundation
import AudioToolbox
import CoreGraphics
import CoreMedia
import CoreText
import CoreVideo
import Foundation

// Run from the project root:
//   swift scripts/make_fixtures.swift
// An optional first argument overrides the output directory.

struct FixtureError: Error, CustomStringConvertible {
    let description: String
}

let fixtureWidth = 640
let fixtureHeight = 360
let fixtureFPS: Int32 = 30
let audioSampleRate: Int32 = 48_000
let audioSamplesPerFrame = Int(audioSampleRate / fixtureFPS)

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw FixtureError(description: message) }
}

func checkStatus(_ status: OSStatus, _ operation: String) throws {
    try require(status == noErr, "\(operation) failed: OSStatus \(status)")
}

func drawText(_ text: String, at point: CGPoint, size: CGFloat, color: CGColor, context: CGContext) {
    let font = CTFontCreateWithName("PingFangSC-Semibold" as CFString, size, nil)
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    context.textMatrix = .identity
    context.textPosition = point
    CTLineDraw(line, context)
}

func makeFrame(pool: CVPixelBufferPool, frame: Int, duration: Int, label: String) throws -> CVPixelBuffer {
    var optionalBuffer: CVPixelBuffer?
    let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &optionalBuffer)
    try require(status == kCVReturnSuccess && optionalBuffer != nil, "Cannot allocate video pixel buffer: \(status)")
    let buffer = optionalBuffer!
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let address = CVPixelBufferGetBaseAddress(buffer),
          let context = CGContext(
            data: address,
            width: fixtureWidth,
            height: fixtureHeight,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
          ) else {
        throw FixtureError(description: "Cannot create drawing context")
    }

    let width = CGFloat(fixtureWidth)
    let height = CGFloat(fixtureHeight)
    context.setFillColor(CGColor(red: 0.04, green: 0.07, blue: 0.12, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let colors: [CGColor] = [
        CGColor(red: 0.9, green: 0.18, blue: 0.2, alpha: 1),
        CGColor(red: 0.12, green: 0.75, blue: 0.36, alpha: 1),
        CGColor(red: 0.14, green: 0.4, blue: 0.94, alpha: 1),
        CGColor(red: 0.95, green: 0.74, blue: 0.12, alpha: 1)
    ]
    for (index, color) in colors.enumerated() {
        context.setFillColor(color)
        context.fill(CGRect(x: CGFloat(index) * 160, y: 210, width: 160, height: 80))
    }

    let time = Double(frame) / Double(fixtureFPS)
    let progress = CGFloat(time / Double(duration))
    let movingX = 28 + CGFloat((sin(time * 1.6) + 1) / 2) * 530
    let movingY = 120 + CGFloat(sin(time * 2.4)) * 26
    context.setFillColor(CGColor(red: 0.35, green: 0.87, blue: 1, alpha: 1))
    context.fillEllipse(in: CGRect(x: movingX, y: movingY, width: 48, height: 48))
    context.setStrokeColor(CGColor(gray: 1, alpha: 1))
    context.setLineWidth(3)
    context.stroke(CGRect(x: 270, y: 105, width: 100, height: 75))
    context.setFillColor(CGColor(red: 0.25, green: 0.7, blue: 0.96, alpha: 1))
    context.fill(CGRect(x: 24, y: 84, width: (width - 48) * progress, height: 5))

    let white = CGColor(gray: 1, alpha: 1)
    drawText("SiliconPlayer · 中文离线测试", at: CGPoint(x: 24, y: 316), size: 25, color: white, context: context)
    drawText("\(label)  640 × 360  30 fps", at: CGPoint(x: 24, y: 185), size: 20, color: white, context: context)
    drawText(String(format: "时间 %.2f 秒  ·  帧 %03d", time, frame), at: CGPoint(x: 24, y: 55), size: 21, color: white, context: context)
    drawText("底部留给中文字幕 · 440 Hz 测试音", at: CGPoint(x: 24, y: 25), size: 16,
             color: CGColor(gray: 0.75, alpha: 1), context: context)
    return buffer
}

func makeAudioFormat() throws -> CMAudioFormatDescription {
    var description = AudioStreamBasicDescription(
        mSampleRate: Double(audioSampleRate),
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 4,
        mFramesPerPacket: 1,
        mBytesPerFrame: 4,
        mChannelsPerFrame: 1,
        mBitsPerChannel: 32,
        mReserved: 0
    )
    var format: CMAudioFormatDescription?
    try checkStatus(CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        asbd: &description,
        layoutSize: 0,
        layout: nil,
        magicCookieSize: 0,
        magicCookie: nil,
        extensions: nil,
        formatDescriptionOut: &format
    ), "Create PCM audio format")
    return format!
}

func makeAudioFrame(frame: Int, duration: Int, format: CMAudioFormatDescription) throws -> CMSampleBuffer {
    let firstSample = frame * audioSamplesPerFrame
    let samples = (0..<audioSamplesPerFrame).map { index -> Float in
        let time = Double(firstSample + index) / Double(audioSampleRate)
        let fade = max(0, min(1, min(time / 0.03, (Double(duration) - time) / 0.03)))
        return Float(sin(2 * Double.pi * 440 * time) * 0.07 * fade)
    }
    let byteCount = samples.count * MemoryLayout<Float>.size
    var block: CMBlockBuffer?
    try checkStatus(CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault,
        memoryBlock: nil,
        blockLength: byteCount,
        blockAllocator: kCFAllocatorDefault,
        customBlockSource: nil,
        offsetToData: 0,
        dataLength: byteCount,
        flags: 0,
        blockBufferOut: &block
    ), "Allocate PCM block")
    try samples.withUnsafeBytes { bytes in
        try checkStatus(CMBlockBufferReplaceDataBytes(
            with: bytes.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: byteCount
        ), "Copy PCM samples")
    }
    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: audioSampleRate),
        presentationTimeStamp: CMTime(value: Int64(firstSample), timescale: audioSampleRate),
        decodeTimeStamp: .invalid
    )
    var sampleSize = MemoryLayout<Float>.size
    var sampleBuffer: CMSampleBuffer?
    try checkStatus(CMSampleBufferCreateReady(
        allocator: kCFAllocatorDefault,
        dataBuffer: block,
        formatDescription: format,
        sampleCount: samples.count,
        sampleTimingEntryCount: 1,
        sampleTimingArray: &timing,
        sampleSizeEntryCount: 1,
        sampleSizeArray: &sampleSize,
        sampleBufferOut: &sampleBuffer
    ), "Create PCM sample buffer")
    return sampleBuffer!
}

func waitUntilReady(_ input: AVAssetWriterInput, writer: AVAssetWriter) throws {
    let deadline = Date().addingTimeInterval(20)
    while !input.isReadyForMoreMediaData {
        try require(writer.status == .writing, writer.error?.localizedDescription ?? "Writer stopped")
        try require(Date() < deadline, "Encoder did not accept data within 20 seconds")
        Thread.sleep(forTimeInterval: 0.001)
    }
}

func writeFixture(to url: URL, codec: AVVideoCodecType, duration: Int, label: String) throws {
    if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: codec,
        AVVideoWidthKey: fixtureWidth,
        AVVideoHeightKey: fixtureHeight,
        AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: 1_500_000,
            AVVideoExpectedSourceFrameRateKey: fixtureFPS,
            AVVideoMaxKeyFrameIntervalKey: fixtureFPS
        ]
    ])
    video.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: fixtureWidth,
        kCVPixelBufferHeightKey as String: fixtureHeight,
        kCVPixelBufferCGImageCompatibilityKey as String: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
    ])
    let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: audioSampleRate,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 64_000
    ])
    audio.expectsMediaDataInRealTime = false
    try require(writer.canAdd(video) && writer.canAdd(audio), "Writer does not support the requested audio/video settings")
    writer.add(video)
    writer.add(audio)
    try require(writer.startWriting(), writer.error?.localizedDescription ?? "Cannot start writer")
    writer.startSession(atSourceTime: .zero)
    guard let pool = adaptor.pixelBufferPool else { throw FixtureError(description: "Missing video pixel buffer pool") }
    let audioFormat = try makeAudioFormat()
    print("正在生成 \(url.lastPathComponent)（\(duration) 秒，含 AAC 测试音）")
    for frame in 0..<(duration * Int(fixtureFPS)) {
        try autoreleasepool {
            try waitUntilReady(video, writer: writer)
            let pixels = try makeFrame(pool: pool, frame: frame, duration: duration, label: label)
            try require(adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: fixtureFPS)),
                        writer.error?.localizedDescription ?? "Cannot append video frame \(frame)")
            try waitUntilReady(audio, writer: writer)
            let audioFrame = try makeAudioFrame(frame: frame, duration: duration, format: audioFormat)
            try require(audio.append(audioFrame), writer.error?.localizedDescription ?? "Cannot append audio frame \(frame)")
        }
    }
    writer.endSession(atSourceTime: CMTime(value: Int64(duration), timescale: 1))
    video.markAsFinished()
    audio.markAsFinished()
    let completion = DispatchSemaphore(value: 0)
    writer.finishWriting { completion.signal() }
    try require(completion.wait(timeout: .now() + 30) == .success, "Timed out finishing \(label)")
    try require(writer.status == .completed, writer.error?.localizedDescription ?? "Writer did not complete \(label)")
}

func writeSubtitles(for videoURL: URL) throws {
    let srt = """
    1
    00:00:00,000 --> 00:00:02,000
    中文 SRT 字幕：你好，Apple Silicon！

    2
    00:00:02,000 --> 00:00:04,000
    第二行字幕 · 时间同步测试
    支持中文和空格文件名

    """
    let ass = """
    [Script Info]
    Title: SiliconPlayer 中文 ASS 测试
    ScriptType: v4.00+
    PlayResX: 640
    PlayResY: 360
    WrapStyle: 0
    ScaledBorderAndShadow: yes

    [V4+ Styles]
    Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
    Style: Default,PingFang SC,25,&H0000FFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,2.5,1,2,16,16,38,1

    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
    Dialogue: 0,0:00:00.00,0:00:02.00,Default,,0,0,0,,中文 ASS 字幕：黄色文字与黑色边框
    Dialogue: 0,0:00:02.00,0:00:04.00,Default,,0,0,0,,{\\c&HFFFF00&}青色字幕{\\r} · 支持样式与同步\\N第二行中文测试

    """
    let stem = videoURL.deletingPathExtension()
    try srt.write(to: stem.appendingPathExtension("srt"), atomically: true, encoding: .utf8)
    try ass.write(to: stem.appendingPathExtension("ass"), atomically: true, encoding: .utf8)
}

func fourCC(_ code: FourCharCode) -> String {
    String(bytes: [UInt8((code >> 24) & 0xff), UInt8((code >> 16) & 0xff), UInt8((code >> 8) & 0xff), UInt8(code & 0xff)], encoding: .ascii) ?? "unknown"
}

func verifyFixture(_ url: URL, expectedDuration: Int) async throws -> String {
    let asset = AVURLAsset(url: url)
    let duration = try await asset.load(.duration)
    let videoTracks = try await asset.loadTracks(withMediaType: .video)
    let audioTracks = try await asset.loadTracks(withMediaType: .audio)
    try require(videoTracks.count == 1 && audioTracks.count == 1, "Fixture must contain one video track and one audio track")
    let video = videoTracks[0]
    let size = try await video.load(.naturalSize)
    let fps = try await video.load(.nominalFrameRate)
    let videoFormats = try await video.load(.formatDescriptions)
    let audioFormats = try await audioTracks[0].load(.formatDescriptions)
    try require(abs(duration.seconds - Double(expectedDuration)) < 0.05, "Unexpected fixture duration: \(duration.seconds)")
    try require(Int(size.width) == fixtureWidth && Int(size.height) == fixtureHeight, "Unexpected fixture dimensions")
    try require(abs(fps - Float(fixtureFPS)) < 0.01, "Unexpected fixture frame rate")
    let audioReader = try AVAssetReader(asset: asset)
    let decodedAudio = AVAssetReaderTrackOutput(track: audioTracks[0], outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsNonInterleaved: false
    ])
    try require(audioReader.canAdd(decodedAudio), "Cannot create audio decode verification")
    audioReader.add(decodedAudio)
    try require(audioReader.startReading(), audioReader.error?.localizedDescription ?? "Cannot decode AAC audio")
    var decodedSampleCount = 0
    while let samples = decodedAudio.copyNextSampleBuffer() {
        decodedSampleCount += CMSampleBufferGetNumSamples(samples)
    }
    try require(audioReader.status == .completed, audioReader.error?.localizedDescription ?? "AAC audio decode did not complete")
    try require(abs(Double(decodedSampleCount) / Double(audioSampleRate) - Double(expectedDuration)) < 0.1,
                "Decoded audio duration differs from video duration")
    let imageGenerator = AVAssetImageGenerator(asset: asset)
    imageGenerator.appliesPreferredTrackTransform = true
    imageGenerator.requestedTimeToleranceBefore = .zero
    imageGenerator.requestedTimeToleranceAfter = .zero
    let preview = try await imageGenerator.image(at: CMTime(value: 2, timescale: 1))
    let image = NSBitmapImageRep(cgImage: preview.image)
    guard let png = image.representation(using: .png, properties: [:]) else {
        throw FixtureError(description: "Cannot encode verification preview")
    }
    try png.write(to: url.deletingPathExtension().appendingPathExtension("png"))
    let videoCodec = videoFormats.first.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) } ?? "unknown"
    let audioCodec = audioFormats.first.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) } ?? "unknown"
    let result = "\(url.lastPathComponent): \(videoCodec) + \(audioCodec), \(Int(size.width))×\(Int(size.height)), \(fps) fps, \(String(format: "%.3f", duration.seconds)) 秒；AVFoundation \(String(format: "%.3f", preview.actualTime.seconds)) 秒帧解码成功；AAC 解码 \(decodedSampleCount) 个 PCM 采样"
    print(result)
    return result
}

do {
    let defaultRoot = URL(fileURLWithPath: #filePath).standardizedFileURL.deletingLastPathComponent().deletingLastPathComponent()
    let outputDirectory = CommandLine.arguments.count > 1
        ? URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL
        : defaultRoot.appendingPathComponent("Tests/Fixtures", isDirectory: true)
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    let fixtures: [(String, AVVideoCodecType, Int, String)] = [
        ("中文 测试 H264.mp4", .h264, 12, "H.264"),
        ("中文 测试 HEVC.mp4", .hevc, 5, "HEVC")
    ]
    var verification: [String] = []
    for (filename, codec, duration, label) in fixtures {
        let url = outputDirectory.appendingPathComponent(filename)
        try writeFixture(to: url, codec: codec, duration: duration, label: label)
        try writeSubtitles(for: url)
        verification.append(try await verifyFixture(url, expectedDuration: duration))
    }
    let report = """
    生成命令：swift scripts/make_fixtures.swift
    生成工具：Swift + AVFoundation / AVAssetWriter，未使用 FFmpeg。
    音频：48 kHz 单声道 AAC，440 Hz 低音量测试音，头尾有短淡入淡出。
    此记录验证容器、轨道、时长、尺寸、帧率和 AVFoundation 解码，不能代替 SiliconPlayer / libmpv 播放验收。

    \(verification.joined(separator: "\n"))

    """
    try report.write(to: outputDirectory.appendingPathComponent("生成验证.txt"), atomically: true, encoding: .utf8)
    print("输出目录：\(outputDirectory.path)")
} catch {
    fputs("测试素材生成失败：\(error)\n", stderr)
    exit(1)
}

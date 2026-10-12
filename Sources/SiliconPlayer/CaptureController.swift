import AppKit
@preconcurrency import AVFoundation
import Combine
import CoreImage
import ScreenCaptureKit
import UniformTypeIdentifiers

enum CaptureSourceKind: String, CaseIterable, Identifiable {
    case display, window, camera
    var id: Self { self }
    var title: String { switch self { case .display: return "屏幕"; case .window: return "窗口"; case .camera: return "摄像头" } }
}

enum CaptureVideoCodec: String, CaseIterable, Identifiable {
    case h264, hevc
    var id: Self { self }
    var title: String { self == .h264 ? "H.264" : "HEVC" }
    var avCodec: AVVideoCodecType { self == .h264 ? .h264 : .hevc }
}

private struct CaptureFailure: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// UI state is isolated to the main actor. Each capture driver owns a separate
/// serial queue; no AVAssetWriter operation is performed on the UI actor.
@MainActor
final class CaptureController: ObservableObject {
    static let shared = CaptureController()
    @Published var sourceKind: CaptureSourceKind = .display
    @Published var codec: CaptureVideoCodec = .h264
    @Published var frameRate = 30
    @Published var maximumDimension = 1920
    @Published var includeCursor = true
    @Published var excludePlayer = true
    @Published var includeSystemAudio = false
    @Published var includeMicrophone = false
    @Published var selectedDisplayID: UInt32?
    @Published var selectedWindowID: UInt32?
    @Published var selectedCameraID = ""
    @Published var selectedMicrophoneID = ""
    @Published private(set) var displays: [SCDisplay] = []
    @Published private(set) var windows: [SCWindow] = []
    @Published private(set) var cameras: [AVCaptureDevice] = []
    @Published private(set) var microphones: [AVCaptureDevice] = []
    @Published private(set) var isBusy = false
    @Published private(set) var isRecording = false
    @Published private(set) var isPreviewing = false
    @Published private(set) var elapsed = 0.0
    @Published private(set) var status = "请选择来源，点击刷新读取可用设备。"
    @Published var error: String?
    @Published private(set) var lastRecordingURL: URL?
    @Published private(set) var screenPreview: NSImage?
    @Published private(set) var cameraSession: AVCaptureSession?

    private var shareableApplications: [SCRunningApplication] = []
    private var screenStream: SCStream?
    private var screenSink: ScreenCaptureSink?
    private var cameraDriver: CameraCaptureDriver?
    private var targetURL: URL?
    private var stagingURL: URL?
    private var captureToken = UUID()
    private var elapsedTimer: Timer?
    private var startedAt: Date?
    private var cameraStopRequested = false
    private var pendingStreamError: String?

    var canStart: Bool {
        guard !isBusy, !isRecording else { return false }
        switch sourceKind {
        case .display: return displays.contains { $0.displayID == selectedDisplayID }
        case .window: return windows.contains { $0.windowID == selectedWindowID }
        case .camera: return cameras.contains { $0.uniqueID == selectedCameraID }
        }
    }

    func refreshSources() async {
        guard !isBusy, !isRecording else { return }
        isBusy = true
        defer { isBusy = false }
        error = nil
        do {
            try await stopPreviewInternal()
            try await loadSources()
            status = sourceKind == .camera ? "找到 \(cameras.count) 台摄像头；点击预览查看画面。" : "找到 \(displays.count) 个屏幕、\(windows.count) 个窗口。"
        } catch { self.error = error.localizedDescription }
    }

    func startPreview() async {
        guard !isBusy, !isRecording else { return }
        isBusy = true
        defer { isBusy = false }
        error = nil
        do {
            try await stopPreviewInternal()
            if !hasSelectedSource { try await loadSources() }
            if sourceKind == .camera { try await prepareCamera(recording: false) }
            else { try await prepareScreen(recording: false) }
            isPreviewing = true
            status = "预览中，尚未写入录制文件。"
        } catch { await clearFailedCapture(error.localizedDescription) }
    }

    func stopPreview() async {
        guard !isBusy, !isRecording else { return }
        isBusy = true
        defer { isBusy = false }
        do { try await stopPreviewInternal(); status = "预览已停止。" }
        catch { self.error = error.localizedDescription }
    }

    func startRecording() async {
        guard !isBusy, !isRecording else { return }
        let panel = NSSavePanel()
        panel.title = "保存采集视频"
        panel.allowedContentTypes = [.quickTimeMovie]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        panel.nameFieldStringValue = "SiliconPlayer-\(sourceKind.title)-\(formatter.string(from: Date())).mov"
        panel.directoryURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        isBusy = true
        error = nil
        lastRecordingURL = nil
        elapsed = 0
        do {
            try await stopPreviewInternal()
            if !hasSelectedSource { try await loadSources() }
            targetURL = destination
            stagingURL = destination.deletingLastPathComponent()
                .appendingPathComponent(".\(destination.deletingPathExtension().lastPathComponent)-\(UUID().uuidString).recording.mov")
            status = "正在启动采集…"
            if sourceKind == .camera {
                try await prepareCamera(recording: true)
                guard let stagingURL, let cameraDriver else { throw CaptureFailure(message: "摄像头会话未准备完成。") }
                cameraStopRequested = false
                cameraDriver.startRecording(to: stagingURL)
                // AVCaptureMovieFileOutput's didStart callback clears busy.
            } else {
                try await prepareScreen(recording: true)
                didStartRecording()
            }
        } catch { await clearFailedCapture(error.localizedDescription) }
    }

    func stopRecording() async {
        guard isRecording, !isBusy else { return }
        isBusy = true
        status = "正在结束并保存 MOV…"
        stopElapsedTimer()
        if let cameraDriver {
            cameraStopRequested = true
            cameraDriver.stopRecording()
            // The delegate owns completion and closes the camera session.
            return
        }
        do {
            let stream = screenStream
            let sink = screenSink
            captureToken = UUID()
            var stoppingError: Error?
            if let stream {
                do { try await stream.stopCapture() }
                catch { stoppingError = error }
            }
            guard let sink else { throw CaptureFailure(message: "录制会话不存在。") }
            try await sink.finishRecording()
            try publishRecording()
            resetCaptureState()
            if let stoppingError {
                error = "采集提前停止，已保存可用片段：\(stoppingError.localizedDescription)"
                status = "采集已结束，可用片段已保存。"
            } else { status = "录制已保存，可直接打开播放。" }
        } catch { await clearFailedCapture(error.localizedDescription) }
    }

    /// Called when the tool sheet is dismissed. Recording keeps the sheet open;
    /// an ordinary preview is released and its device indicator goes off.
    func dismissPreview() async {
        guard !isRecording, !isBusy else { return }
        do { try await stopPreviewInternal() }
        catch { self.error = error.localizedDescription }
    }

    func shutdown() async {
        if isRecording && !isBusy { await stopRecording() }
        let deadline = Date().addingTimeInterval(10)
        while (isBusy || isRecording) && Date() < deadline { try? await Task.sleep(nanoseconds: 100_000_000) }
        if isBusy || isRecording { await clearFailedCapture("采集已取消，正在退出播放器。") }
        else { try? await stopPreviewInternal() }
    }

    private var hasSelectedSource: Bool {
        switch sourceKind {
        case .display: return displays.contains { $0.displayID == selectedDisplayID }
        case .window: return windows.contains { $0.windowID == selectedWindowID }
        case .camera: return cameras.contains { $0.uniqueID == selectedCameraID }
        }
    }

    private func loadSources() async throws {
        if sourceKind == .camera {
            try await Self.requestPermission(.video, description: "摄像头")
            cameras = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified).devices
            microphones = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified).devices
            if !cameras.contains(where: { $0.uniqueID == selectedCameraID }) { selectedCameraID = cameras.first?.uniqueID ?? "" }
            if !microphones.contains(where: { $0.uniqueID == selectedMicrophoneID }) { selectedMicrophoneID = microphones.first?.uniqueID ?? "" }
            guard !cameras.isEmpty else { throw CaptureFailure(message: "未检测到摄像头。请连接 USB 摄像头，或启用可用的连续互通相机。") }
        } else {
            // This is the only ScreenCaptureKit enumeration and is reached only
            // from an explicit refresh, preview or recording action.
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            displays = content.displays
            windows = content.windows.filter { $0.frame.width > 1 && $0.frame.height > 1 && $0.owningApplication != nil }
                .sorted { Self.windowTitle($0).localizedStandardCompare(Self.windowTitle($1)) == .orderedAscending }
            shareableApplications = content.applications
            if !displays.contains(where: { $0.displayID == selectedDisplayID }) { selectedDisplayID = displays.first?.displayID }
            if !windows.contains(where: { $0.windowID == selectedWindowID }) { selectedWindowID = windows.first?.windowID }
            guard !displays.isEmpty else { throw CaptureFailure(message: "没有可用屏幕。请在系统设置 → 隐私与安全性 → 屏幕与系统音频录制中允许 SiliconPlayer。") }
        }
    }

    static func windowTitle(_ window: SCWindow) -> String {
        let app = window.owningApplication?.applicationName ?? "应用"
        let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return "\(app) · \(title.isEmpty ? "窗口 \(window.windowID)" : title)"
    }

    private static func requestPermission(_ type: AVMediaType, description: String) async throws {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized: return
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: type) else {
                throw CaptureFailure(message: "未获得\(description)权限，请到系统设置 → 隐私与安全性中允许访问。")
            }
        default: throw CaptureFailure(message: "\(description)权限未开启，请到系统设置 → 隐私与安全性中允许 SiliconPlayer。")
        }
    }

    private func prepareScreen(recording: Bool) async throws {
        let filter: SCContentFilter
        let sourceWidth: Int
        let sourceHeight: Int
        if sourceKind == .window {
            guard let window = windows.first(where: { $0.windowID == selectedWindowID }) else { throw CaptureFailure(message: "请选择可用窗口并刷新列表。") }
            filter = SCContentFilter(desktopIndependentWindow: window)
            sourceWidth = max(2, Int(window.frame.width * Double(filter.pointPixelScale)))
            sourceHeight = max(2, Int(window.frame.height * Double(filter.pointPixelScale)))
        } else {
            guard let display = displays.first(where: { $0.displayID == selectedDisplayID }) else { throw CaptureFailure(message: "请选择可用屏幕并刷新列表。") }
            if excludePlayer, let app = shareableApplications.first(where: { $0.processID == ProcessInfo.processInfo.processIdentifier }) {
                filter = SCContentFilter(display: display, excludingApplications: [app], exceptingWindows: [])
            } else { filter = SCContentFilter(display: display, excludingWindows: []) }
            sourceWidth = display.width
            sourceHeight = display.height
        }
        let scale = min(1.0, Double(maximumDimension) / Double(max(sourceWidth, sourceHeight)))
        let width = max(2, Int(Double(sourceWidth) * scale) / 2 * 2)
        let height = max(2, Int(Double(sourceHeight) * scale) / 2 * 2)
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.queueDepth = 5
        configuration.showsCursor = includeCursor
        configuration.capturesAudio = recording && includeSystemAudio
        configuration.excludesCurrentProcessAudio = excludePlayer && sourceKind == .display
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        let token = UUID()
        captureToken = token
        pendingStreamError = nil
        let sink = try ScreenCaptureSink(outputURL: recording ? stagingURL : nil, width: width, height: height,
            codec: codec.avCodec, frameRate: frameRate, capturesAudio: configuration.capturesAudio,
            onPreview: { [weak self] image in
                guard let self, self.captureToken == token else { return }
                self.screenPreview = image
            }, onFailure: { [weak self] message in
                guard let self, self.captureToken == token else { return }
                if self.isBusy { self.pendingStreamError = message; return }
                Task {
                    guard self.captureToken == token else { return }
                    await self.handleScreenFailure(message)
                }
            })
        let stream = SCStream(filter: filter, configuration: configuration, delegate: sink)
        try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sink.queue)
        if configuration.capturesAudio { try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: sink.queue) }
        screenSink = sink
        screenStream = stream
        try await stream.startCapture()
        if let pendingStreamError { throw CaptureFailure(message: pendingStreamError) }
        isPreviewing = true
    }

    private func prepareCamera(recording: Bool) async throws {
        try await Self.requestPermission(.video, description: "摄像头")
        guard let device = cameras.first(where: { $0.uniqueID == selectedCameraID }) else { throw CaptureFailure(message: "请选择可用摄像头。") }
        var microphone: AVCaptureDevice?
        if recording && includeMicrophone {
            try await Self.requestPermission(.audio, description: "麦克风")
            guard let selected = microphones.first(where: { $0.uniqueID == selectedMicrophoneID }) else { throw CaptureFailure(message: "未检测到所选麦克风，请刷新设备列表。") }
            microphone = selected
        }
        let token = UUID()
        captureToken = token
        let driver = CameraCaptureDriver(onStarted: { [weak self] in
            guard let self, self.captureToken == token else { return }
            self.didStartRecording()
        }, onFinished: { [weak self] message in
            guard let self, self.captureToken == token else { return }
            Task { await self.cameraRecordingFinished(message: message) }
        })
        cameraDriver = driver
        try await driver.prepare(camera: device, microphone: microphone, recording: recording)
        cameraSession = driver.session
        isPreviewing = true
    }

    private func didStartRecording() {
        isRecording = true
        isBusy = false
        startedAt = Date()
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let startedAt = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(startedAt)
            }
        }
        if let elapsedTimer { RunLoop.main.add(elapsedTimer, forMode: .common) }
        status = "正在录制，点击停止后完成文件保存。"
    }

    private func handleScreenFailure(_ message: String) async {
        if isRecording {
            await stopRecording()
            error = message
            if lastRecordingURL != nil { status = "采集已结束，可用片段已保存。" }
        } else { await clearFailedCapture(message) }
    }

    private func cameraRecordingFinished(message: String?) async {
        stopElapsedTimer()
        isBusy = true
        if let message { await clearFailedCapture(message); return }
        do {
            try publishRecording()
            if let cameraDriver { await cameraDriver.stopSession() }
            resetCaptureState()
            status = cameraStopRequested ? "录制已保存，可直接打开播放。" : "摄像头录制已结束，文件已保存。"
        } catch { await clearFailedCapture(error.localizedDescription) }
    }

    private func publishRecording() throws {
        guard let targetURL, let stagingURL, FileManager.default.fileExists(atPath: stagingURL.path) else {
            throw CaptureFailure(message: "录制未生成有效文件。")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: stagingURL.path)
        guard (attributes[.size] as? NSNumber)?.int64Value ?? 0 > 0 else { throw CaptureFailure(message: "录制输出为空，未覆盖目标文件。") }
        if FileManager.default.fileExists(atPath: targetURL.path) {
            _ = try FileManager.default.replaceItemAt(targetURL, withItemAt: stagingURL)
        } else { try FileManager.default.moveItem(at: stagingURL, to: targetURL) }
        lastRecordingURL = targetURL
        self.targetURL = nil
        self.stagingURL = nil
    }

    private func stopPreviewInternal() async throws {
        captureToken = UUID()
        let stream = screenStream
        let sink = screenSink
        var stoppingError: Error?
        if let stream {
            do { try await stream.stopCapture() }
            catch { stoppingError = error }
        }
        if let sink { await sink.cancelRecording() }
        if let cameraDriver { await cameraDriver.stopSession() }
        screenStream = nil
        screenSink = nil
        cameraDriver = nil
        cameraSession = nil
        screenPreview = nil
        isPreviewing = false
        if let stoppingError { throw stoppingError }
    }

    private func clearFailedCapture(_ message: String) async {
        isBusy = true
        captureToken = UUID()
        stopElapsedTimer()
        if let stream = screenStream { try? await stream.stopCapture() }
        if let sink = screenSink { await sink.cancelRecording() }
        if let cameraDriver { await cameraDriver.stopSession() }
        if let stagingURL { try? FileManager.default.removeItem(at: stagingURL) }
        targetURL = nil
        stagingURL = nil
        resetCaptureState()
        error = message
        status = "采集已停止。"
    }

    private func resetCaptureState() {
        captureToken = UUID()
        screenStream = nil
        screenSink = nil
        cameraDriver = nil
        cameraSession = nil
        screenPreview = nil
        isPreviewing = false
        isRecording = false
        isBusy = false
        startedAt = nil
        pendingStreamError = nil
    }

    private func stopElapsedTimer() {
        if let startedAt { elapsed = Date().timeIntervalSince(startedAt) }
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }
}

/// All writer state below is touched only by `queue`, including completion and
/// cancellation. ScreenCaptureKit audio/video callbacks share this same queue.
private final class ScreenCaptureSink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "SiliconPlayer.screen-capture", qos: .userInitiated)
    private let onPreview: @MainActor (NSImage) -> Void
    private let onFailure: @MainActor (String) -> Void
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let writer: AVAssetWriter?
    private let videoInput: AVAssetWriterInput?
    private let audioInput: AVAssetWriterInput?
    private let frameDuration: CMTime
    private var firstTimestamp: CMTime?
    private var firstUptime = 0.0
    private var lastVideoSample: CMSampleBuffer?
    private var lastPreviewUptime = 0.0
    private var isFinishing = false
    private var reportedFailure = false

    init(outputURL: URL?, width: Int, height: Int, codec: AVVideoCodecType, frameRate: Int, capturesAudio: Bool,
         onPreview: @escaping @MainActor (NSImage) -> Void, onFailure: @escaping @MainActor (String) -> Void) throws {
        self.onPreview = onPreview
        self.onFailure = onFailure
        frameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        if let outputURL {
            let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
            let settings: [String: Any] = [AVVideoCodecKey: codec, AVVideoWidthKey: width, AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(2_000_000, min(40_000_000, width * height * frameRate / 7)),
                    AVVideoExpectedSourceFrameRateKey: frameRate, AVVideoMaxKeyFrameIntervalKey: frameRate * 2]]
            guard writer.canApply(outputSettings: settings, forMediaType: .video) else { throw CaptureFailure(message: "当前系统不能使用所选视频编码。请切换 H.264 或降低分辨率。") }
            let video = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            video.expectsMediaDataInRealTime = true
            guard writer.canAdd(video) else { throw CaptureFailure(message: "无法创建视频编码轨道。") }
            writer.add(video)
            videoInput = video
            if capturesAudio {
                let audioSettings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000]
                guard writer.canApply(outputSettings: audioSettings, forMediaType: .audio) else { throw CaptureFailure(message: "无法创建系统音频编码轨道。") }
                let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                audio.expectsMediaDataInRealTime = true
                guard writer.canAdd(audio) else { throw CaptureFailure(message: "无法加入系统音频轨道。") }
                writer.add(audio)
                audioInput = audio
            } else { audioInput = nil }
            self.writer = writer
        } else { writer = nil; videoInput = nil; audioInput = nil }
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        consume(sampleBuffer, of: outputType)
    }

    func consume(_ sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isFinishing, sampleBuffer.isValid else { return }
        if outputType == .screen {
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let rawStatus = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: rawStatus) == .complete,
                  let pixelBuffer = sampleBuffer.imageBuffer else { return }
            updatePreview(pixelBuffer)
            guard let writer, let videoInput else { return }
            if firstTimestamp == nil {
                guard writer.startWriting() else { fail(writer.error?.localizedDescription ?? "无法启动视频写入。"); return }
                firstTimestamp = sampleBuffer.presentationTimeStamp
                firstUptime = ProcessInfo.processInfo.systemUptime
                writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
            }
            guard writer.status == .writing else { fail(writer.error?.localizedDescription ?? "视频编码器已停止。"); return }
            if videoInput.isReadyForMoreMediaData {
                guard videoInput.append(sampleBuffer) else { fail(writer.error?.localizedDescription ?? "视频画面写入失败。"); return }
                lastVideoSample = sampleBuffer
            }
        } else if outputType == .audio {
            guard let writer, let audioInput, let firstTimestamp, writer.status == .writing,
                  sampleBuffer.presentationTimeStamp >= firstTimestamp, audioInput.isReadyForMoreMediaData else { return }
            if !audioInput.append(sampleBuffer) { fail(writer.error?.localizedDescription ?? "系统音频写入失败。") }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { [weak self] in
            guard let self, !self.isFinishing else { return }
            self.fail("屏幕采集中断：\(error.localizedDescription)")
        }
    }

    func finishRecording() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard let writer = self.writer, let video = self.videoInput, let first = self.firstTimestamp,
                      let last = self.lastVideoSample, writer.status == .writing else {
                    self.writer?.cancelWriting()
                    continuation.resume(throwing: CaptureFailure(message: self.writer?.error?.localizedDescription ?? "没有收到有效录制画面；目标文件保持原样。"))
                    return
                }
                self.isFinishing = true
                let uptimeDuration = max(CMTimeGetSeconds(self.frameDuration), ProcessInfo.processInfo.systemUptime - self.firstUptime)
                let finalTime = max(last.presentationTimeStamp + self.frameDuration, first + CMTime(seconds: uptimeDuration, preferredTimescale: 600))
                self.appendFinalFrame(last, at: finalTime - self.frameDuration, attempts: 50) {
                    guard writer.status == .writing else {
                        continuation.resume(throwing: CaptureFailure(message: writer.error?.localizedDescription ?? "录制最后一帧写入失败。"))
                        return
                    }
                    writer.endSession(atSourceTime: finalTime)
                    video.markAsFinished()
                    self.audioInput?.markAsFinished()
                    writer.finishWriting {
                        self.queue.async {
                            if self.writer?.status == .completed { continuation.resume() }
                            else { continuation.resume(throwing: CaptureFailure(message: self.writer?.error?.localizedDescription ?? "MOV 文件保存失败。")) }
                        }
                    }
                }
            }
        }
    }

    func cancelRecording() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.isFinishing = true
                if self.writer?.status == .writing || self.writer?.status == .unknown { self.writer?.cancelWriting() }
                continuation.resume()
            }
        }
    }

    private func appendFinalFrame(_ sample: CMSampleBuffer, at time: CMTime, attempts: Int, completion: @escaping () -> Void) {
        guard let videoInput, time > sample.presentationTimeStamp else { completion(); return }
        guard videoInput.isReadyForMoreMediaData else {
            if attempts > 0 {
                queue.asyncAfter(deadline: .now() + 0.01) {
                    if let last = self.lastVideoSample { self.appendFinalFrame(last, at: time, attempts: attempts - 1, completion: completion) }
                    else { completion() }
                }
            } else { completion() }
            return
        }
        var timing = CMSampleTimingInfo(duration: frameDuration, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var copied: CMSampleBuffer?
        if CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &copied) == noErr, let copied {
            _ = videoInput.append(copied)
        }
        completion()
    }

    private func updatePreview(_ buffer: CVPixelBuffer) {
        let uptime = ProcessInfo.processInfo.systemUptime
        guard uptime - lastPreviewUptime >= 0.25 else { return }
        lastPreviewUptime = uptime
        let image = CIImage(cvPixelBuffer: buffer)
        let ratio = min(1, 560 / max(image.extent.width, image.extent.height))
        let scaled = image.transformed(by: CGAffineTransform(scaleX: ratio, y: ratio))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return }
        let preview = NSImage(cgImage: cgImage, size: scaled.extent.size)
        Task { @MainActor [onPreview] in onPreview(preview) }
    }

    private func fail(_ message: String) {
        guard !reportedFailure else { return }
        reportedFailure = true
        Task { @MainActor [onFailure] in onFailure(message) }
    }
}

private final class CameraCaptureDriver: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "SiliconPlayer.camera-capture", qos: .userInitiated)
    private let output = AVCaptureMovieFileOutput()
    private let onStarted: @MainActor () -> Void
    private let onFinished: @MainActor (String?) -> Void

    init(onStarted: @escaping @MainActor () -> Void, onFinished: @escaping @MainActor (String?) -> Void) {
        self.onStarted = onStarted
        self.onFinished = onFinished
        super.init()
    }

    func prepare(camera: AVCaptureDevice, microphone: AVCaptureDevice?, recording: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    self.session.beginConfiguration()
                    defer { self.session.commitConfiguration() }
                    if self.session.canSetSessionPreset(.hd1920x1080) { self.session.sessionPreset = .hd1920x1080 }
                    else { self.session.sessionPreset = .high }
                    let cameraInput = try AVCaptureDeviceInput(device: camera)
                    guard self.session.canAddInput(cameraInput) else { throw CaptureFailure(message: "无法连接摄像头，设备可能正在被其他应用占用。") }
                    self.session.addInput(cameraInput)
                    if let microphone {
                        let input = try AVCaptureDeviceInput(device: microphone)
                        guard self.session.canAddInput(input) else { throw CaptureFailure(message: "无法连接所选麦克风。") }
                        self.session.addInput(input)
                    }
                    if recording {
                        guard self.session.canAddOutput(self.output) else { throw CaptureFailure(message: "无法创建摄像头录制输出。") }
                        self.session.addOutput(self.output)
                        guard let connection = self.output.connection(with: .video) else { throw CaptureFailure(message: "摄像头未提供有效视频连接。") }
                        self.output.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.h264], for: connection)
                    }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
        await withCheckedContinuation { continuation in
            queue.async { self.session.startRunning(); continuation.resume() }
        }
        guard session.isRunning else { throw CaptureFailure(message: "摄像头未能启动。请检查设备连接与系统权限。") }
    }

    func startRecording(to url: URL) {
        queue.async { self.output.startRecording(to: url, recordingDelegate: self) }
    }

    func stopRecording() { queue.async { if self.output.isRecording { self.output.stopRecording() } } }

    func stopSession() async {
        await withCheckedContinuation { continuation in
            queue.async {
                if self.output.isRecording { self.output.stopRecording() }
                if self.session.isRunning { self.session.stopRunning() }
                continuation.resume()
            }
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        Task { @MainActor [onStarted] in onStarted() }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        let nsError = error as NSError?
        let finishedSuccessfully = error == nil || (nsError?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? NSNumber)?.boolValue == true
        let message = finishedSuccessfully ? nil : error?.localizedDescription ?? "摄像头录制失败。"
        Task { @MainActor [onFinished] in onFinished(message) }
    }
}

import AppKit
import SwiftUI
import PlayerCore

/// Opt-in actual-app checks of the same EPG service/view used by the channel panel.
/// No external accessibility, synthesized input, or user preference changes.
@MainActor
final class EPGVerifier {
    private let player: PlayerModel
    private let report: URL
    private let mode: String
    private var service: EPGService?
    private var guideWindow: NSWindow?
    private var worker: Task<Void, Never>?
    private var observations: [[String: Any]] = []
    private var result: [String: Any]?

    init(player: PlayerModel, report: URL, mode: String) {
        self.player = player; self.report = report; self.mode = mode
        worker = Task { [weak self] in await self?.run() }
    }
    func tick() -> [String: Any]? { result }
    private struct Failure: LocalizedError {
        let text: String
        var errorDescription: String? { text }
    }
    private func check(_ id: String, _ value: Bool) throws {
        observations.append(["id": id, "passed": value])
        if !value { throw Failure(text: id) }
    }
    private func wait(_ seconds: TimeInterval = 8, label: String = "service work", until condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !condition() {
            if Task.isCancelled { throw Failure(text: "verification cancelled") }
            if ProcessInfo.processInfo.systemUptime >= deadline { throw Failure(text: "EPG condition timeout: \(label)") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
    private func writeGuideImage(_ service: EPGService) throws -> URL {
        let view = NSHostingView(rootView: EPGView(service: service, playChannel: { [weak player] url in
            player?.open([url])
        }, onDone: {}).background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(x: 160, y: 100, width: 1180, height: 740),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "SiliconPlayer 节目单验证"
        window.isReleasedWhenClosed = false; window.contentView = view
        window.makeKeyAndOrderFront(nil); guideWindow = window
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw Failure(text: "EPG view bitmap unavailable")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw Failure(text: "EPG view PNG unavailable")
        }
        let path = report.deletingPathExtension().appendingPathExtension("png")
        try data.write(to: path, options: .atomic)
        return path
    }
    private func requestQuit(_ service: EPGService, id: String) throws {
        try check(id, EPGService.hasActiveJobs)
        result = ["epgChecks": observations, "epgPassed": true, "epgQuitRequestedUptime": ProcessInfo.processInfo.systemUptime,
                  "epgJobsActiveAtQuit": EPGService.hasActiveJobs, "physicalNativeUIAcceptance": false]
        // SessionVerifier writes the report and requests normal AppKit termination.
        // AppDelegate must cancel and await these real network operations.
    }
    private func run() async {
        do {
            let env = ProcessInfo.processInfo.environment
            guard let raw = env["SILICONPLAYER_VERIFY_EPG_ORIGIN"], let origin = URL(string: raw),
                  origin.scheme == "http", origin.host == "127.0.0.1", origin.port != nil else {
                throw Failure(text: "loopback EPG fixture origin required")
            }
            let media = origin.appendingPathComponent("media.mp4")
            let channelsText = "#EXTM3U\n#EXTINF:-1 tvg-id=\"alpha.zh\" group-title=\"验证频道\",中文测试频道\n\(media.absoluteString)\n#EXTINF:-1 tvg-id=\"missing\",手工匹配频道\n\(origin.appendingPathComponent("manual.mp4").absoluteString)\n"
            let parsed = try ChannelDocument.parse(channelsText, baseURL: origin.appendingPathComponent("channels.m3u"))
            let channels = parsed.channels.map { EPGChannelReference(mediaURL: $0.url, tvgID: $0.tvgID, displayName: $0.name, logoURL: $0.logoURL) }
            let preferencesFile = PlayerModel.supportDirectory.appendingPathComponent("epg-verification-preferences.json")
            let preferences = EPGPreferencesStore(file: preferencesFile)
            let cache = EPGLogoCache(directory: PlayerModel.supportDirectory.appendingPathComponent("EPGVerificationLogos", isDirectory: true))
            let service = EPGService(channels: channels, transport: ProductionEPGSourceTransport(username: "guide-user", password: "guide-password"),
                                     logoCache: cache, preferences: preferences)
            self.service = service
            try check("m3u-tvg-id-original-media", channels.count == 2 && channels[0].tvgID == "alpha.zh" && channels[0].mediaURL == media)
            service.address = origin.appendingPathComponent(mode == "epg-quit-load" ? "slow.xml" : "guide.xml").absoluteString
            service.loadRemote()
            if mode == "epg-quit-load" {
                try await Task.sleep(nanoseconds: 400_000_000)
                try check("actual-guide-request-in-progress", service.isBusy)
                try requestQuit(service, id: "quit-awaits-owned-guide-request")
                return
            }
            try await wait { !service.isBusy }
            try check("actual-source-transport-commits", service.document?.channelIDs.contains("alpha.zh") == true && service.error == nil)
            let original = service.document
            try check("exact-id-mapping-no-name-guess", service.mappedID(channels[0]) == "alpha.zh" && service.mappedID(channels[1]) == nil)
            let current = service.nowAndNext(channels[0], at: Date())
            try check("current-next-and-day-schedule", current?.current.first?.programme.title == "正在播出的中文节目"
                      && current?.next.first?.title == "下一档节目" && service.daySchedule(channels[0], on: Date()).count >= 2)
            await service.requestLogo(channels[0])
            try check("logos-disabled-until-explicit-action", !service.logoEnabled && service.logoImage(channels[0]) == nil)
            service.setMapping(channels[1], channelID: "alpha.zh")
            try check("manual-id-mapping-persists", service.mappedID(channels[1]) == "alpha.zh" && preferences.value.manualMappings.count == 1)
            service.setLogoEnabled(true)
            if mode == "epg-quit-logo" {
                let slow = EPGChannelReference(mediaURL: media, tvgID: "alpha.zh", displayName: "慢台标", logoURL: origin.appendingPathComponent("slow-logo.png"))
                service.setChannels([slow])
                Task { await service.requestLogo(slow) }
                try await wait { service.logoPending > 0 }
                try await Task.sleep(nanoseconds: 400_000_000)
                try requestQuit(service, id: "quit-awaits-owned-logo-request")
                return
            }
            await service.requestLogo(channels[0])
            try check("actual-anonymous-logo-image", service.logoImage(channels[0]) != nil && service.logoPending == 0)
            // Build the real SwiftUI view once, then let it lay out before capture.
            _ = try writeGuideImage(service)
            try await Task.sleep(nanoseconds: 300_000_000)
            guard let view = guideWindow?.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                throw Failure(text: "EPG displayed view disappeared")
            }
            view.layoutSubtreeIfNeeded(); view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw Failure(text: "EPG displayed PNG failure") }
            let image = report.deletingPathExtension().appendingPathExtension("png")
            try png.write(to: image, options: .atomic)
            try check("actual-hosted-guide-view-png", png.count > 1024 && bitmap.pixelsWide >= 880 && bitmap.pixelsHigh >= 640)
            let bytesBefore = try Data(contentsOf: preferencesFile)
            service.address = origin.appendingPathComponent("bad.xml").absoluteString; service.loadRemote()
            try await wait { !service.isBusy }
            try check("failed-source-preserves-document-preferences", service.document == original && service.error != nil && (try Data(contentsOf: preferencesFile)) == bytesBefore)
            service.address = origin.appendingPathComponent("guide.xml").absoluteString + "?username=verification-session-secret"
            service.loadRemote(); try await wait { !service.isBusy }
            try check("credential-query-session-only", service.document != nil && service.error == nil
                      && service.committedSource?.absoluteString == service.address && service.status.contains("地址未保存")
                      && !String(decoding: try Data(contentsOf: preferencesFile), as: UTF8.self).contains("verification-session-secret"))
            let restored = EPGService(channels: channels, transport: ProductionEPGSourceTransport(), logoCache: cache,
                                      preferences: EPGPreferencesStore(file: preferencesFile))
            try check("restore-no-automatic-network", restored.document == nil && !restored.isBusy && restored.logoEnabled
                      && !restored.logoRequestsAuthorized && restored.mappedID(channels[1]) == nil)
            service.address = origin.appendingPathComponent("slow.xml").absoluteString; service.loadRemote()
            try await Task.sleep(nanoseconds: 400_000_000); service.cancel()
            try await wait { !EPGService.hasActiveJobs }
            try check("real-request-cancel-preserves-guide", !service.isBusy && service.document != nil)
            player.open([channels[0].mediaURL])
            try await wait(15, label: "original channel loads") { self.player.loaded && self.player.currentURL == media }
            let frames = player.renderProgress.frames
            try await wait(5, label: "original channel advances real video frames") { self.player.renderProgress.frames >= frames + 24 && self.player.position > 0.2 }
            try check("original-channel-plays-real-renderer", player.currentURL == media && player.tracks.contains(where: { $0.type == "video" })
                      && player.tracks.contains(where: { $0.type == "audio" }) && player.renderProgress.frames >= frames + 24)
            guideWindow?.close(); guideWindow = nil
            let clean = await EPGService.shutdownAll()
            try check("service-shutdown-drains-owned-jobs", clean && !EPGService.hasActiveJobs)
            result = ["epgChecks": observations, "epgPassed": true, "epgPNG": image.path,
                      "epgPreferencesSHA256Scope": "isolated test file, no daily preferences",
                      "physicalNativeUIAcceptance": false, "epgGuideAndLogoHTTP": true]
        } catch {
            guideWindow?.close(); guideWindow = nil
            _ = await EPGService.shutdownAll()
            result = ["epgChecks": observations, "epgPassed": false, "failure": error.localizedDescription,
                      "physicalNativeUIAcceptance": false]
        }
    }
}

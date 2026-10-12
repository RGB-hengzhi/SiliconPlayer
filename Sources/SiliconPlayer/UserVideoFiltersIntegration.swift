import AppKit
import CMPV
import PlayerCore
import CryptoKit

extension PlayerModel {
    func configuredVideoFragments(settings s: PlaybackSettings, userFragments: [String]) -> [String] {
        let p = s.processing
        var filters: [String] = []
        if s.flipHorizontal { filters.append("hflip") }
        if s.flipVertical { filters.append("vflip") }
        if s.denoise > 0 { filters.append("hqdn3d=\(s.denoise)") }
        if p.cropWidth < 1 || p.cropHeight < 1 { filters.append("crop=trunc(iw*\(p.cropWidth)/2)*2:trunc(ih*\(p.cropHeight)/2)*2") }
        if AppCapabilities.current.profile == .full && p.stereoInput != "off" { filters.append("stereo3d=\(p.stereoInput):\(p.stereoOutput)") }
        if AppCapabilities.current.profile == .full && p.projection != "off" {
            let verticalFOV = atan(tan(p.fieldOfView * .pi / 360) * 9 / 16) * 360 / .pi
            filters.append("v360=input=\(p.projection):output=flat:w=1280:h=720:yaw=\(p.yaw):pitch=\(p.pitch):h_fov=\(p.fieldOfView):v_fov=\(verticalFOV)")
        }
        return filters + userFragments
    }

    /// Pure requested configuration; does not submit, queue or verify mpv work.
    func videoFilterConfiguration(settings: PlaybackSettings, userFragments: [String], assetFragments: [String] = []) -> (decoder: String, filter: String) {
        let filters = configuredVideoFragments(settings: settings, userFragments: userFragments) + assetFragments
        let decoder = filters.isEmpty ? settings.hardwareDecoder : (settings.hardwareDecoder == "no" ? "no" : "videotoolbox-copy")
        let filter = filters.isEmpty ? "" : "lavfi=[\(filters.joined(separator: ","))]"
        return (decoder, filter)
    }

    func applyVideoFilterProperties(settings: PlaybackSettings, userFragments: [String]) -> Int32 {
        guard !videoConfigurationClosing, !videoAssets.isExecutingConfiguration else { return MPV_ERROR_UNINITIALIZED.rawValue }
        let (decoder, filter) = videoFilterConfiguration(settings: settings, userFragments: userFragments, assetFragments: videoAssets.effectiveLUTFragments)
        let now = ProcessInfo.processInfo.systemUptime
        let changingDecoder = hasActiveVideoDecoder && string("hwdec") != decoder
        let mustWait = changingDecoder && (string("seeking") != "no" || !videoSeekBarrierReady(at: now))
        if mustWait, let pending = pendingVideoConfiguration,
           pending.epoch == videoConfigurationEpoch, pending.decoder == decoder, pending.filter == filter {
            // Equivalent repeats coalesce without extending the 1.5s deadline.
            // Zero here means accepted pending, not configured or rendered.
            return 0
        }
        pendingVideoConfiguration = nil
        videoConfigurationRequestID = UUID()
        if mustWait {
            pendingVideoConfiguration = PendingVideoConfiguration(requestID: videoConfigurationRequestID,
                epoch: videoConfigurationEpoch, decoder: decoder, filter: filter,
                submittedAt: now, renderedBefore: renderProgress.frames)
            return 0
        }
        return executeVideoConfiguration(decoder: decoder, filter: filter, requestID: videoConfigurationRequestID)
    }

    func recordVideoSeekBarrier(at time: TimeInterval, renderedBefore: UInt64, exactTarget: Double?) {
        guard hasActiveVideoDecoder else { videoSeekBarrier = nil; return }
        let rate = number("speed")
        videoSeekBarrier = VideoSeekBarrier(epoch: videoConfigurationEpoch, submittedAt: time,
            renderedBefore: renderedBefore, exactTarget: exactTarget?.isFinite == true ? exactTarget : nil,
            speed: rate.isFinite && rate > 0 ? rate : 1)
    }

    func cancelVideoConfigurationTransition() {
        videoAssets.mediaWillChange()
        // Invalidate the controller's completion token before a delayed
        // validator can report cancellation and attempt a rollback on another
        // media generation, or on a core that is already quitting.
        userVideoFilters.cancelPending(reason: "播放上下文已结束")
        videoFilterGeneration = UUID(); candidateVideoFilters = nil
        pendingVideoConfiguration = nil; videoSeekBarrier = nil
        videoConfigurationEpoch = UUID(); videoConfigurationRequestID = UUID()
        videoConfigurationResult = nil
    }

    func videoConfigurationTerminationSnapshot() -> [String: Any] {
        let file = Self.supportDirectory.appendingPathComponent("user-video-filters.json")
        let bytes = try? BoundedProfileFile.read(file, maximumBytes: UserVideoFilterStore.maximumBytes)
        return ["accepting": !videoConfigurationClosing, "pendingRequest": pendingVideoConfiguration?.requestID.uuidString ?? "",
                "candidateApplying": userVideoFilters.isApplying, "candidateFragments": candidateVideoFilters?.count ?? 0,
                "epoch": videoConfigurationEpoch.uuidString, "request": videoConfigurationRequestID.uuidString,
                "applyCount": videoConfigurationApplyCount, "configuredDecoder": string("hwdec"), "currentDecoder": string("hwdec-current"),
                "filterStoreSHA256": bytes.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? ""]
    }

    /// This reversible acceptance barrier precedes both AppKit exit replies.
    /// It does not send quit or alter the user's saved filter document.
    func beginVideoConfigurationTermination() -> [String: Any] {
        let before = videoConfigurationTerminationSnapshot()
        cancelVideoConfigurationTransition()
        videoConfigurationClosing = true
        videoAssets.beginTermination()
        return ["before": before, "after": videoConfigurationTerminationSnapshot()]
    }

    /// Only the AppKit cancellation branch before irreversible core quit may
    /// reopen this gate. Zero can mean queued restoration, not rendered success.
    @discardableResult
    func resumeVideoConfigurationAfterCancelledTermination(previouslyAccepting: Bool) -> Int32 {
        guard previouslyAccepting, videoConfigurationClosing, let handle else { return MPV_ERROR_UNINITIALIZED.rawValue }
        var paused: Int32 = 0
        guard mpv_get_property(handle, "pause", MPV_FORMAT_FLAG, &paused) >= 0 else { return MPV_ERROR_UNINITIALIZED.rawValue }
        cancelVideoConfigurationTransition()
        videoConfigurationClosing = false
        videoAssets.resumeAfterCancelledTermination()
        videoAssets.mediaLoaded()
        return applyVideoFilterProperties(settings: settings.sanitized(), userFragments: userVideoFilters.effectiveFragments)
    }

    func videoSeekBarrierReady(at now: TimeInterval) -> Bool {
        guard let barrier = videoSeekBarrier else { return true }
        guard barrier.epoch == videoConfigurationEpoch else { videoSeekBarrier = nil; return true }
        // seeking alone omits mpv's queued-but-not-executed seek. mpv 0.41
        // delays command seeks for up to .3s; retain a .35s quiet interval too.
        guard now - barrier.submittedAt >= 0.35, string("seeking") == "no",
              renderProgress.frames > barrier.renderedBefore else { return false }
        if let target = barrier.exactTarget {
            guard let handle else { return false }
            var position = Double.nan
            guard mpv_get_property(handle, "time-pos", MPV_FORMAT_DOUBLE, &position) >= 0,
                  position.isFinite else { return false }
            if flag("pause") {
                guard abs(position - target) <= 0.15 else { return false }
            } else {
                // Playing, including 4x, naturally moves beyond the requested
                // target while this barrier waits. Do not pause to inspect it.
                let rate = max(barrier.speed, max(0, number("speed")))
                let forward = max(0.2, (now - barrier.submittedAt) * rate + 0.2)
                guard position >= target - 0.15, position <= target + forward else { return false }
            }
        }
        videoSeekBarrier = nil
        return true
    }

    private var hasActiveVideoDecoder: Bool {
        loaded && (Int(string("vid")) ?? 0) > 0 && tracks.contains { $0.type == "video" }
    }

    private func videoFilterReadbackMatches(decoder: String, filter: String) -> Bool {
        guard string("hwdec") == decoder,
              let rows = jsonProperty("vf") as? [[String: Any]] else { return false }
        if filter.isEmpty { return rows.isEmpty }
        guard filter.hasPrefix("lavfi=["), filter.hasSuffix("]"), rows.count == 1,
              let row = rows.first, row["name"] as? String == "lavfi",
              (row["enabled"] as? Bool ?? true),
              let params = row["params"] as? [String: Any] else { return false }
        return params["graph"] as? String == String(filter.dropFirst(7).dropLast())
    }

    private func executeVideoConfiguration(decoder: String, filter: String, requestID: UUID) -> Int32 {
        let frames = renderProgress.frames
        let submittedAt = ProcessInfo.processInfo.systemUptime
        let effectiveUnchanged = videoFilterReadbackMatches(decoder: decoder, filter: filter)
        // A paused graph change also needs a source-frame refresh when hwdec
        // stays VT-COPY. Reuse the existing real relative+exact seek contract.
        let refresh = hasActiveVideoDecoder && flag("seekable") && !effectiveUnchanged
        let assignments: [(name: String, value: String)] = filter.isEmpty
            ? [("vf", ""), ("hwdec", decoder)] : [("hwdec", decoder), ("vf", filter)]
        let status: Int32
        if videoAssets.effectiveLUTFragments.isEmpty {
            // Preserve the original raw checked batch for empty assets.
            status = executeCheckedPropertyBatch(assignments, refreshVideo: refresh)
        } else if filter.hasPrefix("lavfi=["), filter.hasSuffix("]") {
            // This is our pure factory wrapper, not a mpv file-list parser.
            let graph = String(filter.dropFirst(7).dropLast())
            status = executeManagedAssetVideoConfiguration(decoder: decoder, graph: graph, refreshVideo: refresh)
        } else {
            status = MPV_ERROR_INVALID_PARAMETER.rawValue
        }
        if status >= 0, refresh {
            // The internal relative exact refresh bypasses executeCommand.
            // Its delayed execution is still an owned seek window; do not
            // infer or rewrite an unknown pending target from time-pos.
            recordVideoSeekBarrier(at: submittedAt, renderedBefore: frames, exactTarget: nil)
        }
        videoConfigurationResult = VideoConfigurationResult(requestID: requestID, epoch: videoConfigurationEpoch,
            status: status, executed: true, renderedBefore: frames, effectiveUnchanged: effectiveUnchanged)
        if status >= 0 { videoConfigurationApplyCount &+= 1 }
        return status
    }

    func consumePendingVideoConfiguration() {
        let now = ProcessInfo.processInfo.systemUptime
        guard let pending = pendingVideoConfiguration else {
            if loaded { _ = videoSeekBarrierReady(at: now) }
            return
        }
        guard pending.epoch == videoConfigurationEpoch, pending.requestID == videoConfigurationRequestID,
              loaded, !isLoading, !profileStoresBlocked, !videoConfigurationClosing else {
            pendingVideoConfiguration = nil
            return
        }
        if !hasActiveVideoDecoder {
            pendingVideoConfiguration = nil
            _ = executeVideoConfiguration(decoder: pending.decoder, filter: pending.filter, requestID: pending.requestID)
            return
        }
        guard now - pending.submittedAt < 1.5 else {
            pendingVideoConfiguration = nil
            videoConfigurationResult = VideoConfigurationResult(requestID: pending.requestID, epoch: pending.epoch,
                status: MPV_ERROR_COMMAND.rawValue, executed: false, renderedBefore: renderProgress.frames, effectiveUnchanged: false)
            videoFilterFailure = "定位尚未稳定，视频处理切换已取消，请稍后重试"
            error = videoFilterFailure
            return
        }
        guard now - pending.submittedAt >= 0.35, string("seeking") == "no",
              renderProgress.frames > pending.renderedBefore, videoSeekBarrierReady(at: now) else { return }
        pendingVideoConfiguration = nil
        let status = executeVideoConfiguration(decoder: pending.decoder, filter: pending.filter, requestID: pending.requestID)
        if status < 0 {
            videoFilterFailure = "视频处理设置失败：\(String(cString: mpv_error_string(status)))"
            error = videoFilterFailure
        }
    }

    func installUserVideoFilters() {
        userVideoFilters.install { [weak self] candidate, completion in
            guard let self else { completion(.failure(CocoaError(.userCancelled))); return }
            guard !self.profileStoresBlocked, !self.videoConfigurationClosing, !self.videoAssets.isApplying else { completion(.failure(CocoaError(.userCancelled))); return }
            self.validateVideoFilterCandidate(candidate, completion: completion)
        }
        applySettings()
    }

    private func validateVideoFilterCandidate(_ candidate: UserVideoFilterChain, completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        do {
            let fragments = try candidate.lavfiFragments()
            let token = UUID(); videoFilterGeneration = token
            videoFilterFailure = nil
            candidateVideoFilters = fragments
            let previousError = error
            let status = applyVideoFilterProperties(settings: settings.sanitized(), userFragments: fragments)
            let configurationRequest = videoConfigurationRequestID
            let epoch = videoConfigurationEpoch
            guard status >= 0 else {
                candidateVideoFilters = nil
                completion(.failure(NSError(domain: "SiliconPlayer.VideoFilters", code: Int(status), userInfo: [NSLocalizedDescriptionKey: String(cString: mpv_error_string(status))])))
                return
            }
            // Without an active video, this verifies the configuration and mpv
            // property parsing. Runtime support is checked on actual playback.
            guard loaded && tracks.contains(where: { $0.type == "video" }) else {
                candidateVideoFilters = nil; completion(.success(())); return
            }
            guard let expectedHandle = handle, let expectedItem = mediaPreferences.boundItemID,
                  mediaPreferences.token == mediaPreferenceToken,
                  let expectedRenderer = videoHost?.video.rendererIdentity else {
                candidateVideoFilters = nil
                completion(.failure(CocoaError(.userCancelled))); return
            }
            let source = currentURL, loadToken = mediaPreferenceToken
            let capturedSettings = settings.sanitized(), capturedLUT = videoAssets.effectiveLUTFragments
            let expectedConfiguration = videoFilterConfiguration(settings: capturedSettings,
                userFragments: fragments, assetFragments: capturedLUT)
            Task { @MainActor [weak self] in
                guard let self else { completion(.failure(CocoaError(.userCancelled))); return }
                let metalView = self.videoHost?.video as? MPVMetalVideoView
                defer {
                    self.renderProgress.retireConfigurationDrawable(ticket: configurationRequest)
                    metalView?.retireConfigurationRedraw(ticket: configurationRequest)
                }
                @MainActor func fresh() -> Bool {
                    self.videoFilterGeneration == token && self.currentURL == source && self.loaded && !self.isLoading
                        && self.handle == expectedHandle && self.mediaPreferenceToken == loadToken
                        && self.mediaPreferences.token == loadToken && self.mediaPreferences.boundItemID == expectedItem
                        && self.videoHost?.video.rendererIdentity == expectedRenderer
                        && self.videoConfigurationEpoch == epoch && self.videoConfigurationRequestID == configurationRequest
                        && !self.videoConfigurationClosing && !self.profileStoresBlocked
                        && self.settings.sanitized() == capturedSettings && self.videoAssets.effectiveLUTFragments == capturedLUT
                }
                var accepted = false, requestedAt: TimeInterval?
                for _ in 0..<12 {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    guard fresh() else { break }
                    guard self.drainCoreEventsToEmpty(expectedHandle: expectedHandle, maximum: 512), fresh() else { continue }
                    if self.error != nil && self.error != previousError { break }
                    if self.videoFilterFailure != nil { break }
                    guard let result = self.videoConfigurationResult, result.requestID == configurationRequest,
                          result.epoch == epoch, result.executed, result.status >= 0,
                          self.pendingVideoConfiguration == nil, self.string("seeking") == "no",
                          self.videoSeekBarrierReady(at: ProcessInfo.processInfo.systemUptime) else { continue }
                    if requestedAt == nil {
                        let requestTime = ProcessInfo.processInfo.systemUptime
                        guard self.videoHost?.video.requestConfigurationRedraw(ticket: configurationRequest) == true else { break }
                        requestedAt = requestTime
                    }
                    let drawable: VideoAssetDrawableProof?
                    if let metalView { drawable = metalView.configurationDrawable(ticket: configurationRequest).map(VideoAssetDrawableProof.metal) }
                    else { drawable = self.renderProgress.configurationDrawable(ticket: configurationRequest).map(VideoAssetDrawableProof.openGL) }
                    guard let requestedAt, drawable?.ready(ticket: configurationRequest,
                              renderer: expectedRenderer, requestedAt: requestedAt) == true,
                          result.effectiveUnchanged || self.renderProgress.frames > result.renderedBefore,
                          self.videoFilterReadbackMatches(decoder: expectedConfiguration.decoder, filter: expectedConfiguration.filter),
                          let output = self.jsonProperty("video-out-params") as? [String: Any],
                          (output["w"] as? Int ?? 0) > 0, (output["h"] as? Int ?? 0) > 0 else { continue }
                    // Consume errors produced by the reads/draw, then recheck
                    // exact current identity and options before disk commit.
                    guard self.drainCoreEventsToEmpty(expectedHandle: expectedHandle, maximum: 512), fresh(),
                          self.videoFilterFailure == nil, self.error == nil || self.error == previousError,
                          self.videoFilterReadbackMatches(decoder: expectedConfiguration.decoder, filter: expectedConfiguration.filter) else { continue }
                    accepted = true; break
                }
                if self.videoFilterGeneration == token { self.candidateVideoFilters = nil }
                if accepted { completion(.success(())) }
                else { completion(.failure(NSError(domain: "SiliconPlayer.VideoFilters", code: 1, userInfo: [NSLocalizedDescriptionKey: "滤镜未能产生有效视频，或验证期间已停止/切换媒体，已恢复原设置"]))) }
            }
        } catch { candidateVideoFilters = nil; completion(.failure(error)) }
    }
}

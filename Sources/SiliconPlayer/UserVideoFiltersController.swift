import Foundation
import Combine
import PlayerCore

/// The engine supplies a bounded asynchronous application/verification hook.
/// The candidate remains uncommitted until that hook and atomic saving succeed.
@MainActor
final class UserVideoFiltersController: ObservableObject {
    typealias Apply = @MainActor (UserVideoFilterChain, @escaping @MainActor (Result<Void, Error>) -> Void) -> Void
    @Published private(set) var chain = UserVideoFilterChain()
    @Published private(set) var isApplying = false
    @Published private(set) var isReady = false
    @Published private(set) var errorText: String?
    @Published private(set) var runtimeSuspended = false
    private let store: UserVideoFilterStore
    private var apply: Apply?
    private var generation = UUID()

    init(fileURL: URL) {
        store = UserVideoFilterStore(fileURL: fileURL)
        do { chain = try store.load() }
        catch { errorText = "视频滤镜设置读取失败，原文件已保留：\(error.localizedDescription)" }
    }
    var effectiveFragments: [String] {
        runtimeSuspended ? [] : (try? chain.lavfiFragments()) ?? []
    }
    func install(apply: @escaping Apply) { self.apply = apply; isReady = true }
    func clearError() { errorText = nil }
    /// The profile coordinator has already committed the complete set of files.
    /// Adopt its validated document without publishing this store a second time;
    /// the host reapplies the complete runtime configuration after all adoption.
    func adoptCommittedProfile(_ candidate: UserVideoFilterChain) throws {
        _ = try candidate.validated()
        generation = UUID(); isApplying = false
        chain = candidate; runtimeSuspended = false; errorText = nil
    }
    func cancelPending(reason: String) {
        guard isApplying else { return }
        generation = UUID(); isApplying = false
        errorText = "\(reason)，未完成的滤镜修改未保存"
    }
    func resumeForNewMedia() {
        cancelPending(reason: "媒体已切换")
        runtimeSuspended = false
    }
    /// A structurally valid chain can fail on a new media's dimensions/format.
    /// Keep the user's last accepted document; omit it for this media only.
    func suspendForCurrentMedia(reason: String) {
        cancelPending(reason: "当前媒体的滤镜已停用")
        runtimeSuspended = true
        errorText = "当前媒体已停用用户滤镜：\(reason)"
    }
    @discardableResult func add(_ kind: UserVideoFilterKind) -> UUID? {
        guard !isApplying else { return nil }
        let filter = UserVideoFilter(kind: kind)
        var candidate = chain; candidate.filters.append(filter)
        return commit(candidate) ? filter.id : nil
    }
    func remove(id: UUID) {
        guard chain.filters.contains(where: { $0.id == id }) else { return }
        var candidate = chain; candidate.filters.removeAll { $0.id == id }; _ = commit(candidate)
    }
    func setEnabled(id: UUID, enabled: Bool) {
        guard let index = chain.filters.firstIndex(where: { $0.id == id }) else { return }
        var candidate = chain; candidate.filters[index].enabled = enabled; _ = commit(candidate)
    }
    func move(id: UUID, to index: Int) {
        var candidate = chain
        do { try candidate.move(id: id, to: index); _ = commit(candidate) }
        catch { errorText = error.localizedDescription }
    }
    func replace(_ entry: UserVideoFilter) {
        guard let index = chain.filters.firstIndex(where: { $0.id == entry.id }) else {
            errorText = "要修改的滤镜已移除"; return
        }
        var candidate = chain; candidate.filters[index] = entry; _ = commit(candidate)
    }
    func removeAll() { _ = commit(UserVideoFilterChain()) }
    func retryCurrentChain() { _ = commit(chain, force: true) }

    @discardableResult func commit(_ candidate: UserVideoFilterChain, force: Bool = false) -> Bool {
        guard !isApplying else { return false }
        do { _ = try candidate.validated() }
        catch { errorText = error.localizedDescription; return false }
        guard let apply else { errorText = "播放引擎尚未就绪，滤镜未保存"; return false }
        if candidate == chain && !force && !runtimeSuspended { return true }
        let previous = chain
        let wasSuspended = runtimeSuspended
        let previousEffective = wasSuspended ? UserVideoFilterChain() : previous
        let token = UUID(); generation = token
        isApplying = true; errorText = nil
        apply(candidate) { [weak self] result in
            guard let self, self.generation == token else { return }
            switch result {
            case .success:
                do {
                    try self.store.save(candidate)
                    self.chain = candidate; self.runtimeSuspended = false
                    self.finish(token: token, error: nil)
                } catch {
                    self.rollback(previousEffective, wasSuspended: wasSuspended, token: token,
                                  reason: "滤镜设置保存失败：\(error.localizedDescription)")
                }
            case .failure(let error):
                self.rollback(previousEffective, wasSuspended: wasSuspended, token: token,
                              reason: "滤镜未应用，已保留上次设置：\(error.localizedDescription)")
            }
        }
        return true
    }
    private func rollback(_ previous: UserVideoFilterChain, wasSuspended: Bool, token: UUID, reason: String) {
        guard let apply else { finish(token: token, error: reason); return }
        apply(previous) { [weak self] result in
            guard let self, self.generation == token else { return }
            switch result {
            case .success:
                self.runtimeSuspended = wasSuspended
                self.finish(token: token, error: reason)
            case .failure(let error):
                // If even the former chain is incompatible, try the baseline.
                // Its failure is also visible; no candidate is persisted.
                self.runtimeSuspended = true
                apply(UserVideoFilterChain()) { [weak self] baseline in
                    guard let self, self.generation == token else { return }
                    var message = "\(reason)；恢复旧链失败，已停用当前媒体的用户滤镜：\(error.localizedDescription)"
                    if case .failure(let lastError) = baseline { message += "；恢复基础画面失败：\(lastError.localizedDescription)" }
                    self.finish(token: token, error: message)
                }
            }
        }
    }
    private func finish(token: UUID, error: String?) {
        guard generation == token else { return }
        generation = UUID() // Ignore duplicate/late engine completions.
        isApplying = false; errorText = error
    }
}

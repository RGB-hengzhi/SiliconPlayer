import Combine
import Foundation

/// Settings panels do not display the position, duration or playback counters.
/// Coalesce only their displayed model changes onto the main run loop.
@MainActor
final class AdvancedPanelObservation: ObservableObject {
    private var subscriptions = Set<AnyCancellable>()
    private var updateQueued = false

    init(player: PlayerModel, processingOnly: Bool = false) {
        watch(player.$settings)
        watch(player.$loaded)
        if !processingOnly {
            watch(player.$tracks)
            watch(player.$subtitleID)
            watch(player.$subtitleDelay)
            watch(player.$audioDevices.map { devices in
                devices.map { [$0.id, $0.name, $0.description] }
            })
            watch(player.$screenshotBusy)
            watch(player.$screenshotStatus)
        }
    }

    private func watch<P: Publisher>(_ publisher: P)
        where P.Output: Equatable, P.Failure == Never {
        publisher.removeDuplicates().dropFirst().sink { [weak self] _ in
            self?.queueUpdate()
        }.store(in: &subscriptions)
    }

    private func queueUpdate() {
        guard !updateQueued else { return }
        updateQueued = true
        // @Published emits before the property's assignment. Read the model
        // in the subsequent view update, after all same-turn writes finish.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateQueued = false
            self.objectWillChange.send()
        }
    }
}

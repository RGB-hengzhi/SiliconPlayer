import Foundation

@MainActor
extension EPGService {
    convenience init(storageDirectory: URL) {
        self.init(channels: [], transport: ProductionEPGSourceTransport(),
                  logoCache: EPGLogoCache(directory: storageDirectory.appendingPathComponent("EPGLogos", isDirectory: true)),
                  preferences: EPGPreferencesStore(file: storageDirectory.appendingPathComponent("epg-preferences-v1.json")))
    }
    convenience init() { self.init(storageDirectory: PlayerModel.supportDirectory) }
}

import Combine
import Foundation

struct LiveTranscriptionPreferences {
    let defaults: UserDefaults

    /// Providers the user added, in the order they were added. Unknown stored values are skipped
    /// so a downgrade or a retired vendor never breaks the list.
    var addedProviders: [LiveTranscriptionProviderID] {
        get {
            var seen = Set<LiveTranscriptionProviderID>()
            return (self.defaults.stringArray(forKey: "LiveTranscriptionProviders") ?? [])
                .compactMap(LiveTranscriptionProviderID.init(rawValue:))
                .filter { seen.insert($0).inserted }
        }
        set {
            var seen = Set<LiveTranscriptionProviderID>()
            self.defaults.set(newValue.filter { seen.insert($0).inserted }.map(\.rawValue), forKey: "LiveTranscriptionProviders")
        }
    }

    var activeProvider: LiveTranscriptionProviderID? {
        get { self.defaults.string(forKey: "LiveTranscriptionActiveProvider").flatMap(LiveTranscriptionProviderID.init(rawValue:)) }
        set { self.defaults.set(newValue?.rawValue, forKey: "LiveTranscriptionActiveProvider") }
    }

    func modelID(for provider: LiveTranscriptionProviderID) -> String {
        let info = LiveTranscriptionCatalog.info(for: provider)
        let stored = self.defaults.string(forKey: "LiveTranscriptionModel.\(provider.rawValue)") ?? ""
        return info.models.contains { $0.id == stored } ? stored : info.defaultModelID
    }

    mutating func setModelID(_ modelID: String, for provider: LiveTranscriptionProviderID) {
        guard LiveTranscriptionCatalog.info(for: provider).models.contains(where: { $0.id == modelID }) else { return }
        self.defaults.set(modelID, forKey: "LiveTranscriptionModel.\(provider.rawValue)")
    }
}

extension SettingsStore {
    func liveTranscriptionAPIKey(for provider: LiveTranscriptionProviderID) -> String {
        (try? KeychainService.shared.fetchKey(for: provider.keychainID)) ?? ""
    }

    func saveLiveTranscriptionAPIKey(_ value: String, for provider: LiveTranscriptionProviderID) throws {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            try KeychainService.shared.deleteKey(for: provider.keychainID)
        } else {
            try KeychainService.shared.storeKey(key, for: provider.keychainID)
        }
        self.objectWillChange.send()
    }

    /// The live provider dictation uses, or nil when Live cloud is not the effective engine.
    var activeLiveProvider: LiveTranscriptionProviderID? {
        Self.usableLiveProvider(
            storedSource: CloudTranscriptionPreferences(defaults: .standard).source,
            activeProvider: LiveTranscriptionPreferences(defaults: .standard).activeProvider,
            apiKey: { self.liveTranscriptionAPIKey(for: $0) }
        )
    }

    /// The active live provider when Live cloud is the stored source and that provider has a saved key.
    static func usableLiveProvider(
        storedSource: SpeechExecutionSource,
        activeProvider: LiveTranscriptionProviderID?,
        apiKey: (LiveTranscriptionProviderID) -> String
    ) -> LiveTranscriptionProviderID? {
        guard storedSource == .liveCloud,
              let provider = activeProvider,
              !apiKey(provider).isEmpty
        else { return nil }
        return provider
    }

    var usesLiveCloudDictation: Bool { self.activeLiveProvider != nil }

    /// True when dictation audio leaves the Mac. Privacy wording such as "ON-DEVICE" must use this.
    var sendsDictationAudioOffDevice: Bool { self.usesCloudTranscription || self.usesLiveCloudDictation }

    var activeVoiceEngineDescription: String {
        if let provider = self.activeLiveProvider { return "\(LiveTranscriptionCatalog.info(for: provider).name) · Live cloud" }
        return self.speechExecutionSource.displayName
    }

    var liveDictationConfiguration: LiveTranscriptionConfiguration? {
        guard let provider = self.activeLiveProvider else { return nil }
        let cloud = CloudTranscriptionPreferences(defaults: .standard)
        return LiveTranscriptionConfiguration(
            provider: provider,
            modelID: LiveTranscriptionPreferences(defaults: .standard).modelID(for: provider),
            languageCode: cloud.dictationLanguageCode,
            languageHints: [cloud.primaryLanguageCode, cloud.secondaryLanguageCode].compactMap { $0 }
        )
    }
}

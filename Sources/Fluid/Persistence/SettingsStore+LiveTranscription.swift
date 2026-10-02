import Combine
import Foundation

struct LiveTranscriptionPreferences {
    let defaults: UserDefaults

    /// Providers the user added, in the order they were added. Saving a provider's key adds it and removing
    /// the key removes it (`SettingsStore.setProviderAPIKey`). Unknown stored values are skipped so a
    /// downgrade or a retired vendor never breaks the list.
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

    /// The chosen model, otherwise the provider's default. A stored model the catalog no longer lists stays
    /// chosen and is still sent, so an update never switches a user's model silently; the picker shows it
    /// as no longer listed.
    func modelID(for provider: LiveTranscriptionProviderID) -> String {
        let stored = self.defaults.string(forKey: "LiveTranscriptionModel.\(provider.rawValue)")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? LiveTranscriptionCatalog.info(for: provider).defaultModelID : stored
    }

    mutating func setModelID(_ modelID: String, for provider: LiveTranscriptionProviderID) {
        guard LiveTranscriptionCatalog.info(for: provider).models.contains(where: { $0.id == modelID }) else { return }
        self.defaults.set(modelID, forKey: "LiveTranscriptionModel.\(provider.rawValue)")
    }

    /// Forgets the chosen model, so a provider added again starts from its default.
    mutating func removeModelChoice(for provider: LiveTranscriptionProviderID) {
        self.defaults.removeObject(forKey: "LiveTranscriptionModel.\(provider.rawValue)")
    }
}

extension SettingsStore {
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

    /// The provider Live cloud was activated with, even when its key has since been removed. Readiness
    /// surfaces use it to say which key is missing; dictation itself uses `activeLiveProvider`.
    var storedLiveProvider: LiveTranscriptionProviderID? {
        Self.storedLiveProvider(in: .standard)
    }

    static func storedLiveProvider(in defaults: UserDefaults) -> LiveTranscriptionProviderID? {
        guard CloudTranscriptionPreferences(defaults: defaults).source == .liveCloud else { return nil }
        return LiveTranscriptionPreferences(defaults: defaults).activeProvider
    }

    /// Leaves Live cloud without touching keys or the added providers. Callers set the new source.
    func clearActiveLiveProvider() {
        var preferences = LiveTranscriptionPreferences(defaults: .standard)
        preferences.activeProvider = nil
        self.objectWillChange.send()
    }

    /// Nil when the language is usable with the active engine; otherwise the provider name that lacks it.
    func liveProviderLackingLanguage(_ code: String) -> String? {
        guard let provider = self.activeLiveProvider else { return nil }
        let info = LiveTranscriptionCatalog.info(for: provider)
        let modelID = LiveTranscriptionPreferences(defaults: .standard).modelID(for: provider)
        return info.supports(languageCode: code, modelID: modelID) ? nil : info.name
    }

    /// True when the provider needs one set language (Speechmatics) and no Primary language is set (UX §E4).
    func liveProviderNeedsPrimaryLanguage(_ provider: LiveTranscriptionProviderID) -> Bool {
        LiveTranscriptionCatalog.info(for: provider).needsPrimaryLanguage(primaryLanguageCode: self.cloudTranscriptionPrimaryLanguageCode)
    }

    /// True when the active live provider cannot detect the language, so the overlay chip offers no automatic choice.
    var activeLiveProviderNeedsSetLanguage: Bool {
        self.activeLiveProvider.map { !LiveTranscriptionCatalog.info(for: $0).detectsLanguageAutomatically } ?? false
    }

    /// The overlay's language chip: shown for Cloud and Live cloud once a Primary language is set.
    var showsDictationLanguageChip: Bool {
        (self.usesCloudTranscription || self.usesLiveCloudDictation) && self.cloudTranscriptionPrimaryLanguageCode != nil
    }

    /// The overlay style menu's engine header for the next dictation. During a recording the header
    /// comes from `ASRService.dictationEngineBadge`, which names the engine that receives its audio.
    var dictationEngineBadge: String {
        Self.dictationEngineBadge(
            cloudProviderName: self.usesCloudTranscription ? self.cloudTranscriptionProviderName : nil,
            liveProvider: self.activeLiveProvider
        )
    }

    /// "ON-DEVICE", "<VENDOR> · CLOUD" or "<VENDOR> · LIVE". Never "ON-DEVICE" while audio leaves the Mac.
    static func dictationEngineBadge(cloudProviderName: String?, liveProvider: LiveTranscriptionProviderID?) -> String {
        if let cloudProviderName { return "\(cloudProviderName.uppercased()) · CLOUD" }
        if let liveProvider { return "\(LiveTranscriptionCatalog.info(for: liveProvider).name.uppercased()) · LIVE" }
        return "ON-DEVICE"
    }

    /// True when dictation audio leaves the Mac. Privacy wording such as "ON-DEVICE" must use this.
    var sendsDictationAudioOffDevice: Bool { self.usesCloudTranscription || self.usesLiveCloudDictation }

    var liveDictationConfiguration: LiveTranscriptionConfiguration? {
        self.activeLiveProvider.map { self.liveDictationConfiguration(for: $0) }
    }

    /// The configuration a dictation with this provider uses: its model and the shared dictation languages.
    func liveDictationConfiguration(for provider: LiveTranscriptionProviderID) -> LiveTranscriptionConfiguration {
        let cloud = CloudTranscriptionPreferences(defaults: .standard)
        return LiveTranscriptionConfiguration(
            provider: provider,
            modelID: LiveTranscriptionPreferences(defaults: .standard).modelID(for: provider),
            languageCode: cloud.dictationLanguageCode,
            languageHints: [cloud.primaryLanguageCode, cloud.secondaryLanguageCode].compactMap { $0 }
        )
    }
}

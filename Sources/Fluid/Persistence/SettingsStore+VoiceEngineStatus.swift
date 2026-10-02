import Foundation

/// What Voice Engine says about the engine dictation uses (VE-2): the header text, the provider whose
/// key is missing, and the tab the page browses when it appears.
struct VoiceEngineStatus: Equatable {
    let description: String
    /// The provider whose missing key the header names; its `Open AI Providers` button opens it.
    let missingKeyProviderID: String?
    /// Live cloud while a live provider is selected without its key, even though dictation runs on Local.
    let tab: SpeechExecutionSource

    /// - Parameters:
    ///   - storedSource: the stored engine, before a keyless Live cloud choice reads as Local.
    ///   - storedLiveProvider: the live provider Live cloud was activated with, if any.
    ///   - speechKey: the speech key of a registry provider.
    static func make(
        storedSource: SpeechExecutionSource,
        cloudProviderID: String,
        storedLiveProvider: LiveTranscriptionProviderID?,
        speechKey: (String) -> String
    ) -> VoiceEngineStatus {
        switch storedSource {
        case .local:
            return VoiceEngineStatus(description: "Local", missingKeyProviderID: nil, tab: .local)
        case .cloud:
            let name = Self.providerName(cloudProviderID)
            guard !speechKey(cloudProviderID).isEmpty else {
                // Cloud has no fallback: dictation fails with the missing-key error until a key is saved.
                return VoiceEngineStatus(description: "\(name) · Cloud. API key missing.", missingKeyProviderID: cloudProviderID, tab: .cloud)
            }
            return VoiceEngineStatus(description: "\(name) · Cloud", missingKeyProviderID: nil, tab: .cloud)
        case .liveCloud:
            guard let live = storedLiveProvider else {
                return VoiceEngineStatus(description: "Local", missingKeyProviderID: nil, tab: .local)
            }
            let providerID = ProviderRegistry.providerID(for: live)
            let name = LiveTranscriptionCatalog.info(for: live).name
            guard !speechKey(providerID).isEmpty else {
                // `SpeechExecutionSource.effective` runs dictation on Local meanwhile.
                return VoiceEngineStatus(
                    description: "Local. \(name) is selected for Live cloud but its API key is missing.",
                    missingKeyProviderID: providerID,
                    tab: .liveCloud
                )
            }
            return VoiceEngineStatus(description: "\(name) · Live cloud", missingKeyProviderID: nil, tab: .liveCloud)
        }
    }

    /// "Soniox key required" while the stored Cloud or Live cloud provider has no key; otherwise nil.
    var missingKeyMessage: String? {
        self.missingKeyProviderID.map { "\(Self.providerName($0)) key required" }
    }

    static func providerName(_ providerID: String) -> String {
        ProviderRegistry.descriptor(for: providerID)?.name ?? providerID
    }
}

extension SettingsStore {
    var voiceEngineStatus: VoiceEngineStatus {
        VoiceEngineStatus.make(
            storedSource: CloudTranscriptionPreferences(defaults: .standard).source,
            cloudProviderID: self.cloudTranscriptionProviderID,
            storedLiveProvider: self.storedLiveProvider,
            speechKey: { self.speechAPIKey(for: $0) }
        )
    }

    /// The header of the Voice Engine page: "Local", "OpenRouter · Cloud" or "Soniox · Live cloud", or a
    /// missing-key state (VE-2).
    var activeVoiceEngineDescription: String {
        self.voiceEngineStatus.description
    }

    /// "OpenRouter key required" while the stored Cloud or Live cloud provider has no key; otherwise nil.
    var missingVoiceEngineKeyMessage: String? {
        self.voiceEngineStatus.missingKeyMessage
    }

    /// The name of the provider the Cloud engine uses.
    var cloudTranscriptionProviderName: String {
        VoiceEngineStatus.providerName(self.cloudTranscriptionProviderID)
    }
}

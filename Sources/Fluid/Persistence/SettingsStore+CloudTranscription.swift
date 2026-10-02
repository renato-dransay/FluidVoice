import Combine
import Foundation

nonisolated enum SpeechExecutionSource: String, CaseIterable, Identifiable, Sendable {
    case local
    /// Audio is uploaded after recording stops. The raw value predates other cloud providers and is kept.
    case cloud = "openRouter"
    case liveCloud

    var id: String { self.rawValue }
    var displayName: String {
        switch self {
        case .local: "Local"
        case .cloud: "Cloud"
        case .liveCloud: "Live cloud"
        }
    }

    /// The engine dictation really uses. A stored Live cloud choice without a usable live provider
    /// reads as Local; every other stored value is kept as is.
    static func effective(stored: SpeechExecutionSource, usableLiveProvider: LiveTranscriptionProviderID?) -> SpeechExecutionSource {
        stored == .liveCloud && usableLiveProvider == nil ? .local : stored
    }
}

struct CloudTranscriptionPreferences {
    static let defaultProviderID = CloudTranscriptionCatalog.openRouterID

    let defaults: UserDefaults

    var source: SpeechExecutionSource {
        get { SpeechExecutionSource(rawValue: self.defaults.string(forKey: "SpeechExecutionSource") ?? "") ?? .local }
        set { self.defaults.set(newValue.rawValue, forKey: "SpeechExecutionSource") }
    }

    /// The provider the Cloud engine uses. OpenRouter until another provider is chosen.
    var providerID: String {
        get {
            let stored = self.defaults.string(forKey: "CloudTranscriptionProvider")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return stored.isEmpty ? Self.defaultProviderID : stored
        }
        set { self.defaults.set(newValue, forKey: "CloudTranscriptionProvider") }
    }

    /// OpenRouter's speech model, under the key it always had.
    var modelID: String {
        get { self.modelID(for: Self.defaultProviderID) }
        set { self.setModelID(newValue, for: Self.defaultProviderID) }
    }

    /// Where a provider's speech model is stored: `CloudTranscriptionModel` for OpenRouter, as before, and
    /// `CloudTranscriptionModel.<providerID>` for the others.
    static func modelDefaultsKey(for providerID: String) -> String {
        providerID == self.defaultProviderID ? "CloudTranscriptionModel" : "CloudTranscriptionModel.\(providerID)"
    }

    /// The provider's chosen speech model when its catalog still offers it, otherwise its default model.
    /// Empty for a provider without a catalog.
    func modelID(for providerID: String) -> String {
        let stored = self.defaults.string(forKey: Self.modelDefaultsKey(for: providerID)) ?? ""
        if CloudTranscriptionCatalog.models(for: providerID).contains(where: { $0.id == stored }) { return stored }
        return CloudTranscriptionCatalog.defaultModelID(for: providerID) ?? ""
    }

    /// Ignores a model the provider's catalog does not offer.
    mutating func setModelID(_ modelID: String, for providerID: String) {
        guard CloudTranscriptionCatalog.models(for: providerID).contains(where: { $0.id == modelID }) else { return }
        self.defaults.set(modelID, forKey: Self.modelDefaultsKey(for: providerID))
    }

    var primaryLanguageCode: String? {
        get {
            // Preserve a former manual selection as an optional hint, never as a forced language.
            Self.validLanguageCode(self.defaults.string(forKey: "CloudTranscriptionPrimaryLanguage")
                ?? self.defaults.string(forKey: "CloudTranscriptionLanguage"))
        }
        set {
            guard newValue == nil || Self.validLanguageCode(newValue) != nil else { return }
            let code = Self.validLanguageCode(newValue)
            let previousSecondary = self.secondaryLanguageCode
            self.defaults.set(code ?? "none", forKey: "CloudTranscriptionPrimaryLanguage")
            if code == nil || code == previousSecondary {
                self.defaults.set("none", forKey: "CloudTranscriptionSecondaryLanguage")
            }
        }
    }

    var secondaryLanguageCode: String? {
        get {
            guard let primary = self.primaryLanguageCode,
                  let secondary = Self.validLanguageCode(self.defaults.string(forKey: "CloudTranscriptionSecondaryLanguage")),
                  secondary != primary else { return nil }
            return secondary
        }
        set {
            guard newValue == nil || Self.validLanguageCode(newValue) != nil else { return }
            let code = Self.validLanguageCode(newValue)
            guard code == nil || (self.primaryLanguageCode != nil && code != self.primaryLanguageCode) else { return }
            self.defaults.set(code ?? "none", forKey: "CloudTranscriptionSecondaryLanguage")
        }
    }

    /// An absent or unavailable choice keeps automatic detection. A user may
    /// explicitly choose a configured language during recording.
    var dictationLanguageCode: String? {
        get {
            let stored = self.defaults.string(forKey: "CloudDictationLanguageSelection")
            if stored == "auto" { return nil }
            let primary = self.primaryLanguageCode
            if let code = Self.validLanguageCode(stored), code == primary || code == self.secondaryLanguageCode {
                return code
            }
            return nil
        }
        set {
            guard newValue == nil || (newValue == self.primaryLanguageCode || newValue == self.secondaryLanguageCode) else { return }
            self.defaults.set(newValue ?? "auto", forKey: "CloudDictationLanguageSelection")
        }
    }

    /// Automatic, or a model the user picked. An absent or withdrawn model reads as Automatic.
    var dictationModelSelection: String {
        get {
            let stored = self.defaults.string(forKey: "CloudDictationModel") ?? ""
            return CloudAudioDictationModel.isListed(stored) ? stored : CloudAudioDictationModel.automaticID
        }
        set {
            guard newValue == CloudAudioDictationModel.automaticID || CloudAudioDictationModel.isListed(newValue) else { return }
            self.defaults.set(newValue, forKey: "CloudDictationModel")
        }
    }

    /// The model dictation sends audio to. Automatic follows the OpenRouter model selected in AI
    /// Providers when that model accepts audio.
    func dictationModelID(inheriting providerModel: String?) -> String {
        let selection = self.dictationModelSelection
        return selection == CloudAudioDictationModel.automaticID
            ? CloudAudioDictationModel.automaticModelID(inheriting: providerModel) : selection
    }

    /// Imported files, voice commands and the local API: the active Cloud provider and its speech model.
    var configuration: CloudTranscriptionConfiguration {
        let providerID = self.providerID
        return CloudTranscriptionConfiguration(
            providerID: providerID,
            modelID: self.modelID(for: providerID),
            primaryLanguageCode: self.primaryLanguageCode,
            secondaryLanguageCode: self.secondaryLanguageCode
        )
    }

    var dictationConfiguration: CloudTranscriptionConfiguration {
        let selectedLanguage = self.dictationLanguageCode
        let providerID = self.providerID
        return CloudTranscriptionConfiguration(
            providerID: providerID,
            modelID: self.modelID(for: providerID),
            languageCode: selectedLanguage,
            primaryLanguageCode: self.primaryLanguageCode,
            secondaryLanguageCode: self.secondaryLanguageCode
        )
    }

    private static func validLanguageCode(_ value: String?) -> String? {
        guard let code = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              CloudTranscriptionConfiguration.supportedLanguageCodes.contains(code) else { return nil }
        return code
    }
}

extension SettingsStore {
    /// The engine dictation uses. A stored Live cloud choice that cannot run, because no provider is
    /// active or its key is missing, reads as Local so dictation keeps working.
    var speechExecutionSource: SpeechExecutionSource {
        get {
            let stored = CloudTranscriptionPreferences(defaults: .standard).source
            return SpeechExecutionSource.effective(stored: stored, usableLiveProvider: self.activeLiveProvider)
        }
        set {
            self.objectWillChange.send()
            var preferences = CloudTranscriptionPreferences(defaults: .standard)
            preferences.source = newValue
        }
    }

    /// True while Cloud is the dictation engine, whichever provider serves it.
    var usesCloudTranscription: Bool { self.speechExecutionSource == .cloud }

    /// The provider the Cloud engine uses (`CloudTranscriptionProvider`), OpenRouter by default.
    var cloudTranscriptionProviderID: String {
        get { CloudTranscriptionPreferences(defaults: .standard).providerID }
        set {
            self.objectWillChange.send()
            var preferences = CloudTranscriptionPreferences(defaults: .standard)
            preferences.providerID = newValue
        }
    }

    /// With OpenRouter as the Cloud engine, a Cleanup Style is applied by the style model in the same
    /// request that hears the audio, never by a separate text provider. A dictation whose style resolves
    /// to Off skips that model and goes to the speech model on the transcription endpoint.
    var usesCombinedCloudDictation: Bool {
        Self.usesCombinedCloudDictation(source: self.speechExecutionSource, cloudProviderID: self.cloudTranscriptionProviderID)
    }

    static func usesCombinedCloudDictation(source: SpeechExecutionSource, cloudProviderID: String) -> Bool {
        source == .cloud && cloudProviderID == CloudTranscriptionPreferences.defaultProviderID
    }

    /// What the Voice Engine picker shows: Automatic or a model the user picked.
    var cloudDictationModelSelection: String {
        get { CloudTranscriptionPreferences(defaults: .standard).dictationModelSelection }
        set {
            self.objectWillChange.send()
            var preferences = CloudTranscriptionPreferences(defaults: .standard)
            preferences.dictationModelSelection = newValue
        }
    }

    /// The model dictation actually uses, with Automatic resolved.
    var cloudDictationModelID: String {
        CloudTranscriptionPreferences(defaults: .standard).dictationModelID(inheriting: self.openRouterAIProviderModel)
    }

    /// OpenRouter's speech model, which its "Speech model" picker edits.
    var cloudTranscriptionModelID: String {
        get { CloudTranscriptionPreferences(defaults: .standard).modelID }
        set {
            self.objectWillChange.send()
            var preferences = CloudTranscriptionPreferences(defaults: .standard)
            preferences.modelID = newValue
        }
    }

    /// The speech model of any Cloud provider.
    func cloudTranscriptionModelID(for providerID: String) -> String {
        CloudTranscriptionPreferences(defaults: .standard).modelID(for: providerID)
    }

    func setCloudTranscriptionModelID(_ modelID: String, for providerID: String) {
        self.objectWillChange.send()
        var preferences = CloudTranscriptionPreferences(defaults: .standard)
        preferences.setModelID(modelID, for: providerID)
    }

    /// The speech model of the active Cloud provider.
    var activeCloudTranscriptionModelID: String {
        self.cloudTranscriptionModelID(for: self.cloudTranscriptionProviderID)
    }

    var cloudTranscriptionPrimaryLanguageCode: String? {
        get { CloudTranscriptionPreferences(defaults: .standard).primaryLanguageCode }
        set {
            self.objectWillChange.send()
            var preferences = CloudTranscriptionPreferences(defaults: .standard)
            preferences.primaryLanguageCode = newValue
        }
    }

    var cloudTranscriptionSecondaryLanguageCode: String? {
        get { CloudTranscriptionPreferences(defaults: .standard).secondaryLanguageCode }
        set {
            self.objectWillChange.send()
            var preferences = CloudTranscriptionPreferences(defaults: .standard)
            preferences.secondaryLanguageCode = newValue
        }
    }

    var cloudDictationLanguageCode: String? {
        get { CloudTranscriptionPreferences(defaults: .standard).dictationLanguageCode }
        set {
            var preferences = CloudTranscriptionPreferences(defaults: .standard)
            guard newValue == nil || newValue == preferences.primaryLanguageCode || newValue == preferences.secondaryLanguageCode else { return }
            self.objectWillChange.send()
            preferences.dictationLanguageCode = newValue
        }
    }

    var cloudTranscriptionConfiguration: CloudTranscriptionConfiguration {
        CloudTranscriptionPreferences(defaults: .standard).configuration
    }

    var cloudDictationConfiguration: CloudTranscriptionConfiguration {
        CloudTranscriptionPreferences(defaults: .standard).dictationConfiguration
    }
}

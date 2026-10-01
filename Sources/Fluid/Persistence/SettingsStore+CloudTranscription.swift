import Combine
import Foundation

nonisolated enum SpeechExecutionSource: String, CaseIterable, Identifiable, Sendable {
    case local
    case openRouter
    case liveCloud

    var id: String { self.rawValue }
    var displayName: String {
        switch self {
        case .local: "Local"
        case .openRouter: "OpenRouter"
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
    let defaults: UserDefaults

    var source: SpeechExecutionSource {
        get { SpeechExecutionSource(rawValue: self.defaults.string(forKey: "SpeechExecutionSource") ?? "") ?? .local }
        set { self.defaults.set(newValue.rawValue, forKey: "SpeechExecutionSource") }
    }

    var modelID: String {
        get {
            let stored = self.defaults.string(forKey: "CloudTranscriptionModel") ?? ""
            return CloudTranscriptionModel.catalog.contains { $0.id == stored }
                ? stored : CloudTranscriptionModel.defaultDictationID
        }
        set {
            guard CloudTranscriptionModel.catalog.contains(where: { $0.id == newValue }) else { return }
            self.defaults.set(newValue, forKey: "CloudTranscriptionModel")
        }
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

    var dictationModelID: String {
        get {
            let stored = self.defaults.string(forKey: "CloudDictationModel") ?? ""
            return CloudAudioDictationModel.catalog.contains { $0.id == stored } ? stored : CloudAudioDictationModel.defaultID
        }
        set {
            guard CloudAudioDictationModel.catalog.contains(where: { $0.id == newValue }) else { return }
            self.defaults.set(newValue, forKey: "CloudDictationModel")
        }
    }

    var configuration: CloudTranscriptionConfiguration {
        CloudTranscriptionConfiguration(modelID: self.modelID, primaryLanguageCode: self.primaryLanguageCode, secondaryLanguageCode: self.secondaryLanguageCode)
    }

    var dictationConfiguration: CloudTranscriptionConfiguration {
        let selectedLanguage = self.dictationLanguageCode
        return CloudTranscriptionConfiguration(
            modelID: self.modelID,
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
    static let openRouterTranscriptionKeyID = "openrouter-transcription"

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

    var usesCloudTranscription: Bool { self.speechExecutionSource == .openRouter }

    /// Every OpenRouter dictation is one request: audio and the resolved Cleanup Style go to the
    /// audio dictation model together, and Off asks that model for the plain transcript.
    var usesCombinedCloudDictation: Bool { self.usesCloudTranscription }

    var cloudDictationModelID: String {
        get { CloudTranscriptionPreferences(defaults: .standard).dictationModelID }
        set {
            self.objectWillChange.send()
            var preferences = CloudTranscriptionPreferences(defaults: .standard)
            preferences.dictationModelID = newValue
        }
    }

    var cloudTranscriptionModelID: String {
        get { CloudTranscriptionPreferences(defaults: .standard).modelID }
        set {
            self.objectWillChange.send()
            var preferences = CloudTranscriptionPreferences(defaults: .standard)
            preferences.modelID = newValue
        }
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

    var openRouterTranscriptionAPIKey: String {
        (try? KeychainService.shared.fetchKey(for: Self.openRouterTranscriptionKeyID)) ?? ""
    }

    func saveOpenRouterTranscriptionAPIKey(_ value: String) throws {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            try KeychainService.shared.deleteKey(for: Self.openRouterTranscriptionKeyID)
        } else {
            try KeychainService.shared.storeKey(key, for: Self.openRouterTranscriptionKeyID)
        }
        self.objectWillChange.send()
    }
}

import Combine
import Foundation

nonisolated enum SpeechExecutionSource: String, CaseIterable, Identifiable, Sendable {
    case local
    case openRouter

    var id: String { self.rawValue }
    var displayName: String { self == .local ? "Local" : "OpenRouter" }
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

    var languageCode: String? {
        get { SettingsStore.whisperLanguageCode(fromStoredValue: self.defaults.string(forKey: "CloudTranscriptionLanguage")) }
        set { self.defaults.set(newValue ?? "auto", forKey: "CloudTranscriptionLanguage") }
    }

    var configuration: CloudTranscriptionConfiguration {
        CloudTranscriptionConfiguration(modelID: self.modelID, languageCode: self.languageCode)
    }
}

extension SettingsStore {
    static let openRouterTranscriptionKeyID = "openrouter-transcription"

    var speechExecutionSource: SpeechExecutionSource {
        get { CloudTranscriptionPreferences(defaults: .standard).source }
        set {
            self.objectWillChange.send()
            var preferences = CloudTranscriptionPreferences(defaults: .standard)
            preferences.source = newValue
        }
    }

    var usesCloudTranscription: Bool { self.speechExecutionSource == .openRouter }

    var cloudTranscriptionModelID: String {
        get { CloudTranscriptionPreferences(defaults: .standard).modelID }
        set {
            self.objectWillChange.send()
            var preferences = CloudTranscriptionPreferences(defaults: .standard)
            preferences.modelID = newValue
        }
    }

    var cloudTranscriptionLanguageCode: String? {
        get { CloudTranscriptionPreferences(defaults: .standard).languageCode }
        set {
            self.objectWillChange.send()
            var preferences = CloudTranscriptionPreferences(defaults: .standard)
            preferences.languageCode = newValue
        }
    }

    var cloudTranscriptionConfiguration: CloudTranscriptionConfiguration {
        CloudTranscriptionPreferences(defaults: .standard).configuration
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

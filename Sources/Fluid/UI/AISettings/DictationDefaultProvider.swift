import Foundation

/// Identifies the main shortcut's provider without reading credentials or app-specific overrides.
enum DictationDefaultProvider {
    static func setupIssue(requiresAPIKey: Bool, hasAPIKey: Bool, hasModel: Bool, isVerified: Bool, verificationFailed: Bool) -> String? {
        if requiresAPIKey, !hasAPIKey { return "API key missing" }
        if !hasModel { return "Choose a model" }
        if verificationFailed { return "Verification failed" }
        // A test is optional; only missing setup prevents use.
        return nil
    }

    static func providerID(
        selection: SettingsStore.DictationPromptSelection,
        selectedProviderID: String,
        privateProviderID: String
    ) -> String {
        if selection == .off { return "" }
        if selection == .privateAI { return privateProviderID }
        if selection == .default, selectedProviderID == privateProviderID { return privateProviderID }
        let fallback = selectedProviderID.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback == privateProviderID ? "" : fallback
    }
}

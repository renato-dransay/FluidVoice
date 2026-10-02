import Foundation

/// Identifies the main shortcut's provider without reading credentials or app-specific overrides.
enum DictationDefaultProvider {
    /// What a text provider's row says is missing, or nil once it is verified. Display only: the
    /// feature gates read the verification record themselves.
    static func setupIssue(requiresAPIKey: Bool, hasAPIKey: Bool, hasModel: Bool, isVerified: Bool, verificationFailed: Bool) -> String? {
        if requiresAPIKey, !hasAPIKey { return "API key missing" }
        if !hasModel { return "Choose a model" }
        if verificationFailed { return "Verification failed" }
        return isVerified ? nil : "Not verified"
    }

    /// The default text provider is the selected provider, whatever Cleanup Style the main shortcut uses.
    static func isDefaultTextProvider(_ providerID: String, selectedProviderID: String) -> Bool {
        let selected = selectedProviderID.trimmingCharacters(in: .whitespacesAndNewlines)
        return !selected.isEmpty && selected == providerID
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

import Foundation

// Minimal settings types let the production read-only resolver run without launching the app.
enum SettingsStore {
    enum DictationPromptSelection: Equatable { case off, `default`, privateAI, profile(String) }
}

@main
enum DictationDefaultProviderTests {
    static func main() {
        func resolve(_ selection: SettingsStore.DictationPromptSelection, _ global: String) -> String {
            DictationDefaultProvider.providerID(
                selection: selection,
                selectedProviderID: global,
                privateProviderID: "fluid-1"
            )
        }
        precondition(resolve(.off, "openai") == "")
        precondition(resolve(.privateAI, "openai") == "fluid-1")
        precondition(resolve(.default, "openai") == "openai")
        precondition(resolve(.default, " openrouter ") == "openrouter")
        precondition(resolve(.profile("style"), "openai") == "openai")
        precondition(resolve(.default, "fluid-1") == "fluid-1")
        precondition(resolve(.profile("style"), "fluid-1") == "")
        precondition(DictationDefaultProvider.setupIssue(requiresAPIKey: true, hasAPIKey: false, hasModel: true, isVerified: true, verificationFailed: false) == "API key missing")
        precondition(DictationDefaultProvider.setupIssue(requiresAPIKey: false, hasAPIKey: false, hasModel: true, isVerified: true, verificationFailed: false) == nil)
        precondition(DictationDefaultProvider.setupIssue(requiresAPIKey: true, hasAPIKey: true, hasModel: false, isVerified: false, verificationFailed: false) == "Choose a model")
        precondition(
            DictationDefaultProvider.setupIssue(requiresAPIKey: true, hasAPIKey: true, hasModel: true, isVerified: false, verificationFailed: false) == "Not verified",
            "A configured provider that was never verified says so"
        )
        precondition(
            DictationDefaultProvider.setupIssue(requiresAPIKey: true, hasAPIKey: true, hasModel: true, isVerified: true, verificationFailed: false) == nil,
            "A verified provider has no setup issue"
        )
        precondition(DictationDefaultProvider
            .setupIssue(requiresAPIKey: true, hasAPIKey: true, hasModel: true, isVerified: false, verificationFailed: true) == "Verification failed")
        precondition(DictationDefaultProvider
            .setupIssue(requiresAPIKey: false, hasAPIKey: false, hasModel: true, isVerified: false, verificationFailed: false) == "Not verified")
        // The default text provider no longer depends on the main shortcut's Cleanup Style.
        precondition(DictationDefaultProvider.isDefaultTextProvider("openai", selectedProviderID: "openai"))
        precondition(DictationDefaultProvider.isDefaultTextProvider("openai", selectedProviderID: " openai "))
        precondition(!DictationDefaultProvider.isDefaultTextProvider("openai", selectedProviderID: "anthropic"))
        precondition(!DictationDefaultProvider.isDefaultTextProvider("", selectedProviderID: ""))
        print("PASS: 7 default-provider cases, 7 setup-status cases and 4 default-text-provider cases")
    }
}

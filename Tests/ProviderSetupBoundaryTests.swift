import Foundation

// Compile the production draft/save adapter against isolated settings and Keychain doubles.
final class UserDefaults {
    static let standard = UserDefaults()
    var values: [String: [String]] = [:]
    // Match Foundation UserDefaults, including an absent key.
    // swiftlint:disable:next discouraged_optional_collection
    func stringArray(forKey key: String) -> [String]? { self.values[key] }
    func set(_ value: [String], forKey key: String) { self.values[key] = value }
}

struct PrivateAIProviderFeature {
    static let shared = PrivateAIProviderFeature()
    let providerID = "fluid"
}

struct ModelRepository {
    static let shared = ModelRepository()
    func isBuiltIn(_ id: String) -> Bool { ["openai", "ollama", "fluid"].contains(id) }
    func defaultModels(for id: String) -> [String] { ["default-model"] }
    func isLocalEndpoint(_ url: String) -> Bool { url.hasPrefix("http://localhost") || url.hasPrefix("http://127.0.0.1") }
}

/// Built-in OpenAI requires a key; Ollama and custom providers take an optional one.
enum AIProviderCatalog {
    static func requiresAPIKey(_ id: String) -> Bool { id == "openai" }
}

enum ProviderAPIKeySaveError: Error {
    case readbackMismatch
}

struct KeychainFailure: Error {}

enum AIConnectionStatus: Equatable {
    case unknown
    case testing
    case success
    case failed
}

final class SettingsStore {
    struct SavedProvider {
        var id = UUID().uuidString
        let name: String
        let baseURL: String
        let models: [String]
    }

    struct Configuration: Equatable {
        var providerID: String
        var modelName = "model"
        var shortcut = "keep-shortcut"
    }

    var selectedProviderID = "fluid"
    var selectedModel: String? = "mini"
    var rewriteModeSelectedProviderID = ""
    var rewriteModeSelectedModel: String?
    var commandModeSelectedProviderID = ""
    var commandModeSelectedModel: String?
    var availableModelsByProvider: [String: [String]] = [:]
    var selectedModelByProvider: [String: String] = [:]
    var dictationPromptConfigurations: [String: Configuration] = [:]
    var verifiedProviderFingerprints: [String: String] = [:]

    /// The Keychain behind the single write path: each provider's own entry, plus the providers that
    /// also have another entry (a separate speech key or an old voice entry).
    var storedKeys: [String: String] = [:]
    var otherKeyEntries: Set<String> = []
    var failKeychain = false
    var keyWrites = 0
    var providerAPIKeys: [String: String] { self.storedKeys }

    func setProviderAPIKey(_ key: String?, for id: String) throws {
        self.keyWrites += 1
        if self.failKeychain { throw KeychainFailure() }
        if let key, !key.isEmpty {
            self.storedKeys[id] = key
        } else {
            self.storedKeys.removeValue(forKey: id)
        }
        self.otherKeyEntries.remove(id)
    }

    func hasAnyProviderKeyEntry(for id: String) -> Bool {
        self.storedKeys[id] != nil || self.otherKeyEntries.contains(id)
    }
}

final class AIEnhancementSettingsViewModel {
    struct ProviderItemData {
        let id: String
        let name: String
        let isBuiltIn: Bool
    }

    let settings = SettingsStore()
    var isTestingConnection = false
    var isFetchingModels = false
    private var persistsSelectedProvider = true
    /// Persisted to the settings like production's, except while a provider is only configured.
    var selectedProviderID = "openai" {
        didSet {
            if self.persistsSelectedProvider { self.settings.selectedProviderID = self.selectedProviderID }
        }
    }

    var managedOriginalKey: String?
    var fetchedModelsProviders: Set<String> = []
    var providerAPIKeys: [String: String] = [:]
    var savedProviders: [SettingsStore.SavedProvider] = []
    var availableModelsByProvider: [String: [String]] = [:]
    var selectedModelByProvider: [String: String] = ["fluid": "mini"]
    var cachedAddedProviderItems: [ProviderItemData] = []
    var connectionStatus: AIConnectionStatus = .unknown
    var connectionStatusByProvider: [String: AIConnectionStatus] = [:]
    /// What the stubbed text check answers, and how many it sent.
    var verificationPasses = false
    var verificationRequests = 0
    var saves = 0
    var failKeychain: Bool {
        get { self.settings.failKeychain }
        set { self.settings.failKeychain = newValue }
    }

    /// Keychain writes attempted through the single write path.
    var keySaves: Int { self.settings.keyWrites }
    var persistedKeys: [String: String] { self.settings.storedKeys }
    func providerKey(for id: String) -> String { id }
    func providerAPIKey(for id: String) -> String { self.providerAPIKeys[id] ?? "" }
    func updateProviderAPIKey(_ value: String, for id: String) { self.providerAPIKeys[id] = value }
    func textProviderBaseURL(for id: String) -> String {
        if let saved = self.savedProviders.first(where: { $0.id == id }) { return saved.baseURL }
        return ["openai": "https://api.openai.com/v1", "ollama": "http://localhost:11434/v1"][id] ?? ""
    }

    func invalidateVerification(for id: String) { self.settings.verifiedProviderFingerprints.removeValue(forKey: id) }
    func invalidateVerificationIfNeeded(for id: String) {}
    func showKeychainPersistenceFailure(_ error: Error) {}
    func isSpeechOnlyProvider(_ id: String) -> Bool { id == "deepgram" }
    func canUseProviderWithoutVerification(_ id: String) -> Bool { true }
    func connectionStatus(for id: String) -> AIConnectionStatus { self.connectionStatusByProvider[id] ?? .unknown }
    func configureProvider(_ id: String) {
        self.persistsSelectedProvider = false
        self.selectedProviderID = id
        self.persistsSelectedProvider = true
    }

    func handleProviderChange(_ id: String) {}
    func testAPIConnection() async {
        self.verificationRequests += 1
        self.connectionStatusByProvider[self.selectedProviderID] = self.verificationPasses ? .success : .failed
    }

    func hasProviderAPIKeyDraft(for id: String) -> Bool { self.providerAPIKeys[id] != nil }
    func refreshProviderItems() {
        let items = [
            ProviderItemData(id: "openai", name: "OpenAI", isBuiltIn: true),
            ProviderItemData(id: "ollama", name: "Ollama", isBuiltIn: true),
            ProviderItemData(id: "fluid", name: "Fluid", isBuiltIn: true),
        ]
            + self.savedProviders.map { ProviderItemData(id: $0.id, name: $0.name, isBuiltIn: false) }
        self.cachedAddedProviderItems = addedProviderItems(from: items)
    }

    func saveSavedProviders() { self.saves += 1; self.refreshProviderItems() }
    func clearEditProviderDraft() {}
    func finishConfiguringProvider() {
        self.persistsSelectedProvider = false
        self.selectedProviderID = self.settings.selectedProviderID
        self.persistsSelectedProvider = true
    }

    func refreshVerifiedProviders() {}
    func selectSoleVerifiedProviderIfNeeded() {}
}

@main enum ProviderSetupBoundaryTests {
    static func main() async throws {
        var count = 0
        func check(_ value: Bool, _ message: String) {
            precondition(value, message)
            count += 1
        }
        let vm = AIEnhancementSettingsViewModel()
        vm.refreshProviderItems()
        check(vm.cachedAddedProviderItems.isEmpty, "Fresh catalog stays hidden")
        let connectionEdits: [(inout ProviderSetupDraft) -> Void] = [
            { $0.providerID = "ollama" },
            { $0.baseURL = "http://localhost:4321/v1" },
            { $0.apiKey = "replacement-key" },
        ]
        for edit in connectionEdits {
            var fetched = ProviderSetupDraft(name: "Server", baseURL: "http://localhost:1234/v1")
            let oldIdentity = fetched.connectionIdentity
            check(fetched.applyFetchedModels(["second", "first", "first"], for: oldIdentity), "Current discovery is accepted")
            check(fetched.model == "first", "Discovery selects its first sorted result")
            fetched.selectFetchedModel("second")
            edit(&fetched)
            check(fetched.model.isEmpty && fetched.fetchedModels.isEmpty, "Connection edits clear automatic and picker selections immediately")
            check(fetched.modelsToSave(defaults: []).isEmpty, "Saving a new custom connection cannot retain an old fetched model")
            check(!fetched.applyFetchedModels(["stale"], for: oldIdentity), "Late discovery from the old connection is rejected")
            check(fetched.model.isEmpty && fetched.fetchedModels.isEmpty, "Rejected discovery cannot repopulate the cleared selection")

            var manual = ProviderSetupDraft(name: "Server", baseURL: "http://localhost:1234/v1")
            manual.applyFetchedModels(["first"], for: manual.connectionIdentity)
            // Typing even the same ID explicitly makes it a manual choice.
            manual.model = "first"
            edit(&manual)
            check(manual.model == "first" && manual.fetchedModels.isEmpty, "Connection edits preserve an explicitly entered ID")
            check(manual.modelsToSave(defaults: []) == ["first"], "Manual IDs remain available to save")
            manual.applyFetchedModels([], for: manual.connectionIdentity)
            check(manual.model == "first", "Empty discovery must not erase manual entry")
        }
        var reloaded = ProviderSetupDraft(name: "Server", baseURL: "http://localhost:1234/v1")
        reloaded.applyFetchedModels(["first", "second"], for: reloaded.connectionIdentity)
        reloaded.selectFetchedModel("second")
        reloaded.name = "Renamed server"
        reloaded.baseURL = " http://localhost:1234/v1 "
        check(reloaded.model == "second", "Name and URL whitespace edits preserve a valid fetched choice")
        reloaded.applyFetchedModels(["second", "third"], for: reloaded.connectionIdentity)
        check(reloaded.model == "second", "Reload preserves a selection still returned by the server")
        reloaded.applyFetchedModels(["third"], for: reloaded.connectionIdentity)
        check(reloaded.model == "third", "Reload replaces a fetched selection the server no longer returns")
        reloaded.applyFetchedModels([], for: reloaded.connectionIdentity)
        check(reloaded.model.isEmpty, "Empty discovery clears an old fetched selection")
        reloaded.applyFetchedModels(["old-server-model"], for: reloaded.connectionIdentity)
        reloaded.baseURL = "http://localhost:4321/v1"
        reloaded.apiKey = "new-key"
        let freshVM = AIEnhancementSettingsViewModel()
        check(freshVM.addProvider(reloaded), "A custom provider can be saved after rapid connection edits")
        check(freshVM.savedProviders.first?.models == [], "Persistence receives no model from the previous connection")
        check(freshVM.settings.selectedProviderID == "fluid", "Saving the new connection leaves the current dictation route intact")
        var draft = ProviderSetupDraft(name: "Local", baseURL: "http://localhost:1234/v1", model: "tiny")
        check(draft.isValid && vm.saves == 0, "Editing a valid draft has no persistence effects")
        var discoveryDraft = draft
        discoveryDraft.fetchedModels = ["first", "second"]
        discoveryDraft.model = "second"
        check(discoveryDraft.modelsToSave(defaults: []) == ["second", "first"], "Selected discovered model is saved first without dropping other models")
        discoveryDraft.model = "manual"
        check(discoveryDraft.modelsToSave(defaults: []) == ["manual", "first", "second"], "Manual entry preserves discovered models")
        discoveryDraft.model = ""
        check(discoveryDraft.modelsToSave(defaults: ["default"]) == ["first", "second"], "Discovery replaces fallback defaults")
        discoveryDraft.fetchedModels = []
        check(discoveryDraft.modelsToSave(defaults: ["default"]) == ["default"], "Empty discovery preserves default fallback")
        let originalConnection = discoveryDraft.connectionIdentity
        discoveryDraft.model = "another"
        check(discoveryDraft.connectionIdentity == originalConnection, "Model selection does not invalidate a connection request")
        discoveryDraft.apiKey = "changed"
        check(discoveryDraft.connectionIdentity != originalConnection, "Credential edits invalidate stale discovery")
        check(vm.saves == 0 && vm.providerAPIKeys.isEmpty && vm.savedProviders.isEmpty, "Model discovery drafts do not persist credentials or providers")
        draft.baseURL = "file:///tmp/model"
        check(!draft.isValid && !vm.addProvider(draft), "Reject non-HTTP endpoints without persistence")
        draft.baseURL = "https://user:secret@example.com"
        check(!draft.isValid, "Reject credentials embedded in URL")
        draft.baseURL = "http://localhost:1234/v1"
        draft.apiKey = "test-key"
        vm.failKeychain = true
        check(
            !vm.addProvider(draft) && vm.savedProviders.isEmpty && vm.providerAPIKeys.isEmpty && vm.saves == 0,
            "Keychain failure keeps records, keys, and model maps unchanged"
        )
        vm.failKeychain = false
        draft.fetchedModels = ["other", "tiny"]
        check(vm.addProvider(draft) && vm.savedProviders.count == 1, "Explicit Add saves a custom provider")
        check(vm.savedProviders.first?.models == ["tiny", "other"], "Add persists the selected model and complete discovered list")
        check(vm.settings.selectedProviderID == "fluid" && vm.selectedModelByProvider["fluid"] == "mini", "Adding does not change current route/model")
        check(vm.addProvider(draft) && vm.savedProviders.count == 2, "Same display name cannot overwrite another provider")
        check(vm.cachedAddedProviderItems.count == 2, "Saved custom providers appear without verification")
        let builtIn = ProviderSetupDraft(providerID: "ollama", name: "Ollama", baseURL: "http://localhost:11434/v1")
        check(vm.addProvider(builtIn), "Keyless local provider can be added")
        check(!vm.addProvider(builtIn), "Duplicate built-in Add is rejected")
        check(vm.cachedAddedProviderItems.contains { $0.id == "ollama" }, "Keyless provider remains visible via explicit membership")
        vm.providerAPIKeys["openai"] = "expired-key"
        vm.refreshProviderItems()
        check(vm.cachedAddedProviderItems.contains { $0.id == "openai" }, "Unverified legacy credentials remain discoverable")
        vm.providerAPIKeys.removeValue(forKey: "openai")
        vm.settings.dictationPromptConfigurations["legacy"] = .init(providerID: "openai")
        vm.refreshProviderItems()
        // Cleanup Styles carry no provider since every style uses the AI Providers card's provider.
        check(!vm.cachedAddedProviderItems.contains { $0.id == "openai" }, "A style configuration no longer keeps a provider listed")
        vm.isFetchingModels = true
        check(!vm.addProvider(draft), "In-flight editor request blocks another Add")
        let source = try String(contentsOfFile: "Sources/Fluid/UI/AISettingsView+AIConfiguration.swift", encoding: .utf8)
        let manager = source.components(separatedBy: "private var externalProviderManager: some View")[1]
            .components(separatedBy: "private var legacyAIConfigurationCard")[0]
        check(!manager.contains("Use for shortcut") && !manager.contains("Edit details"), "External manager has no duplicate editor or shortcut assignment action")
        check(source.contains(".onSubmit {") && source.contains("self.viewModel.addNewModel()"), "Manual model input retains Enter-to-add behavior")
        // The Manage sheet AI Providers routes to: Connection, Models and Used for.
        let management = try String(contentsOfFile: "Sources/Fluid/UI/AISettingsView+ProviderManagement.swift", encoding: .utf8)
        check(management.contains(".accessibilityLabel(\"Add model\")"), "Model add button remains accessible")
        let connection = management.components(separatedBy: "private func providerConnectionGroup")[1]
            .components(separatedBy: "private func apiKeyBinding")[0]
        check(connection.contains("Label(\"Remove provider\""), "Built-in management exposes removal")
        check(source.contains("self.providerManagementContent(for: providerID)"), "The routed Manage sheet shows the new sections")
        // The default control changes the provider only; the main shortcut's style is left alone.
        let makeDefault = source.components(separatedBy: "private func makePrimaryDefaultProvider")[1]
            .components(separatedBy: "func modelBinding")[0]
        check(
            makeDefault.contains("makeDefaultTextProvider") && !makeDefault.contains("setDictationPromptSelection(.default"),
            "Making a provider default leaves the main shortcut's Cleanup Style unchanged"
        )
        let providerList = try String(contentsOfFile: "Sources/Fluid/UI/AISettings/AIEnhancementSettingsViewModel+ProviderList.swift", encoding: .utf8)
        let makeDefaultText = providerList.components(separatedBy: "func makeDefaultTextProvider")[1]
            .components(separatedBy: "static func setDefaultAfterVerification")[0]
        check(
            makeDefaultText.contains("saveManagedProviderAPIKeyIfNeeded") && !makeDefaultText.contains("saveProviderAPIKey(")
                && !makeDefaultText.contains("setDictationPromptSelection"),
            "Making a provider default only persists an active credential edit and never changes a style"
        )
        let removal = AIEnhancementSettingsViewModel()
        removal.providerAPIKeys = ["openai": "remove-key", "other": "keep-key"]
        removal.settings.storedKeys = ["openai": "remove-key", "other": "keep-key"]
        removal.settings.dictationPromptConfigurations = [
            "affected": .init(providerID: "openai"),
            "unrelated": .init(providerID: "other"),
        ]
        removal.settings.rewriteModeSelectedProviderID = "openai"
        removal.settings.rewriteModeSelectedModel = "old"
        removal.settings.commandModeSelectedProviderID = "other"
        removal.settings.commandModeSelectedModel = "keep-model"
        removal.availableModelsByProvider = ["openai": ["old"], "other": ["keep"]]
        removal.selectedModelByProvider["openai"] = "old"
        UserDefaults.standard.set(["openai", "other"], forKey: AIEnhancementSettingsViewModel.addedProviderIDsKey)
        let before = removal.settings.dictationPromptConfigurations
        removal.failKeychain = true
        check(!removal.deleteCurrentProvider(), "Failed credential removal must fail the operation")
        check(removal.providerAPIKeys["openai"] == "remove-key" && removal.saves == 0, "Failed removal restores keys without saving provider changes")
        check(removal.settings.dictationPromptConfigurations == before, "Failed removal preserves assignments")
        check(UserDefaults.standard.stringArray(forKey: AIEnhancementSettingsViewModel.addedProviderIDsKey) == ["openai", "other"], "Failed removal preserves explicit membership")
        removal.failKeychain = false
        removal.isFetchingModels = true
        check(!removal.deleteCurrentProvider(), "Busy editor cannot remove a provider")
        removal.isFetchingModels = false
        check(removal.deleteCurrentProvider(), "Built-in removal succeeds")
        check(removal.settings.selectedProviderID == "fluid" && removal.settings.selectedModel == "mini", "Removing another provider preserves the default")
        check(removal.settings.dictationPromptConfigurations == before, "Removal leaves style configurations, which hold only shortcuts, unchanged")
        check(removal.settings.rewriteModeSelectedProviderID.isEmpty && removal.settings.rewriteModeSelectedModel == nil, "Affected rewrite route is cleared")
        check(removal.settings.commandModeSelectedProviderID == "other" && removal.settings.commandModeSelectedModel == "keep-model", "Unrelated command route is unchanged")
        check(removal.providerAPIKeys == ["other": "keep-key"] && removal.availableModelsByProvider["other"] == ["keep"], "Unrelated provider credentials and models survive")
        check(!removal.cachedAddedProviderItems.contains { $0.id == "openai" }, "Removed built-in disappears from added providers")
        removal.selectedProviderID = "ollama"
        removal.settings.selectedProviderID = "ollama"
        let keySavesBeforeKeylessRemoval = removal.keySaves
        removal.failKeychain = true
        check(
            removal.deleteCurrentProvider() && removal.settings.selectedProviderID.isEmpty && removal.settings.selectedModel == nil,
            "Removing the default clears its model without selecting another provider"
        )
        check(removal.keySaves == keySavesBeforeKeylessRemoval, "Removing a keyless provider does not require a Keychain write")
        removal.selectedProviderID = "fluid"
        check(!removal.deleteCurrentProvider(), "External provider removal cannot remove private AI")
        let closing = AIEnhancementSettingsViewModel()
        closing.providerAPIKeys["openai"] = "edited-key"
        closing.managedOriginalKey = "edited-key"
        closing.failKeychain = true
        check(closing.saveManagedProviderBeforeClosing("openai") && closing.keySaves == 0, "Unchanged key closes without any Keychain write, even if writes would fail")
        closing.managedOriginalKey = "old-key"
        closing.failKeychain = true
        check(!closing.saveManagedProviderBeforeClosing("openai"), "Keychain failure keeps Manage open")
        check(closing.providerAPIKeys["openai"] == "edited-key" && closing.settings.selectedProviderID == "fluid", "Failed close preserves the draft and default")
        closing.failKeychain = false
        closing.providerAPIKeys["anthropic"] = "unsaved-draft"
        check(
            closing.saveManagedProviderBeforeClosing("openai") && closing.persistedKeys["openai"] == "edited-key",
            "Done persists an edited key without verification or model refresh"
        )
        check(closing.persistedKeys["anthropic"] == nil, "Saving one provider's key never writes a snapshot of other drafts")
        closing.providerAPIKeys.removeValue(forKey: "anthropic")
        let savedCount = closing.keySaves
        closing.selectedProviderID = "fluid"
        check(closing.saveManagedProviderBeforeClosing("openai") && closing.keySaves == savedCount, "Removal cleanup must not save a different selected provider")
        closing.selectedProviderID = "ollama"
        check(closing.saveManagedProviderBeforeClosing("ollama") && closing.keySaves == savedCount, "Keyless provider close does not touch Keychain")
        closing.failKeychain = true
        check(closing.saveManagedProviderAPIKeyIfNeeded("ollama") && closing.keySaves == savedCount, "Making a keyless provider default does not require a Keychain write")
        closing.isTestingConnection = true
        check(!closing.saveManagedProviderBeforeClosing("ollama"), "Busy editor cannot dismiss")
        check(manager.contains(".interactiveDismissDisabled()"), "Interactive dismissal cannot bypass failed persistence")

        // KEY-6: emptying the key field removes nothing for a provider that needs a key.
        let key6 = AIEnhancementSettingsViewModel()
        key6.settings.storedKeys = ["openai": "kept-key"]
        key6.providerAPIKeys["openai"] = ""
        check(
            key6.saveProviderAPIKey(for: "openai") && key6.persistedKeys["openai"] == "kept-key" && key6.providerAPIKeys["openai"] == "kept-key",
            "Emptying a required key's field keeps the saved key"
        )
        check(key6.keySaves == 0, "Keeping the saved key writes nothing")
        let remote = SettingsStore.SavedProvider(name: "Remote", baseURL: "https://llm.example.com/v1", models: [])
        key6.savedProviders.append(remote)
        key6.settings.storedKeys[remote.id] = "remote-key"
        key6.providerAPIKeys[remote.id] = ""
        check(
            key6.saveProviderAPIKey(for: remote.id) && key6.persistedKeys[remote.id] == "remote-key",
            "A custom provider on a remote server keeps its key when the field is emptied"
        )
        let local = SettingsStore.SavedProvider(name: "Local", baseURL: "http://localhost:1234/v1", models: [])
        key6.savedProviders.append(local)
        key6.settings.storedKeys[local.id] = "local-key"
        key6.providerAPIKeys[local.id] = ""
        check(
            key6.saveProviderAPIKey(for: local.id) && key6.persistedKeys[local.id] == nil,
            "A local server's optional key goes with an emptied field"
        )
        // `Remove key` empties the draft first, as `removeProviderAPIKey` does.
        key6.providerAPIKeys.removeValue(forKey: "openai")
        check(
            key6.saveProviderAPIKey(for: "openai", allowsRemoval: true) && key6.persistedKeys["openai"] == nil,
            "Remove key still removes a required key"
        )
        key6.settings.otherKeyEntries = ["openrouter"]
        let writesBeforeSpeechOnlyEntry = key6.keySaves
        check(
            key6.saveProviderAPIKey(for: "openrouter", allowsRemoval: true) && key6.keySaves == writesBeforeSpeechOnlyEntry + 1
                && key6.settings.otherKeyEntries.isEmpty,
            "Removal writes when only a separate speech key or an old voice entry exists"
        )
        let writesBeforeNothing = key6.keySaves
        check(
            key6.saveProviderAPIKey(for: "groq", allowsRemoval: true) && key6.keySaves == writesBeforeNothing,
            "Removal of a provider with no entry at all writes nothing"
        )

        // VER-4 and AIP-7, through the production makeDefaultTextProvider.
        let defaults = AIEnhancementSettingsViewModel()
        defaults.settings.selectedProviderID = "anthropic"
        defaults.selectedProviderID = "anthropic"
        let stylesBefore = defaults.settings.dictationPromptConfigurations
        defaults.verificationPasses = false
        let failedDefault = await defaults.makeDefaultTextProvider("openai")
        check(!failedDefault && defaults.settings.selectedProviderID == "anthropic", "A failed check leaves the default text provider")
        check(defaults.connectionStatus(for: "openai") == .failed && defaults.verificationRequests == 1, "The unverified provider was checked once and shows the failure")
        check(defaults.selectedProviderID == "anthropic", "The list goes back to the default after a row's check")
        defaults.verificationPasses = true
        let passedDefault = await defaults.makeDefaultTextProvider("openai")
        check(passedDefault && defaults.settings.selectedProviderID == "openai", "A passed check makes the provider the default")
        defaults.connectionStatusByProvider["ollama"] = .success
        let verifiedDefault = await defaults.makeDefaultTextProvider("ollama")
        check(verifiedDefault && defaults.settings.selectedProviderID == "ollama" && defaults.verificationRequests == 2, "A verified provider becomes the default without a request")
        check(defaults.settings.dictationPromptConfigurations == stylesBefore, "Changing the default text provider leaves every Cleanup Style alone")
        let speechOnlyDefault = await defaults.makeDefaultTextProvider("deepgram")
        check(!speechOnlyDefault && defaults.settings.selectedProviderID == "ollama", "A speech-only provider never becomes the text default")
        let historySource = try String(contentsOfFile: "Sources/Fluid/UI/TranscriptionHistoryView.swift", encoding: .utf8)
        // Inspect only the request type and its inputs. Unrelated properties may
        // legitimately sit between these declarations and the filtered list.
        func declaration(_ marker: String) -> String {
            guard let start = historySource.range(of: marker),
                  let end = historySource.range(of: "\n    }", range: start.upperBound..<historySource.endIndex)
            else { preconditionFailure("Missing history declaration: \(marker)") }
            return String(historySource[start.lowerBound..<end.upperBound])
        }
        let audioRequest = declaration("private struct AudioAvailabilityRequest")
            + declaration("private var audioAvailabilityRequest:")
        check(!audioRequest.contains("selectedEntry") && !audioRequest.contains("selectedID"), "Row selection cannot restart audio scans")
        print("Passed \(count) provider setup assertions")
    }
}

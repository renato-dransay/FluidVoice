import Combine
import Foundation

/// A speech key check in AI Providers that is running or failed.
enum ProviderSpeechCheckState: Equatable {
    case verifying
    case failed(String)
}

/// Verify for a provider without Text: the live key check with the key speech features send. It writes
/// only the speech verification record; a rejected key clears it.
enum SpeechProviderVerification {
    typealias KeyCheck = (LiveTranscriptionProviderID, String) async throws -> Void

    static func verify(
        providerID: String,
        store: ProviderKeyStore,
        check: KeyCheck = { try await LiveTranscriptionKeyChecker.check(provider: $0, apiKey: $1) }
    ) async -> ProviderActionResult {
        guard let live = ProviderRegistry.liveProviderID(for: providerID) else {
            return .failure("This provider has no key check yet.")
        }
        let name = LiveTranscriptionCatalog.info(for: live).name
        let apiKey = store.speechAPIKey(for: providerID)
        guard !apiKey.isEmpty else {
            return .failure("Add a \(name) API key first.")
        }
        do {
            try await check(live, apiKey)
            // The check speaks only for the key it sent; a key replaced meanwhile is not verified.
            guard store.recordSpeechVerification(for: providerID, checkedKey: apiKey) else {
                return .failure(Self.keyChangedMessage)
            }
            return .success("Verified.")
        } catch let error as LiveTranscriptionError {
            if error == .authentication { store.clearSpeechVerification(for: providerID, rejectedKey: apiKey) }
            return .failure(error.message(providerName: name))
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    static let keyChangedMessage = "The key changed during the check. Verify again."
}

/// The AI Providers rows and the actions of providers without Text, which use only the key store:
/// they never go through a draft, `addProvider`, `configureProvider` or `deleteCurrentProvider`, and
/// never become the selected text provider.
extension AIEnhancementSettingsViewModel {
    /// The text provider rows plus one row for each speech-only provider with a saved key, by name.
    static func providerRows(textRows: [ProviderItemData], apiKeys: [String: String]) -> [ProviderItemData] {
        let textIDs = Set(textRows.map(\.id))
        let speechRows = AIProviderCatalog.speechOnlyProviders(withKeys: apiKeys)
            .filter { !textIDs.contains($0.id) }
            .map { ProviderItemData(id: $0.id, name: $0.name, isBuiltIn: true) }
        return (textRows + speechRows).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func isSpeechOnlyProvider(_ providerID: String) -> Bool {
        AIProviderCatalog.isSpeechOnly(providerID)
    }

    func providerName(for providerID: String) -> String {
        self.cachedAddedProviderItems.first { $0.id == providerID }?.name
            ?? self.cachedProviderItems.first { $0.id == providerID }?.name
            ?? AIProviderCatalog.name(for: providerID)
            ?? providerID
    }

    /// True when a key is saved in the Keychain for this provider, whatever the field shows now.
    func hasStoredAPIKey(for providerID: String) -> Bool {
        let key = self.providerKey(for: providerID)
        return !(self.settings.providerAPIKeys[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// KEY-3: Voice Engine uses a different key for this provider.
    func hasSeparateSpeechKey(_ providerID: String) -> Bool {
        let entry = ProviderKeyMigration.speechKeyEntry(for: self.providerKey(for: providerID))
        return !(self.providerAPIKeys[entry] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func removalImpact(for providerID: String) -> ProviderRemovalImpact {
        self.settings.providerRemovalImpact(for: providerID)
    }

    /// The badge of a row: the text status for a provider with Text, the speech status otherwise.
    func providerStatus(for providerID: String) -> ProviderStatus {
        if self.isSpeechOnlyProvider(providerID) {
            let state = self.speechCheckStates[providerID]
            return .speech(
                hasAPIKey: self.hasStoredAPIKey(for: providerID),
                isVerifying: state == .verifying,
                isVerified: self.settings.isSpeechVerified(providerID),
                verificationFailed: { if case .failed = state { return true } else { return false } }()
            )
        }
        let status = self.connectionStatus(for: providerID)
        let setupIssue = DictationDefaultProvider.setupIssue(
            requiresAPIKey: !self.isLocalEndpoint(self.textProviderBaseURL(for: providerID)),
            hasAPIKey: !self.providerAPIKey(for: providerID).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            hasModel: !self.selectedModel(for: providerID).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            isVerified: status == .success,
            verificationFailed: status == .failed
        )
        return .text(setupIssue: setupIssue, isVerifying: status == .testing)
    }

    /// The server a text provider is reached at, as the rows show it.
    func textProviderBaseURL(for providerID: String) -> String {
        if providerID == self.selectedProviderID { return self.openAIBaseURL }
        if let saved = self.savedProviders.first(where: { $0.id == providerID }) { return saved.baseURL }
        if ModelRepository.shared.isBuiltIn(providerID) { return ModelRepository.shared.defaultBaseURL(for: providerID) }
        return ""
    }

    // MARK: - Speech-only providers

    /// Saves a speech-only provider's key: adding it or replacing its key. Makes no network request.
    @discardableResult
    func saveSpeechProviderKey(_ apiKey: String, for providerID: String) -> ProviderActionResult {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard self.isSpeechOnlyProvider(providerID), !trimmed.isEmpty else {
            return .failure("Enter an API key.")
        }
        do {
            try self.settings.setProviderAPIKey(trimmed, for: providerID)
        } catch {
            self.showKeychainPersistenceFailure(error)
            return .failure("Couldn't save the key. Check Keychain access and try again.")
        }
        self.reloadStoredKeys(for: providerID)
        self.speechCheckStates[providerID] = nil
        self.refreshProviderItems()
        return .success("Key saved in macOS Keychain.")
    }

    /// Removes a provider's key through the single write path, which runs the removal effects (KEY-5).
    /// A text provider stays listed while it is still added; a speech-only provider leaves the list.
    @discardableResult
    func removeProviderAPIKey(for providerID: String) -> Bool {
        if self.isSpeechOnlyProvider(providerID) {
            do {
                try self.settings.setProviderAPIKey(nil, for: providerID)
            } catch {
                self.showKeychainPersistenceFailure(error)
                return false
            }
            self.reloadStoredKeys(for: providerID)
            self.speechCheckStates[providerID] = nil
            self.refreshProviderItems()
            return true
        }
        let key = self.providerKey(for: providerID)
        let previousKeys = self.providerAPIKeys
        self.providerAPIKeys.removeValue(forKey: key)
        if key != providerID { self.providerAPIKeys.removeValue(forKey: providerID) }
        guard self.saveProviderAPIKey(for: providerID, allowsRemoval: true) else {
            self.providerAPIKeys = previousKeys
            return false
        }
        self.reloadStoredKeys(for: providerID)
        self.refreshProviderItems()
        return true
    }

    /// VER-2 for a provider without Text.
    @discardableResult
    func verifySpeechProvider(_ providerID: String) async -> ProviderActionResult {
        guard self.speechCheckStates[providerID] != .verifying else { return .failure("A check is already running.") }
        self.speechCheckStates[providerID] = .verifying
        let result = await SpeechProviderVerification.verify(providerID: providerID, store: self.settings.providerKeyStore)
        self.settings.objectWillChange.send()
        switch result {
        case .success: self.speechCheckStates[providerID] = nil
        case let .failure(message): self.speechCheckStates[providerID] = .failed(message)
        }
        self.refreshProviderItems()
        return result
    }

    // MARK: - Two keys (KEY-3)

    @discardableResult
    func useTextKeyEverywhere(for providerID: String) -> ProviderActionResult {
        do {
            try self.settings.useTextKeyEverywhere(for: providerID)
        } catch {
            self.showKeychainPersistenceFailure(error)
            return .failure("Couldn't update the keys. Check Keychain access and try again.")
        }
        self.reloadStoredKeys(for: providerID)
        self.refreshProviderItems()
        return .success("Voice Engine now uses the key saved here.")
    }

    @discardableResult
    func useSpeechKeyEverywhere(for providerID: String) -> ProviderActionResult {
        do {
            try self.settings.useSpeechKeyEverywhere(for: providerID)
        } catch {
            self.showKeychainPersistenceFailure(error)
            return .failure("Couldn't update the keys. Check Keychain access and try again.")
        }
        self.reloadStoredKeys(for: providerID)
        if self.selectedProviderID == providerID, self.managedOriginalKey != nil {
            self.managedOriginalKey = self.providerAPIKey(for: providerID)
        }
        self.updateConnectionStatus(.unknown, for: providerID)
        self.refreshProviderItems()
        return .success("AI Providers now uses the Voice Engine key.")
    }

    // MARK: - Default text provider (AIP-7, VER-4)

    /// Makes a text provider the default. The main shortcut's Cleanup Style is not touched. A provider
    /// that is not text-verified is verified first, with one small request, and becomes the default
    /// only if that passes; on failure its row shows "Verification failed".
    @discardableResult
    func makeDefaultTextProvider(_ providerID: String) async -> Bool {
        guard !self.isFetchingModels, !self.isTestingConnection,
              !self.isSpeechOnlyProvider(providerID),
              providerID != self.settings.selectedProviderID,
              self.canUseProviderWithoutVerification(providerID),
              self.saveManagedProviderAPIKeyIfNeeded(providerID)
        else { return false }
        let wasManaging = self.selectedProviderID == providerID
        let madeDefault = await Self.setDefaultAfterVerification(
            isVerified: self.connectionStatus(for: providerID) == .success,
            verify: {
                self.configureProvider(providerID)
                await self.testAPIConnection()
                return self.connectionStatus(for: providerID) == .success
            },
            setDefault: {
                self.selectedProviderID = providerID
                self.handleProviderChange(providerID)
                self.connectionStatus = self.connectionStatus(for: providerID)
            }
        )
        // A row's check configured the provider only for the check; the list goes back to the default.
        if !wasManaging { self.finishConfiguringProvider() }
        return madeDefault
    }

    /// VER-4: a provider becomes the default only once it is text-verified; an unverified one is
    /// verified first, and a failed check leaves the default unchanged.
    static func setDefaultAfterVerification(
        isVerified: Bool,
        verify: () async -> Bool,
        setDefault: () -> Void
    ) async -> Bool {
        if !isVerified {
            guard await verify() else { return false }
        }
        setDefault()
        return true
    }

    // MARK: - Helpers

    /// Copies this provider's stored entries (its key and any separate Voice Engine key) into the
    /// view model, leaving other providers' unsaved drafts alone.
    private func reloadStoredKeys(for providerID: String) {
        let stored = self.settings.providerAPIKeys
        let key = self.providerKey(for: providerID)
        for entry in [key, ProviderKeyMigration.speechKeyEntry(for: key)] {
            if let value = stored[entry] {
                self.providerAPIKeys[entry] = value
            } else {
                self.providerAPIKeys.removeValue(forKey: entry)
            }
        }
    }
}

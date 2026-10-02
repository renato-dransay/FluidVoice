import Foundation

/// `ProviderKeyMigrationV1`: one key per provider. The Voice Engine used to keep its own Keychain entries
/// (`openrouter-transcription` and `live-transcription.<raw>`, the "old voice entries"); their keys move
/// to the provider's own entry, or to `speech-key.<id>` when that entry already holds a different key.
/// Text features keep exactly the key they used before and speech features keep exactly theirs.
nonisolated enum ProviderKeyMigration {
    static let flagKey = "ProviderKeyMigrationV1"
    static let speechKeyPrefix = "speech-key."
    static let openRouterTranscriptionEntry = "openrouter-transcription"
    private static let liveTranscriptionEntryPrefix = "live-transcription."

    /// Every old voice entry with the provider entry it migrates to.
    static let oldVoiceEntries: [(entry: String, providerID: String)] =
        [(Self.openRouterTranscriptionEntry, "openrouter")]
            + LiveTranscriptionProviderID.allCases.map { (Self.liveEntry(for: $0), ProviderRegistry.providerID(for: $0)) }

    /// The entry a provider's key used to have in the Voice Engine, kept so a downgraded build still works.
    static func liveEntry(for provider: LiveTranscriptionProviderID) -> String {
        provider.keychainID
    }

    static func oldVoiceEntries(for providerID: String) -> [String] {
        self.oldVoiceEntries.filter { $0.providerID == providerID }.map(\.entry)
    }

    static func speechKeyEntry(for providerID: String) -> String {
        self.speechKeyPrefix + providerID
    }

    static func isOldVoiceEntry(_ id: String) -> Bool {
        id == self.openRouterTranscriptionEntry || id.hasPrefix(self.liveTranscriptionEntryPrefix)
    }

    static func isSpeechKeyEntry(_ id: String) -> Bool {
        id.hasPrefix(self.speechKeyPrefix)
    }

    struct Result: Equatable {
        var entries: [String: String]
        /// Providers whose own entry was empty and received an old voice entry's key.
        var providersThatReceivedAKey: [String]
    }

    static func migrated(_ entries: [String: String]) -> [String: String] {
        self.migrate(entries).entries
    }

    /// Pure and idempotent. Old voice entries are left in place.
    static func migrate(_ entries: [String: String]) -> Result {
        var result = Result(entries: entries, providersThatReceivedAKey: [])
        for (entry, target) in self.oldVoiceEntries {
            let voiceKey = Self.trimmed(entries[entry])
            guard !voiceKey.isEmpty else { continue }
            let targetKey = Self.trimmed(result.entries[target])
            if targetKey.isEmpty {
                result.entries[target] = voiceKey
                result.providersThatReceivedAKey.append(target)
            } else if targetKey != voiceKey {
                result.entries[self.speechKeyEntry(for: target)] = voiceKey
            }
        }
        return result
    }

    private static func trimmed(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

extension ProviderKeyMigration {
    /// Runs the migration once. The flag is set only after the Keychain write succeeds, so a locked
    /// Keychain delays the migration to a later attempt instead of losing it. Returns true when the
    /// flag is set afterwards.
    @MainActor
    @discardableResult
    static func runIfNeeded(defaults: UserDefaults, keychain: KeychainService) -> Bool {
        guard !defaults.bool(forKey: self.flagKey) else { return true }
        var received: [String] = []
        do {
            try keychain.updateKeys { entries in
                let result = self.migrate(entries)
                entries = result.entries
                received = result.providersThatReceivedAKey
            }
        } catch {
            DebugLogger.shared.warning("Provider key migration deferred: \(type(of: error))", source: "ProviderKeyMigration")
            return false
        }
        defaults.set(true, forKey: self.flagKey)
        // A text provider that gained a key is listed in AI Providers, like one the user added.
        let textProviders = received.filter { ProviderRegistry.descriptor(for: $0)?.capabilities.contains(.text) == true }
        if !textProviders.isEmpty {
            let key = AIEnhancementSettingsViewModel.addedProviderIDsKey
            var added = defaults.stringArray(forKey: key) ?? []
            for id in textProviders where !added.contains(id) {
                added.append(id)
            }
            defaults.set(added, forKey: key)
        }
        return true
    }
}

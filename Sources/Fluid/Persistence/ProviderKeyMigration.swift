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
    /// Set once the engines that had no Voice Engine key were moved to Local, on the first Keychain read
    /// that succeeded. Separate from `flagKey`, so a Keychain write that keeps failing cannot skip it.
    static let enginesCheckedFlagKey = "ProviderKeyMigrationV1EnginesChecked"
    /// Text providers whose empty text entry the migration filled with a Voice Engine key. Meeting summaries
    /// do not use such a key until it is text-verified or saved again in AI Providers.
    static let filledTextProvidersKey = "ProviderKeyMigrationV1FilledTextProviders"

    /// What the Keychain part of the migration did. `entriesBefore` is nil when the Keychain could not be
    /// read; `written` is true once the migrated entries are stored (or nothing needed writing).
    struct KeychainOutcome {
        var entriesBefore: [String: String]? // swiftlint:disable:this discouraged_optional_collection
        var providersThatReceivedAKey: [String] = []
        var written = false
    }

    /// The Keychain part: one forced read, the pure migration and one write. Touches no UserDefaults, so it
    /// may run away from the main thread; `KeychainService` serializes its I/O on its own lock.
    nonisolated static func migrateKeychain(_ keychain: KeychainService) -> KeychainOutcome {
        var outcome = KeychainOutcome()
        do {
            try keychain.updateKeys { entries in
                outcome.entriesBefore = entries
                let result = self.migrate(entries)
                entries = result.entries
                outcome.providersThatReceivedAKey = result.providersThatReceivedAKey
            }
            outcome.written = true
        } catch {
            DebugLogger.shared.warning("Provider key migration deferred: \(type(of: error))", source: "ProviderKeyMigration")
        }
        return outcome
    }

    /// Runs the migration once. The flag is set only after the Keychain write succeeds, so a locked
    /// Keychain delays the migration to a later attempt instead of losing it. Returns true when the
    /// flag is set afterwards. Callers attempt it on events only (launch, the app becoming active, a key
    /// write), never on the read path: until it is written, readers return the keys as they were before the
    /// update.
    @MainActor
    @discardableResult
    static func runIfNeeded(defaults: UserDefaults, keychain: KeychainService) -> Bool {
        guard !defaults.bool(forKey: self.flagKey) else { return true }
        return self.apply(self.migrateKeychain(keychain), defaults: defaults)
    }

    /// The UserDefaults part, after `migrateKeychain`. The engines are adjusted whenever the Keychain could
    /// be read, even if the write failed; the flag and the provider lists only after the write.
    @MainActor
    @discardableResult
    static func apply(_ outcome: KeychainOutcome, defaults: UserDefaults) -> Bool {
        guard !defaults.bool(forKey: self.flagKey) else { return true }
        if let entriesBefore = outcome.entriesBefore {
            self.keepEnginesWithoutVoiceKeysLocalIfNeeded(entriesBefore: entriesBefore, defaults: defaults)
        }
        guard outcome.written else { return false }
        defaults.set(true, forKey: self.flagKey)
        // A text provider that gained a key is listed in AI Providers, like one the user added.
        let textProviders = outcome.providersThatReceivedAKey.filter {
            ProviderRegistry.descriptor(for: $0)?.capabilities.contains(.text) == true
        }
        if !textProviders.isEmpty {
            self.append(textProviders, toListAt: AIEnhancementSettingsViewModel.addedProviderIDsKey, in: defaults)
            self.append(textProviders, toListAt: self.filledTextProvidersKey, in: defaults)
        }
        return true
    }

    /// Text providers whose key the migration copied from a Voice Engine entry and that were neither
    /// verified nor saved again since.
    static func filledTextProviders(in defaults: UserDefaults) -> [String] {
        defaults.stringArray(forKey: self.filledTextProvidersKey) ?? []
    }

    /// Forgets that the migration filled this provider's text key: its key was saved or removed.
    static func forgetFilledTextProvider(_ providerID: String, in defaults: UserDefaults) {
        let filled = self.filledTextProviders(in: defaults)
        guard filled.contains(providerID) else { return }
        let remaining = filled.filter { $0 != providerID }
        if remaining.isEmpty {
            defaults.removeObject(forKey: self.filledTextProvidersKey)
        } else {
            defaults.set(remaining, forKey: self.filledTextProvidersKey)
        }
    }

    private static func append(_ ids: [String], toListAt key: String, in defaults: UserDefaults) {
        var list = defaults.stringArray(forKey: key) ?? []
        for id in ids where !list.contains(id) {
            list.append(id)
        }
        defaults.set(list, forKey: key)
    }

    /// Runs `keepEnginesWithoutVoiceKeysLocal` once, before the migration has been written, on the first
    /// Keychain read that succeeded. Never after the migration: an engine chosen since then uses the key
    /// AI Providers holds on purpose.
    static func keepEnginesWithoutVoiceKeysLocalIfNeeded(entriesBefore: [String: String], defaults: UserDefaults) {
        guard !defaults.bool(forKey: self.flagKey), !defaults.bool(forKey: self.enginesCheckedFlagKey) else { return }
        self.keepEnginesWithoutVoiceKeysLocal(entriesBefore: entriesBefore, defaults: defaults)
        defaults.set(true, forKey: self.enginesCheckedFlagKey)
    }

    /// Before the migration, Voice Engine used only its own entries: a live provider without its old voice
    /// entry could not stream (dictation ran Local, `SpeechExecutionSource.effective`), and OpenRouter
    /// without `openrouter-transcription` failed with a missing key, for dictation and FluidMeet alike.
    /// After it, speech readers fall back to the provider's text key, which would silently start sending
    /// audio with an AI Providers key. So every engine that had no old voice entry is moved to what it
    /// effectively was: dictation on Local, FluidMeet on its local model.
    static func keepEnginesWithoutVoiceKeysLocal(entriesBefore: [String: String], defaults: UserDefaults) {
        func hadVoiceKey(_ entry: String) -> Bool {
            !self.trimmed(entriesBefore[entry]).isEmpty
        }
        func hadVoiceKey(_ provider: LiveTranscriptionProviderID) -> Bool {
            hadVoiceKey(self.liveEntry(for: provider))
        }

        var cloud = CloudTranscriptionPreferences(defaults: defaults)
        var live = LiveTranscriptionPreferences(defaults: defaults)
        if let active = live.activeProvider, !hadVoiceKey(active) {
            if cloud.source == .liveCloud {
                cloud.source = .local
            }
            live.activeProvider = nil
        }

        let hadOpenRouterVoiceKey = hadVoiceKey(self.openRouterTranscriptionEntry)
        if !hadOpenRouterVoiceKey, cloud.source == .cloud, cloud.providerID == CloudTranscriptionPreferences.defaultProviderID {
            cloud.source = .local
        }

        let meetingBackend = SettingsStore.meetingTranscriptionBackendID(in: defaults)
        if !hadOpenRouterVoiceKey, meetingBackend == .openRouterNemotron {
            SettingsStore.setMeetingTranscriptionBackendID(.parakeetNemotron, in: defaults)
        }
        if let meetingProvider = SettingsStore.meetingLiveCloudProvider(in: defaults), !hadVoiceKey(meetingProvider) {
            if meetingBackend == .liveCloudNemotron {
                SettingsStore.setMeetingTranscriptionBackendID(.parakeetNemotron, in: defaults)
            }
            SettingsStore.setMeetingLiveCloudProvider(nil, in: defaults)
        }
    }
}

/// Spaces the migration retries the app makes when it becomes active, so switching apps never runs a
/// Keychain read and write more than once per interval.
struct ProviderKeyMigrationRetryThrottle {
    static let minimumInterval: TimeInterval = 30

    private(set) var lastAttempt: Date?

    /// True when an attempt may run now; records it as the last attempt.
    mutating func shouldAttempt(at now: Date) -> Bool {
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < Self.minimumInterval { return false }
        self.lastAttempt = now
        return true
    }
}

import Combine
import CryptoKit
import Foundation

extension Notification.Name {
    /// Posted after `SettingsStore.setProviderAPIKey` saved or removed a provider's key.
    static let providerAPIKeyChanged = Notification.Name("ProviderAPIKeyChanged")
}

/// The payload of `.providerAPIKeyChanged`.
struct ProviderAPIKeyChange: Equatable {
    static let providerIDKey = "providerID"
    static let removedKey = "removed"
    static let affectedActiveEngineKey = "affectedActiveEngine"

    let providerID: String
    let removed: Bool
    /// True when the provider served the dictation engine before the change. After a removal the engine
    /// is Local, so whoever holds a provider built for the old engine must rebuild it.
    let affectedActiveEngine: Bool

    init(providerID: String, removed: Bool, affectedActiveEngine: Bool) {
        self.providerID = providerID
        self.removed = removed
        self.affectedActiveEngine = affectedActiveEngine
    }

    init?(_ notification: Notification) {
        guard notification.name == .providerAPIKeyChanged,
              let providerID = notification.userInfo?[Self.providerIDKey] as? String,
              let removed = notification.userInfo?[Self.removedKey] as? Bool
        else { return nil }
        self.providerID = providerID
        self.removed = removed
        self.affectedActiveEngine = notification.userInfo?[Self.affectedActiveEngineKey] as? Bool ?? false
    }

    var userInfo: [String: Any] {
        [Self.providerIDKey: self.providerID, Self.removedKey: self.removed, Self.affectedActiveEngineKey: self.affectedActiveEngine]
    }
}

enum ProviderAPIKeyError: LocalizedError {
    case missingProviderID
    case noSavedKey

    var errorDescription: String? {
        switch self {
        case .missingProviderID: "No provider was given for this API key."
        case .noSavedKey: "No key is saved here to use everywhere."
        }
    }
}

/// Every provider key is read and written here, for every provider: text, cloud transcription and live.
/// Text features read `apiKey(for:)` (the entry `<id>`); speech features read `speechAPIKey(for:)` (the
/// entry `speech-key.<id>` when present, otherwise `<id>`). The only writer is `setProviderAPIKey`.
/// Defaults and Keychain are injected so tests never touch the app's own stores.
struct ProviderKeyStore {
    static let verifiedSpeechProvidersKey = "VerifiedSpeechProvidersV1"

    let defaults: UserDefaults
    let keychain: KeychainService
    var notificationCenter: NotificationCenter = .default
    /// False only for the app's own stores inside the unit-test host, which must never write them.
    var writesMigration = true

    // MARK: - Reading

    /// Attempts the key migration while its flag is unset. Returns true once it has been written. Run on
    /// events only (launch, the app becoming active, before a key write), never by a reader: an attempt
    /// forces a Keychain read and write.
    @discardableResult
    func migrateIfNeeded() -> Bool {
        guard self.writesMigration else { return self.isMigrated }
        return ProviderKeyMigration.runIfNeeded(defaults: self.defaults, keychain: self.keychain)
    }

    var isMigrated: Bool {
        self.defaults.bool(forKey: ProviderKeyMigration.flagKey)
    }

    /// The stored entries, from the Keychain cache. Until the migration is written they are exactly what
    /// the build before the update stored, so a deferred migration never hides, swaps or reroutes a key:
    /// text readers get `<id>` and speech readers get the old voice entries (see `speechAPIKey(for:)`).
    func entries() -> [String: String] {
        guard let stored = try? self.keychain.fetchAllKeys() else { return [:] }
        if !self.isMigrated, self.writesMigration {
            // The first Keychain read that succeeds settles the engines without a Voice Engine key, even
            // while the migration write keeps failing (UserDefaults only; no Keychain write).
            ProviderKeyMigration.keepEnginesWithoutVoiceKeysLocalIfNeeded(entriesBefore: stored, defaults: self.defaults)
        }
        return stored
    }

    /// The text key: the exact entry, else the canonical provider key (a custom provider's prefixed key).
    func apiKey(for providerID: String) -> String? {
        let entries = self.entries()
        if let key = entries[providerID] { return key }
        return entries[ModelRepository.shared.providerKey(for: providerID)]
    }

    /// The key speech features send to this provider: `speech-key.<id>` when present, otherwise `<id>`.
    /// Until the migration is written, only the key Voice Engine used before the update: its old voice
    /// entry for this provider, never the text entry. A provider without an old voice entry then has no
    /// speech key, as before the update.
    func speechAPIKey(for providerID: String) -> String {
        let entries = self.entries()
        if let override = Self.nonEmpty(entries[ProviderKeyMigration.speechKeyEntry(for: providerID)]) {
            return override
        }
        guard self.isMigrated else {
            return ProviderKeyMigration.oldVoiceEntries(for: providerID).lazy.compactMap { Self.nonEmpty(entries[$0]) }.first ?? ""
        }
        return entries[providerID] ?? ""
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    // MARK: - Speech verification

    var verifiedSpeechProviders: [String: String] {
        get { self.defaults.dictionary(forKey: Self.verifiedSpeechProvidersKey) as? [String: String] ?? [:] }
        nonmutating set {
            if newValue.isEmpty {
                self.defaults.removeObject(forKey: Self.verifiedSpeechProvidersKey)
            } else {
                self.defaults.set(newValue, forKey: Self.verifiedSpeechProvidersKey)
            }
        }
    }

    static func speechFingerprint(providerID: String, apiKey: String) -> String {
        let digest = SHA256.hash(data: Data("speech:\(providerID)|\(apiKey)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// True when a speech key check passed with the key `speechAPIKey(for:)` returns now.
    func isSpeechVerified(_ providerID: String) -> Bool {
        let key = self.speechAPIKey(for: providerID)
        guard !key.isEmpty, let stored = self.verifiedSpeechProviders[providerID] else { return false }
        return stored == Self.speechFingerprint(providerID: providerID, apiKey: key)
    }

    /// Records that a speech key check passed with `checkedKey`, the key the check sent. Nothing is
    /// recorded when that key is no longer the saved speech key (it changed while the check ran). Never
    /// touches the text record. Returns true when it recorded.
    @discardableResult
    func recordSpeechVerification(for providerID: String, checkedKey: String) -> Bool {
        guard !checkedKey.isEmpty, self.speechAPIKey(for: providerID) == checkedKey else { return false }
        self.verifiedSpeechProviders[providerID] = Self.speechFingerprint(providerID: providerID, apiKey: checkedKey)
        return true
    }

    /// Clears the speech record after the provider rejected `checkedKey`, unless the key was replaced while
    /// the check ran (the rejection then says nothing about the saved key).
    func clearSpeechVerification(for providerID: String, rejectedKey: String) {
        guard self.speechAPIKey(for: providerID) == rejectedKey else { return }
        self.clearSpeechVerification(for: providerID)
    }

    func clearSpeechVerification(for providerID: String) {
        guard self.verifiedSpeechProviders[providerID] != nil else { return }
        self.verifiedSpeechProviders.removeValue(forKey: providerID)
    }

    // MARK: - Writing

    /// The single write path for provider keys. A non-empty key is saved; nil or an empty key removes it.
    /// Each call reads and writes the Keychain aggregate once, then posts `.providerAPIKeyChanged`.
    /// Saving the key the provider already has, with no separate speech key, changes nothing: no write,
    /// no lost verification or passed live test, no notification. It makes no network request.
    @discardableResult
    func setProviderAPIKey(_ key: String?, for providerID: String) throws -> ProviderAPIKeyChange {
        let id = ModelRepository.shared.providerKey(for: providerID)
        guard !id.isEmpty else { throw ProviderAPIKeyError.missingProviderID }
        let value = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let removed = value.isEmpty
        self.migrateIfNeeded()
        let affectedActiveEngine = self.isActiveEngineProvider(id)
        if !removed, self.isSavedKey(value, for: id) {
            // Saved again by the user: the key is now theirs for text, whatever entry it came from.
            ProviderKeyMigration.forgetFilledTextProvider(id, in: self.defaults)
            self.addToLiveProviders(id)
            return ProviderAPIKeyChange(providerID: id, removed: false, affectedActiveEngine: affectedActiveEngine)
        }
        let oldVoiceEntries = ProviderKeyMigration.oldVoiceEntries(for: id)
        let speechKeyEntry = ProviderKeyMigration.speechKeyEntry(for: id)

        try self.keychain.updateKeys { entries in
            entries.removeValue(forKey: speechKeyEntry)
            if removed {
                entries.removeValue(forKey: id)
                for entry in oldVoiceEntries {
                    entries.removeValue(forKey: entry)
                }
            } else {
                entries[id] = value
                // An older build reads the Voice Engine entry, so one it still has gets the new key too.
                for entry in oldVoiceEntries where entries[entry] != nil {
                    entries[entry] = value
                }
            }
        }

        ProviderKeyMigration.forgetFilledTextProvider(id, in: self.defaults)
        // The Keychain took this write, so a migration it refused earlier is tried again now.
        if !self.isMigrated {
            self.migrateIfNeeded()
        }

        var fingerprints = SettingsStore.verifiedProviderFingerprints(in: self.defaults)
        if fingerprints.removeValue(forKey: id) != nil {
            SettingsStore.setVerifiedProviderFingerprints(fingerprints, in: self.defaults)
        }
        self.clearSpeechVerification(for: id)

        if removed {
            if let live = ProviderRegistry.liveProviderID(for: id) {
                var preferences = LiveTranscriptionPreferences(defaults: self.defaults)
                preferences.addedProviders.removeAll { $0 == live }
            }
            self.applyRemovalEffects(for: id)
        } else {
            self.addToLiveProviders(id)
        }

        let change = ProviderAPIKeyChange(providerID: id, removed: removed, affectedActiveEngine: affectedActiveEngine)
        self.notificationCenter.post(name: .providerAPIKeyChanged, object: nil, userInfo: change.userInfo)
        return change
    }

    /// True when `key` (trimmed) is already the provider's key for text and speech alike, and every old
    /// voice entry it still has (read by a downgraded build) holds it too, so saving it again would change
    /// nothing.
    func isSavedKey(_ key: String, for providerID: String) -> Bool {
        let id = ModelRepository.shared.providerKey(for: providerID)
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let entries = self.entries()
        return !value.isEmpty
            && entries[id] == value
            && entries[ProviderKeyMigration.speechKeyEntry(for: id)] == nil
            && ProviderKeyMigration.oldVoiceEntries(for: id).allSatisfy { entries[$0] == nil || entries[$0] == value }
    }

    /// A live-capable provider with a key is listed in `LiveTranscriptionProviders`, which a downgraded
    /// build reads.
    private func addToLiveProviders(_ providerID: String) {
        guard let live = ProviderRegistry.liveProviderID(for: providerID) else { return }
        var preferences = LiveTranscriptionPreferences(defaults: self.defaults)
        if !preferences.addedProviders.contains(live) {
            preferences.addedProviders.append(live)
        }
    }

    /// True when the stored dictation engine runs on this provider: Cloud with it as the Cloud provider,
    /// or Live cloud with it as the active live provider.
    func isActiveEngineProvider(_ providerID: String) -> Bool {
        let cloud = CloudTranscriptionPreferences(defaults: self.defaults)
        switch cloud.source {
        case .local:
            return false
        case .cloud:
            return cloud.providerID == providerID
        case .liveCloud:
            return LiveTranscriptionPreferences(defaults: self.defaults).activeProvider.map(ProviderRegistry.providerID(for:)) == providerID
        }
    }

    /// True when FluidMeet transcribes with this provider: its cloud backend (OpenRouter's) or its live
    /// backend with this provider as the meeting's live provider.
    func isFluidMeetProvider(_ providerID: String) -> Bool {
        let backend = SettingsStore.meetingTranscriptionBackendID(in: self.defaults)
        let meetingLiveProviderID = SettingsStore.meetingLiveCloudProvider(in: self.defaults).map(ProviderRegistry.providerID(for:))
        return (backend == .openRouterNemotron && providerID == CloudTranscriptionPreferences.defaultProviderID)
            || (backend == .liveCloudNemotron && meetingLiveProviderID == providerID)
    }

    /// What removing this provider's key would switch to Local; the removal confirmation names it.
    func removalImpact(for providerID: String) -> ProviderRemovalImpact {
        let id = ModelRepository.shared.providerKey(for: providerID)
        return ProviderRemovalImpact(
            switchesDictationToLocal: self.isActiveEngineProvider(id),
            switchesFluidMeetToLocal: self.isFluidMeetProvider(id)
        )
    }

    /// Settings that could only keep running with the removed key fall back to what works without it.
    private func applyRemovalEffects(for providerID: String) {
        var cloud = CloudTranscriptionPreferences(defaults: self.defaults)
        var live = LiveTranscriptionPreferences(defaults: self.defaults)
        if self.isActiveEngineProvider(providerID) {
            cloud.source = .local
            live.activeProvider = nil
        }
        if cloud.providerID == providerID {
            cloud.providerID = CloudTranscriptionPreferences.defaultProviderID
        }

        let meetingLiveProviderID = SettingsStore.meetingLiveCloudProvider(in: self.defaults).map(ProviderRegistry.providerID(for:))
        let meetingUsesProvider = self.isFluidMeetProvider(providerID)
        if meetingUsesProvider {
            SettingsStore.setMeetingTranscriptionBackendID(.parakeetNemotron, in: self.defaults)
        }
        if meetingUsesProvider || meetingLiveProviderID == providerID {
            SettingsStore.setMeetingLiveCloudProvider(nil, in: self.defaults)
        }
    }

    // MARK: - Two keys (KEY-3)

    /// True while Voice Engine uses a different key for this provider from the one AI Providers saved.
    func hasSeparateSpeechKey(_ providerID: String) -> Bool {
        let id = ModelRepository.shared.providerKey(for: providerID)
        let value = self.entries()[ProviderKeyMigration.speechKeyEntry(for: id)]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !value.isEmpty
    }

    /// True when the provider has a non-empty key of its own (`<id>`), the one "Use this key everywhere" uses.
    func hasTextKey(_ providerID: String) -> Bool {
        let id = ModelRepository.shared.providerKey(for: providerID)
        return !(self.entries()[id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
    }

    /// True when any Keychain entry of this provider exists: its key, a separate speech key or an old
    /// voice entry. Removing the provider's key must then write, even when the key field shows nothing.
    func hasAnyKeyEntry(for providerID: String) -> Bool {
        let id = ModelRepository.shared.providerKey(for: providerID)
        let entries = self.entries()
        let names = [id, ProviderKeyMigration.speechKeyEntry(for: id)] + ProviderKeyMigration.oldVoiceEntries(for: id)
        return names.contains { entries[$0] != nil }
    }

    /// "Use this key everywhere": speech features switch to the key AI Providers saved. One aggregate write;
    /// the speech verification of the old Voice Engine key is cleared. Refused while no key is saved
    /// here: it would delete the only key the provider has.
    @discardableResult
    func useTextKeyEverywhere(for providerID: String) throws -> ProviderAPIKeyChange {
        let id = ModelRepository.shared.providerKey(for: providerID)
        guard !id.isEmpty else { throw ProviderAPIKeyError.missingProviderID }
        guard self.hasTextKey(id) else { throw ProviderAPIKeyError.noSavedKey }
        self.migrateIfNeeded()
        let affectedActiveEngine = self.isActiveEngineProvider(id)
        let speechKeyEntry = ProviderKeyMigration.speechKeyEntry(for: id)
        let oldVoiceEntries = ProviderKeyMigration.oldVoiceEntries(for: id)
        try self.keychain.updateKeys { entries in
            entries.removeValue(forKey: speechKeyEntry)
            // An older build reads the Voice Engine entry, so it follows the key now used everywhere.
            if let textKey = entries[id], !textKey.isEmpty {
                for entry in oldVoiceEntries where entries[entry] != nil {
                    entries[entry] = textKey
                }
            }
        }
        self.clearSpeechVerification(for: id)
        return self.postKeyChange(providerID: id, affectedActiveEngine: affectedActiveEngine)
    }

    /// "Use the Voice Engine key everywhere": text features switch to the key Voice Engine used. One
    /// aggregate write; the text verification of the old AI Providers key is cleared.
    @discardableResult
    func useSpeechKeyEverywhere(for providerID: String) throws -> ProviderAPIKeyChange {
        let id = ModelRepository.shared.providerKey(for: providerID)
        guard !id.isEmpty else { throw ProviderAPIKeyError.missingProviderID }
        self.migrateIfNeeded()
        let affectedActiveEngine = self.isActiveEngineProvider(id)
        let speechKeyEntry = ProviderKeyMigration.speechKeyEntry(for: id)
        try self.keychain.updateKeys { entries in
            guard let speechKey = entries[speechKeyEntry]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !speechKey.isEmpty
            else { return }
            entries[id] = speechKey
            entries.removeValue(forKey: speechKeyEntry)
        }
        var fingerprints = SettingsStore.verifiedProviderFingerprints(in: self.defaults)
        if fingerprints.removeValue(forKey: id) != nil {
            SettingsStore.setVerifiedProviderFingerprints(fingerprints, in: self.defaults)
        }
        return self.postKeyChange(providerID: id, affectedActiveEngine: affectedActiveEngine)
    }

    private func postKeyChange(providerID: String, affectedActiveEngine: Bool) -> ProviderAPIKeyChange {
        let change = ProviderAPIKeyChange(providerID: providerID, removed: false, affectedActiveEngine: affectedActiveEngine)
        self.notificationCenter.post(name: .providerAPIKeyChanged, object: nil, userInfo: change.userInfo)
        return change
    }
}

/// What a key removal switches to Local (KEY-6). Removal asks first whenever either applies.
struct ProviderRemovalImpact: Equatable {
    let switchesDictationToLocal: Bool
    let switchesFluidMeetToLocal: Bool

    var needsConfirmation: Bool { self.switchesDictationToLocal || self.switchesFluidMeetToLocal }

    func confirmationTitle(providerName: String) -> String {
        "Remove \(providerName)?"
    }

    var confirmationMessage: String {
        var sentences: [String] = []
        if self.switchesDictationToLocal { sentences.append("Dictation switches to your selected local model.") }
        if self.switchesFluidMeetToLocal { sentences.append("FluidMeet transcription switches to Local.") }
        return sentences.joined(separator: " ")
    }
}

extension SettingsStore {
    var providerKeyStore: ProviderKeyStore {
        ProviderKeyStore(defaults: .standard, keychain: .shared, writesMigration: !Self.isRunningInUnitTestHost)
    }

    /// Retries a deferred key migration when the app becomes active, at most once per
    /// `ProviderKeyMigrationRetryThrottle.minimumInterval` and never twice at once. The Keychain read and
    /// write run off the main thread (they may wait for the login keychain); the result is applied to
    /// UserDefaults back on the main actor.
    func retryProviderKeyMigrationIfDue(now: Date = Date()) {
        let store = self.providerKeyStore
        guard store.writesMigration,
              !store.isMigrated,
              !Self.isProviderKeyMigrationRetryRunning,
              Self.providerKeyMigrationRetryThrottle.shouldAttempt(at: now)
        else { return }
        Self.isProviderKeyMigrationRetryRunning = true
        let keychain = store.keychain
        let defaults = store.defaults
        Task.detached(priority: .utility) {
            let outcome = ProviderKeyMigration.migrateKeychain(keychain)
            await MainActor.run {
                Self.isProviderKeyMigrationRetryRunning = false
                if ProviderKeyMigration.apply(outcome, defaults: defaults), outcome.written {
                    self.objectWillChange.send()
                }
            }
        }
    }

    private static var isProviderKeyMigrationRetryRunning = false
    private static var providerKeyMigrationRetryThrottle = ProviderKeyMigrationRetryThrottle()

    /// The unit-test host is this app with the app's own Keychain item and defaults, so the key
    /// migration never writes them from there; readers see the keys as the build before the update stored them.
    nonisolated static var isRunningInUnitTestHost: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// Every stored key entry, as the text features of AI Providers read them.
    var providerAPIKeys: [String: String] {
        self.providerKeyStore.entries()
    }

    /// The key text features send to this provider.
    func getAPIKey(for providerID: String) -> String? {
        self.providerKeyStore.apiKey(for: providerID)
    }

    /// The key speech features (Cloud and Live cloud transcription) send to this provider.
    func speechAPIKey(for providerID: String) -> String {
        self.providerKeyStore.speechAPIKey(for: providerID)
    }

    var openRouterTranscriptionAPIKey: String {
        self.speechAPIKey(for: CloudTranscriptionPreferences.defaultProviderID)
    }

    /// The speech key of the provider the Cloud engine uses.
    var cloudTranscriptionAPIKey: String {
        self.speechAPIKey(for: self.cloudTranscriptionProviderID)
    }

    func liveTranscriptionAPIKey(for provider: LiveTranscriptionProviderID) -> String {
        self.speechAPIKey(for: ProviderRegistry.providerID(for: provider))
    }

    /// Saves (non-empty key) or removes (nil) a provider's key, with the effects described on
    /// `ProviderKeyStore.setProviderAPIKey`.
    func setProviderAPIKey(_ key: String?, for providerID: String) throws {
        self.objectWillChange.send()
        try self.providerKeyStore.setProviderAPIKey(key, for: providerID)
    }

    /// The speech verification record (`VerifiedSpeechProvidersV1`), separate from the text record.
    var verifiedSpeechProviders: [String: String] {
        self.providerKeyStore.verifiedSpeechProviders
    }

    func isSpeechVerified(_ providerID: String) -> Bool {
        self.providerKeyStore.isSpeechVerified(providerID)
    }

    /// Records a passed speech check of `checkedKey`, only while it is still the saved speech key.
    @discardableResult
    func recordSpeechVerification(for providerID: String, checkedKey: String) -> Bool {
        self.objectWillChange.send()
        return self.providerKeyStore.recordSpeechVerification(for: providerID, checkedKey: checkedKey)
    }

    func clearSpeechVerification(for providerID: String, rejectedKey: String) {
        self.objectWillChange.send()
        self.providerKeyStore.clearSpeechVerification(for: providerID, rejectedKey: rejectedKey)
    }

    func clearSpeechVerification(for providerID: String) {
        self.objectWillChange.send()
        self.providerKeyStore.clearSpeechVerification(for: providerID)
    }

    func hasSeparateSpeechKey(_ providerID: String) -> Bool {
        self.providerKeyStore.hasSeparateSpeechKey(providerID)
    }

    func hasProviderTextKey(_ providerID: String) -> Bool {
        self.providerKeyStore.hasTextKey(providerID)
    }

    func hasAnyProviderKeyEntry(for providerID: String) -> Bool {
        self.providerKeyStore.hasAnyKeyEntry(for: providerID)
    }

    func useTextKeyEverywhere(for providerID: String) throws {
        self.objectWillChange.send()
        try self.providerKeyStore.useTextKeyEverywhere(for: providerID)
    }

    func useSpeechKeyEverywhere(for providerID: String) throws {
        self.objectWillChange.send()
        try self.providerKeyStore.useSpeechKeyEverywhere(for: providerID)
    }

    func providerRemovalImpact(for providerID: String) -> ProviderRemovalImpact {
        self.providerKeyStore.removalImpact(for: providerID)
    }
}

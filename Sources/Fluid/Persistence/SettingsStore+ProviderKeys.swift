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

    var errorDescription: String? {
        switch self {
        case .missingProviderID: "No provider was given for this API key."
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

    /// Attempts the key migration while its flag is unset. Returns true once it has been written.
    @discardableResult
    func migrateIfNeeded() -> Bool {
        guard self.writesMigration else { return self.defaults.bool(forKey: ProviderKeyMigration.flagKey) }
        return ProviderKeyMigration.runIfNeeded(defaults: self.defaults, keychain: self.keychain)
    }

    /// The stored entries as this build reads them. Until the migration could be written, its result is
    /// computed in memory, so a failed write never hides or swaps a key.
    func entries() -> [String: String] {
        let isMigrated = self.migrateIfNeeded()
        let stored = (try? self.keychain.fetchAllKeys()) ?? [:]
        return isMigrated ? stored : ProviderKeyMigration.migrated(stored)
    }

    /// The text key: the exact entry, else the canonical provider key (a custom provider's prefixed key).
    func apiKey(for providerID: String) -> String? {
        let entries = self.entries()
        if let key = entries[providerID] { return key }
        return entries[ModelRepository.shared.providerKey(for: providerID)]
    }

    /// The key speech features send to this provider.
    func speechAPIKey(for providerID: String) -> String {
        let entries = self.entries()
        let override = entries[ProviderKeyMigration.speechKeyEntry(for: providerID)]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return override.isEmpty ? entries[providerID] ?? "" : override
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

    /// Records that a speech key check passed with the current speech key. Never touches the text record.
    func recordSpeechVerification(for providerID: String) {
        let key = self.speechAPIKey(for: providerID)
        guard !key.isEmpty else { return }
        self.verifiedSpeechProviders[providerID] = Self.speechFingerprint(providerID: providerID, apiKey: key)
    }

    func clearSpeechVerification(for providerID: String) {
        guard self.verifiedSpeechProviders[providerID] != nil else { return }
        self.verifiedSpeechProviders.removeValue(forKey: providerID)
    }

    // MARK: - Writing

    /// The single write path for provider keys. A non-empty key is saved; nil or an empty key removes it.
    /// Each call reads and writes the Keychain aggregate once, then posts `.providerAPIKeyChanged`.
    /// It makes no network request.
    @discardableResult
    func setProviderAPIKey(_ key: String?, for providerID: String) throws -> ProviderAPIKeyChange {
        let id = ModelRepository.shared.providerKey(for: providerID)
        guard !id.isEmpty else { throw ProviderAPIKeyError.missingProviderID }
        let value = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let removed = value.isEmpty
        self.migrateIfNeeded()
        let affectedActiveEngine = self.isActiveEngineProvider(id)
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

        var fingerprints = SettingsStore.verifiedProviderFingerprints(in: self.defaults)
        if fingerprints.removeValue(forKey: id) != nil {
            SettingsStore.setVerifiedProviderFingerprints(fingerprints, in: self.defaults)
        }
        self.clearSpeechVerification(for: id)

        if let live = ProviderRegistry.liveProviderID(for: id) {
            var preferences = LiveTranscriptionPreferences(defaults: self.defaults)
            if removed {
                preferences.addedProviders.removeAll { $0 == live }
            } else if !preferences.addedProviders.contains(live) {
                preferences.addedProviders.append(live)
            }
        }
        if removed { self.applyRemovalEffects(for: id) }

        let change = ProviderAPIKeyChange(providerID: id, removed: removed, affectedActiveEngine: affectedActiveEngine)
        self.notificationCenter.post(name: .providerAPIKeyChanged, object: nil, userInfo: change.userInfo)
        return change
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

        let backend = SettingsStore.meetingTranscriptionBackendID(in: self.defaults)
        let meetingLiveProviderID = SettingsStore.meetingLiveCloudProvider(in: self.defaults).map(ProviderRegistry.providerID(for:))
        // FluidMeet's cloud backend is OpenRouter's; its live backend uses the meeting's live provider.
        let meetingUsesProvider = (backend == .openRouterNemotron && providerID == CloudTranscriptionPreferences.defaultProviderID)
            || (backend == .liveCloudNemotron && meetingLiveProviderID == providerID)
        if meetingUsesProvider {
            SettingsStore.setMeetingTranscriptionBackendID(.parakeetNemotron, in: self.defaults)
        }
        if meetingUsesProvider || meetingLiveProviderID == providerID {
            SettingsStore.setMeetingLiveCloudProvider(nil, in: self.defaults)
        }
    }
}

extension SettingsStore {
    var providerKeyStore: ProviderKeyStore {
        ProviderKeyStore(defaults: .standard, keychain: .shared, writesMigration: !Self.isRunningInUnitTestHost)
    }

    /// The unit-test host is this app with the app's own Keychain item and defaults, so the key
    /// migration never writes them from there; readers still see the migrated keys in memory.
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

    func recordSpeechVerification(for providerID: String) {
        self.objectWillChange.send()
        self.providerKeyStore.recordSpeechVerification(for: providerID)
    }

    func clearSpeechVerification(for providerID: String) {
        self.objectWillChange.send()
        self.providerKeyStore.clearSpeechVerification(for: providerID)
    }
}

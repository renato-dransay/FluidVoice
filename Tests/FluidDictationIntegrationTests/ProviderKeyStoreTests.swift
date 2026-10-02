@testable import FluidVoice_Debug
import Foundation
import XCTest

/// Keys and migration (spec section 6) and the speech verification record (VER-1), against an
/// in-memory Keychain and a private defaults suite. Nothing here reads the app's own stores.
@MainActor
final class ProviderKeyStoreTests: XCTestCase {
    /// The Keychain aggregate in memory. The service keeps it alive for as long as a store uses it.
    private final class FakeKeychain {
        var storage: [String: String]
        var failSaves = false
        var saves = 0
        private(set) var service: KeychainService!

        init(_ storage: [String: String]) {
            self.storage = storage
            self.service = KeychainService(
                testingLoad: { self.storage },
                testingSave: { values in
                    if self.failSaves { throw KeychainServiceError.unhandled(-25308) }
                    self.saves += 1
                    self.storage = values
                }
            )
        }
    }

    private var suiteName = ""
    private var defaults: UserDefaults!
    private var notificationCenter: NotificationCenter!

    override func setUpWithError() throws {
        self.suiteName = "ProviderKeyStoreTests.\(UUID().uuidString)"
        self.defaults = try XCTUnwrap(UserDefaults(suiteName: self.suiteName))
        self.notificationCenter = NotificationCenter()
    }

    override func tearDown() {
        self.defaults.removePersistentDomain(forName: self.suiteName)
        super.tearDown()
    }

    private func store(_ keychain: FakeKeychain) -> ProviderKeyStore {
        ProviderKeyStore(defaults: self.defaults, keychain: keychain.service, notificationCenter: self.notificationCenter)
    }

    // MARK: - Pure migration

    func testAnEmptyOrAbsentOldEntryChangesNothing() {
        let entries = ["openrouter-transcription": "  ", "openai": "text"]
        XCTAssertEqual(ProviderKeyMigration.migrated(entries), entries)
        XCTAssertEqual(ProviderKeyMigration.migrated(["openai": "text"]), ["openai": "text"])
    }

    func testAnOldEntryFillsAnEmptyOrAbsentProviderEntry() {
        let result = ProviderKeyMigration.migrate([
            "openrouter-transcription": "router-voice",
            "live-transcription.soniox": "soniox-key",
            "live-transcription.openAI": "openai-voice",
            "openai": "",
        ])
        XCTAssertEqual(result.entries["openrouter"], "router-voice")
        XCTAssertEqual(result.entries["soniox"], "soniox-key")
        XCTAssertEqual(result.entries["openai"], "openai-voice")
        XCTAssertEqual(Set(result.providersThatReceivedAKey), ["openrouter", "soniox", "openai"])
        XCTAssertFalse(result.entries.keys.contains { $0.hasPrefix("speech-key.") })
    }

    func testAnEqualProviderEntryChangesNothing() {
        let entries = ["openrouter-transcription": "same", "openrouter": "same"]
        let result = ProviderKeyMigration.migrate(entries)
        XCTAssertEqual(result.entries, entries)
        XCTAssertEqual(result.providersThatReceivedAKey, [])
    }

    func testADifferentProviderEntryKeepsItsKeyAndTheVoiceKeyMovesToSpeechKey() {
        let result = ProviderKeyMigration.migrate([
            "openrouter-transcription": "router-voice",
            "openrouter": "router-text",
            "live-transcription.openAI": "openai-voice",
            "openai": "openai-text",
        ])
        XCTAssertEqual(result.entries["openrouter"], "router-text")
        XCTAssertEqual(result.entries["speech-key.openrouter"], "router-voice")
        XCTAssertEqual(result.entries["openai"], "openai-text")
        XCTAssertEqual(result.entries["speech-key.openai"], "openai-voice")
        XCTAssertEqual(result.providersThatReceivedAKey, [])
    }

    func testMigrationIsIdempotentAndLeavesOldEntriesInPlace() {
        let entries = [
            "openrouter-transcription": "router-voice",
            "openrouter": "router-text",
            "live-transcription.deepgram": "deepgram-key",
            "live-transcription.elevenLabs": "eleven-key",
            "custom:local": "local-key",
        ]
        let once = ProviderKeyMigration.migrated(entries)
        XCTAssertEqual(ProviderKeyMigration.migrated(once), once)
        for (entry, value) in entries {
            XCTAssertEqual(once[entry], value, entry)
        }
        XCTAssertEqual(once["deepgram"], "deepgram-key")
        XCTAssertEqual(once["elevenlabs"], "eleven-key")
    }

    // MARK: - Runner

    func testTheRunnerWritesOnceSetsTheFlagAndListsTextProvidersThatGainedAKey() {
        let keychain = FakeKeychain(["openrouter-transcription": "router-voice", "live-transcription.soniox": "soniox-key"])
        self.defaults.set(["anthropic"], forKey: AIEnhancementSettingsViewModel.addedProviderIDsKey)

        XCTAssertTrue(ProviderKeyMigration.runIfNeeded(defaults: self.defaults, keychain: keychain.service))

        XCTAssertTrue(self.defaults.bool(forKey: ProviderKeyMigration.flagKey))
        XCTAssertEqual(keychain.saves, 1)
        XCTAssertEqual(keychain.storage["openrouter"], "router-voice")
        XCTAssertEqual(keychain.storage["soniox"], "soniox-key")
        // Soniox has no Text capability, so it is not an AI Providers text row.
        XCTAssertEqual(self.defaults.stringArray(forKey: AIEnhancementSettingsViewModel.addedProviderIDsKey), ["anthropic", "openrouter"])

        XCTAssertTrue(ProviderKeyMigration.runIfNeeded(defaults: self.defaults, keychain: keychain.service))
        XCTAssertEqual(keychain.saves, 1)
    }

    func testTheRunnerWritesNoVerificationRecord() {
        let keychain = FakeKeychain(["openrouter-transcription": "router-voice"])
        SettingsStore.setVerifiedProviderFingerprints(["openai": "kept"], in: self.defaults)
        ProviderKeyMigration.runIfNeeded(defaults: self.defaults, keychain: keychain.service)
        XCTAssertEqual(SettingsStore.verifiedProviderFingerprints(in: self.defaults), ["openai": "kept"])
        XCTAssertEqual(self.store(keychain).verifiedSpeechProviders, [:])
    }

    func testAFailedWriteLeavesTheFlagUnsetAndALaterReadRetries() {
        let keychain = FakeKeychain(["openrouter-transcription": "router-voice", "openrouter": "router-text"])
        keychain.failSaves = true
        let store = self.store(keychain)

        XCTAssertFalse(ProviderKeyMigration.runIfNeeded(defaults: self.defaults, keychain: keychain.service))
        XCTAssertFalse(self.defaults.bool(forKey: ProviderKeyMigration.flagKey))
        XCTAssertNil(keychain.storage["speech-key.openrouter"])
        // Until the write succeeds, readers see the migrated result, so neither feature loses its key.
        XCTAssertEqual(store.speechAPIKey(for: "openrouter"), "router-voice")
        XCTAssertEqual(store.apiKey(for: "openrouter"), "router-text")

        keychain.failSaves = false
        XCTAssertEqual(store.speechAPIKey(for: "openrouter"), "router-voice")
        XCTAssertTrue(self.defaults.bool(forKey: ProviderKeyMigration.flagKey))
        XCTAssertEqual(keychain.storage["speech-key.openrouter"], "router-voice")
    }

    // MARK: - Readers

    func testReadersReturnTheOldVoiceKeysBeforeTheFlagIsSet() {
        let keychain = FakeKeychain([
            "openrouter-transcription": "router-voice",
            "live-transcription.soniox": "soniox-key",
            "live-transcription.assemblyAI": "assembly-key",
        ])
        let store = self.store(keychain)
        XCTAssertFalse(self.defaults.bool(forKey: ProviderKeyMigration.flagKey))
        XCTAssertEqual(store.speechAPIKey(for: CloudTranscriptionPreferences.defaultProviderID), "router-voice")
        XCTAssertEqual(store.speechAPIKey(for: ProviderRegistry.providerID(for: .soniox)), "soniox-key")
        XCTAssertEqual(store.speechAPIKey(for: ProviderRegistry.providerID(for: .assemblyAI)), "assembly-key")
        XCTAssertEqual(store.speechAPIKey(for: ProviderRegistry.providerID(for: .deepgram)), "")
    }

    func testWithAConflictTextAndSpeechReadersReturnDifferentKeys() {
        let keychain = FakeKeychain(["live-transcription.openAI": "openai-voice", "openai": "openai-text"])
        let store = self.store(keychain)
        XCTAssertEqual(store.apiKey(for: "openai"), "openai-text")
        XCTAssertEqual(store.speechAPIKey(for: "openai"), "openai-voice")
    }

    func testTheTextReaderFindsACustomProviderByItsCanonicalKey() {
        let store = self.store(FakeKeychain(["custom:local-server": "local-key"]))
        XCTAssertEqual(store.apiKey(for: "local-server"), "local-key")
        XCTAssertEqual(store.apiKey(for: "custom:local-server"), "local-key")
    }

    // MARK: - setProviderAPIKey

    func testSavingMirrorsIntoExistingOldEntriesAndDeletesTheSpeechKey() throws {
        let keychain = FakeKeychain([
            "openrouter": "router-text",
            "openrouter-transcription": "router-voice",
            "speech-key.openrouter": "router-voice",
        ])
        self.defaults.set(true, forKey: ProviderKeyMigration.flagKey)
        let savesBefore = keychain.saves

        try self.store(keychain).setProviderAPIKey("  router-new  ", for: "openrouter")

        XCTAssertEqual(keychain.storage, ["openrouter": "router-new", "openrouter-transcription": "router-new"])
        XCTAssertEqual(keychain.saves, savesBefore + 1)
    }

    func testSavingDoesNotCreateOldEntriesThatDidNotExist() throws {
        let keychain = FakeKeychain([:])
        self.defaults.set(true, forKey: ProviderKeyMigration.flagKey)
        try self.store(keychain).setProviderAPIKey("deepgram-key", for: "deepgram")
        XCTAssertEqual(keychain.storage, ["deepgram": "deepgram-key"])
    }

    func testSavingALiveProviderKeyAddsItToTheLiveList() throws {
        let keychain = FakeKeychain([:])
        var live = LiveTranscriptionPreferences(defaults: self.defaults)
        live.addedProviders = [.soniox]
        try self.store(keychain).setProviderAPIKey("openai-key", for: "openai")
        try self.store(keychain).setProviderAPIKey("soniox-key", for: "soniox")
        try self.store(keychain).setProviderAPIKey("groq-key", for: "groq")
        XCTAssertEqual(LiveTranscriptionPreferences(defaults: self.defaults).addedProviders, [.soniox, .openAI])
    }

    func testSavingClearsBothVerificationRecordsOfThatProviderOnly() throws {
        let keychain = FakeKeychain(["openai": "old", "groq": "groq-key"])
        let store = self.store(keychain)
        SettingsStore.setVerifiedProviderFingerprints(["openai": "text", "groq": "text"], in: self.defaults)
        store.verifiedSpeechProviders = ["openai": "speech", "soniox": "speech"]

        try store.setProviderAPIKey("new", for: "openai")

        XCTAssertEqual(SettingsStore.verifiedProviderFingerprints(in: self.defaults), ["groq": "text"])
        XCTAssertEqual(store.verifiedSpeechProviders, ["soniox": "speech"])
    }

    func testRemovalDeletesAllFourKindsOfEntry() throws {
        let keychain = FakeKeychain([
            "openai": "text",
            "speech-key.openai": "voice",
            "live-transcription.openAI": "voice",
            "groq": "groq-key",
            "openrouter-transcription": "router-voice",
        ])
        var live = LiveTranscriptionPreferences(defaults: self.defaults)
        live.addedProviders = [.openAI, .soniox]

        try self.store(keychain).setProviderAPIKey(nil, for: "openai")

        XCTAssertEqual(keychain.storage, ["groq": "groq-key", "openrouter-transcription": "router-voice", "openrouter": "router-voice"])
        XCTAssertEqual(LiveTranscriptionPreferences(defaults: self.defaults).addedProviders, [.soniox])
    }

    func testRemovingTheActiveLiveProvidersKeySetsTheEngineToLocalAndResetsFluidMeet() throws {
        let keychain = FakeKeychain(["deepgram": "deepgram-key"])
        var cloud = CloudTranscriptionPreferences(defaults: self.defaults)
        cloud.source = .liveCloud
        var live = LiveTranscriptionPreferences(defaults: self.defaults)
        live.activeProvider = .deepgram
        live.addedProviders = [.deepgram]
        SettingsStore.setMeetingTranscriptionBackendID(.liveCloudNemotron, in: self.defaults)
        SettingsStore.setMeetingLiveCloudProvider(.deepgram, in: self.defaults)

        let change = try self.store(keychain).setProviderAPIKey(nil, for: "deepgram")

        XCTAssertTrue(change.affectedActiveEngine)
        XCTAssertEqual(CloudTranscriptionPreferences(defaults: self.defaults).source, .local)
        XCTAssertNil(LiveTranscriptionPreferences(defaults: self.defaults).activeProvider)
        XCTAssertEqual(SettingsStore.meetingTranscriptionBackendID(in: self.defaults), .parakeetNemotron)
        XCTAssertNil(SettingsStore.meetingLiveCloudProvider(in: self.defaults))
    }

    func testRemovingAnotherProvidersKeyLeavesTheEngineAndFluidMeetAlone() throws {
        let keychain = FakeKeychain(["deepgram": "deepgram-key", "soniox": "soniox-key"])
        var cloud = CloudTranscriptionPreferences(defaults: self.defaults)
        cloud.source = .liveCloud
        var live = LiveTranscriptionPreferences(defaults: self.defaults)
        live.activeProvider = .deepgram
        SettingsStore.setMeetingTranscriptionBackendID(.liveCloudNemotron, in: self.defaults)
        SettingsStore.setMeetingLiveCloudProvider(.deepgram, in: self.defaults)

        let change = try self.store(keychain).setProviderAPIKey(nil, for: "soniox")

        XCTAssertFalse(change.affectedActiveEngine)
        XCTAssertEqual(CloudTranscriptionPreferences(defaults: self.defaults).source, .liveCloud)
        XCTAssertEqual(LiveTranscriptionPreferences(defaults: self.defaults).activeProvider, .deepgram)
        XCTAssertEqual(SettingsStore.meetingTranscriptionBackendID(in: self.defaults), .liveCloudNemotron)
        XCTAssertEqual(SettingsStore.meetingLiveCloudProvider(in: self.defaults), .deepgram)
    }

    func testRemovingOpenRouterEndsTheCloudEngineAndFluidMeetsCloudBackend() throws {
        let keychain = FakeKeychain(["openrouter": "router-key", "openrouter-transcription": "router-key"])
        var cloud = CloudTranscriptionPreferences(defaults: self.defaults)
        cloud.source = .cloud
        SettingsStore.setMeetingTranscriptionBackendID(.openRouterNemotron, in: self.defaults)

        let change = try self.store(keychain).setProviderAPIKey(nil, for: "openrouter")

        XCTAssertTrue(change.affectedActiveEngine)
        XCTAssertEqual(CloudTranscriptionPreferences(defaults: self.defaults).source, .local)
        XCTAssertEqual(SettingsStore.meetingTranscriptionBackendID(in: self.defaults), .parakeetNemotron)
        XCTAssertEqual(keychain.storage, [:])
    }

    func testRemovingTheStoredCloudProviderResetsItToOpenRouter() throws {
        let keychain = FakeKeychain(["deepgram": "deepgram-key"])
        var cloud = CloudTranscriptionPreferences(defaults: self.defaults)
        cloud.providerID = "deepgram"
        try self.store(keychain).setProviderAPIKey(nil, for: "deepgram")
        XCTAssertEqual(CloudTranscriptionPreferences(defaults: self.defaults).providerID, "openrouter")
        XCTAssertEqual(CloudTranscriptionPreferences(defaults: self.defaults).source, .local)
    }

    func testTheNotificationCarriesTheProviderAndWhetherItWasRemoved() throws {
        let keychain = FakeKeychain([:])
        var received: [ProviderAPIKeyChange] = []
        let observer = self.notificationCenter.addObserver(forName: .providerAPIKeyChanged, object: nil, queue: nil) { notification in
            if let change = ProviderAPIKeyChange(notification) { received.append(change) }
        }
        defer { self.notificationCenter.removeObserver(observer) }

        try self.store(keychain).setProviderAPIKey("key", for: "elevenlabs")
        try self.store(keychain).setProviderAPIKey(nil, for: "elevenlabs")
        try self.store(keychain).setProviderAPIKey("", for: "local-server")

        XCTAssertEqual(received, [
            ProviderAPIKeyChange(providerID: "elevenlabs", removed: false, affectedActiveEngine: false),
            ProviderAPIKeyChange(providerID: "elevenlabs", removed: true, affectedActiveEngine: false),
            ProviderAPIKeyChange(providerID: "custom:local-server", removed: true, affectedActiveEngine: false),
        ])
    }

    func testAFailedWriteChangesNothingAndPostsNothing() {
        let keychain = FakeKeychain(["deepgram": "deepgram-key"])
        self.defaults.set(true, forKey: ProviderKeyMigration.flagKey)
        keychain.failSaves = true
        var cloud = CloudTranscriptionPreferences(defaults: self.defaults)
        cloud.source = .liveCloud
        var live = LiveTranscriptionPreferences(defaults: self.defaults)
        live.activeProvider = .deepgram
        var posted = false
        let observer = self.notificationCenter.addObserver(forName: .providerAPIKeyChanged, object: nil, queue: nil) { _ in posted = true }
        defer { self.notificationCenter.removeObserver(observer) }

        XCTAssertThrowsError(try self.store(keychain).setProviderAPIKey(nil, for: "deepgram"))

        XCTAssertFalse(posted)
        XCTAssertEqual(keychain.storage, ["deepgram": "deepgram-key"])
        XCTAssertEqual(CloudTranscriptionPreferences(defaults: self.defaults).source, .liveCloud)
    }

    // MARK: - Speech verification (VER-1)

    func testASpeechCheckWritesOnlyTheSpeechRecordForTheCurrentKey() throws {
        let keychain = FakeKeychain(["openai": "openai-key"])
        let store = self.store(keychain)

        store.recordSpeechVerification(for: "openai")

        XCTAssertTrue(store.isSpeechVerified("openai"))
        XCTAssertEqual(store.verifiedSpeechProviders["openai"], ProviderKeyStore.speechFingerprint(providerID: "openai", apiKey: "openai-key"))
        XCTAssertEqual(SettingsStore.verifiedProviderFingerprints(in: self.defaults), [:])
        XCTAssertEqual(self.defaults.dictionary(forKey: "VerifiedSpeechProvidersV1") as? [String: String], store.verifiedSpeechProviders)

        keychain.storage["openai"] = "rotated-elsewhere"
        try keychain.service.refreshCachedKeys()
        XCTAssertFalse(store.isSpeechVerified("openai"))
    }

    func testATextVerificationLeavesTheSpeechRecordEmpty() {
        let store = self.store(FakeKeychain(["openai": "openai-key"]))
        SettingsStore.setVerifiedProviderFingerprints(["openai": "text"], in: self.defaults)
        XCTAssertEqual(store.verifiedSpeechProviders, [:])
        XCTAssertFalse(store.isSpeechVerified("openai"))
    }

    func testNoKeyIsNeverSpeechVerified() {
        let store = self.store(FakeKeychain([:]))
        store.recordSpeechVerification(for: "soniox")
        XCTAssertEqual(store.verifiedSpeechProviders, [:])
        XCTAssertFalse(store.isSpeechVerified("soniox"))
    }

    // MARK: - Cloud provider preference (VE-5b)

    func testTheCloudProviderDefaultsToOpenRouter() {
        var cloud = CloudTranscriptionPreferences(defaults: self.defaults)
        XCTAssertEqual(cloud.providerID, "openrouter")
        cloud.providerID = "deepgram"
        XCTAssertEqual(self.defaults.string(forKey: "CloudTranscriptionProvider"), "deepgram")
        self.defaults.set("  ", forKey: "CloudTranscriptionProvider")
        XCTAssertEqual(CloudTranscriptionPreferences(defaults: self.defaults).providerID, "openrouter")
    }
}

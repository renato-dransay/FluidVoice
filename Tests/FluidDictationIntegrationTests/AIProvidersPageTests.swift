@testable import FluidVoice_Debug
import Foundation
import XCTest

/// The AI Providers page (spec section 9) and its verification rules (section 7), against an in-memory
/// Keychain and a private defaults suite. Nothing here reads or writes the app's own stores.
@MainActor
final class AIProvidersPageTests: XCTestCase {
    /// The Keychain aggregate in memory. The service keeps it alive for as long as a store uses it.
    private final class FakeKeychain {
        var storage: [String: String]
        private(set) var service: KeychainService!

        init(_ storage: [String: String]) {
            self.storage = storage
            self.service = KeychainService(
                testingLoad: { self.storage },
                testingSave: { values in self.storage = values }
            )
        }
    }

    private struct CheckFailure: Error {}

    private var suiteName = ""
    private var defaults: UserDefaults!
    private var notificationCenter: NotificationCenter!

    override func setUpWithError() throws {
        self.suiteName = "AIProvidersPageTests.\(UUID().uuidString)"
        self.defaults = try XCTUnwrap(UserDefaults(suiteName: self.suiteName))
        self.defaults.set(true, forKey: ProviderKeyMigration.flagKey)
        self.notificationCenter = NotificationCenter()
    }

    override func tearDown() {
        self.defaults.removePersistentDomain(forName: self.suiteName)
        super.tearDown()
    }

    private func store(_ keychain: FakeKeychain) -> ProviderKeyStore {
        ProviderKeyStore(defaults: self.defaults, keychain: keychain.service, notificationCenter: self.notificationCenter)
    }

    private typealias Row = AIEnhancementSettingsViewModel.ProviderItemData

    // MARK: - Rows (AIP-0, AIP-2, AIP-3)

    func testASpeechOnlyProviderWithAKeyIsARowAndNeverATextProvider() {
        let textRows = [Row(id: "openai", name: "OpenAI", isBuiltIn: true)]
        let rows = AIEnhancementSettingsViewModel.providerRows(
            textRows: textRows,
            apiKeys: ["openai": "o", "deepgram": "d", "soniox": "  ", "speech-key.openai": "v"]
        )

        XCTAssertEqual(rows.map(\.id), ["deepgram", "openai"], "Rows are sorted by name; a blank key adds no row")
        XCTAssertFalse(ModelRepository.shared.builtInProvidersList().contains { $0.id == "deepgram" })
        XCTAssertFalse(ProviderRegistry.providers(with: .text).contains { $0.id == "deepgram" })
        XCTAssertFalse(AIProviderListFilter.text.matches(AIProviderCatalog.capabilities(for: "deepgram")))
        XCTAssertTrue(AIProviderCatalog.isSpeechOnly("deepgram"))
        XCTAssertFalse(AIProviderCatalog.isSpeechOnly("openai"))
        XCTAssertFalse(AIProviderCatalog.isSpeechOnly("some-custom-id"), "A custom provider has Text")
    }

    func testRowsTagCapabilitiesInOrderAndTheFilterAppearsAboveSixRows() {
        XCTAssertEqual(ProviderCapability.ordered([.liveTranscription, .text]).map(\.title), ["Text", "Live"])
        XCTAssertEqual(ProviderCapability.ordered(AIProviderCatalog.capabilities(for: "openrouter")).map(\.title), ["Text", "Cloud transcription"])
        XCTAssertEqual(AIProviderCatalog.capabilities(for: "a-custom-provider"), [.text])
        XCTAssertFalse(AIProviderListFilter.isShown(rowCount: 6))
        XCTAssertTrue(AIProviderListFilter.isShown(rowCount: 7))
        XCTAssertEqual(AIProviderListFilter.allCases.map(\.rawValue), ["All", "Text", "Transcription", "Live"])
        XCTAssertTrue(AIProviderListFilter.transcription.matches([.cloudTranscription]))
        XCTAssertFalse(AIProviderListFilter.transcription.matches([.liveTranscription]))
        XCTAssertTrue(AIProviderListFilter.live.matches(AIProviderCatalog.capabilities(for: "openai")))
    }

    // MARK: - Add sheet (AIP-4, NAV-3)

    func testTheAddGridListsUnconnectedProvidersAndFiltersByCapability() {
        let all = AIProviderCatalog.addableProviders(capability: nil, connectedProviderIDs: ["openai", "deepgram"])
        XCTAssertFalse(all.contains { $0.id == "openai" || $0.id == "deepgram" })
        XCTAssertTrue(all.contains { $0.id == "soniox" } && all.contains { $0.id == "anthropic" })

        let live = AIProviderCatalog.addableProviders(capability: .liveTranscription, connectedProviderIDs: ["deepgram"])
        XCTAssertEqual(Set(live.map(\.id)), ["openai", "mistral", "assemblyai", "soniox", "elevenlabs", "speechmatics", "gladia"])

        XCTAssertTrue(AIProviderCatalog.offersCustomProvider(for: nil))
        XCTAssertTrue(AIProviderCatalog.offersCustomProvider(for: .text))
        XCTAssertFalse(AIProviderCatalog.offersCustomProvider(for: .liveTranscription))
        XCTAssertFalse(AIProviderCatalog.offersCustomProvider(for: .cloudTranscription))
    }

    func testTilesNameWhatEachProviderCanDo() {
        XCTAssertEqual(AIProviderCatalog.capabilitySummary(for: "anthropic"), "Text")
        XCTAssertEqual(AIProviderCatalog.capabilitySummary(for: "openai"), "Text · Live")
        XCTAssertEqual(AIProviderCatalog.capabilitySummary(for: "openrouter"), "Text · Cloud transcription")
        XCTAssertEqual(AIProviderCatalog.capabilitySummary(for: "soniox"), "Live")
        XCTAssertEqual(AIProviderCatalog.capabilitySummary(for: "ollama"), "Local connection")
        XCTAssertEqual(AIProviderCatalog.capabilitySummary(for: "lmstudio"), "Local connection")
    }

    func testTheKeyFieldLinkIsAKeyPageOrASetupGuide() {
        XCTAssertEqual(AIProviderCatalog.keyLink(for: "openai")?.title, "Get an API key")
        XCTAssertEqual(AIProviderCatalog.keyLink(for: "ollama")?.title, "Setup guide")
        XCTAssertEqual(AIProviderCatalog.keyLink(for: "lmstudio")?.title, "Setup guide")
        XCTAssertEqual(AIProviderCatalog.keyLink(for: "deepgram")?.title, "Get an API key")
        XCTAssertEqual(AIProviderCatalog.keyLink(for: "deepgram")?.url, ProviderRegistry.descriptor(for: "deepgram")?.keyURL)
        XCTAssertNil(AIProviderCatalog.keyLink(for: "a-custom-provider"))
        XCTAssertTrue(AIProviderCatalog.requiresAPIKey("deepgram"))
        XCTAssertFalse(AIProviderCatalog.requiresAPIKey("ollama"))
        XCTAssertFalse(AIProviderCatalog.requiresAPIKey("a-custom-provider"), "A custom provider's key is optional")
    }

    func testAddingASpeechOnlyProviderWritesOnlyItsKeyAndLeavesTheTextProviderAlone() throws {
        let keychain = FakeKeychain(["openai": "openai-key"])
        self.defaults.set("openai", forKey: "SelectedProviderID")
        let defaultsBefore = self.defaults.persistentDomain(forName: self.suiteName) ?? [:]

        try self.store(keychain).setProviderAPIKey("deepgram-key", for: "deepgram")

        XCTAssertEqual(keychain.storage, ["openai": "openai-key", "deepgram": "deepgram-key"])
        XCTAssertEqual(self.defaults.string(forKey: "SelectedProviderID"), "openai")
        XCTAssertNil(self.defaults.object(forKey: "SavedProviders"))
        XCTAssertNil(self.defaults.object(forKey: AIEnhancementSettingsViewModel.addedProviderIDsKey))
        // The only other change is the live list, which an older build still reads.
        let changed = Set((self.defaults.persistentDomain(forName: self.suiteName) ?? [:]).keys).subtracting(defaultsBefore.keys)
        XCTAssertEqual(changed, ["LiveTranscriptionProviders"])
    }

    func testRemovingASpeechOnlyProviderRunsTheRemovalEffects() throws {
        let keychain = FakeKeychain(["deepgram": "deepgram-key"])
        var cloud = CloudTranscriptionPreferences(defaults: self.defaults)
        cloud.source = .liveCloud
        var live = LiveTranscriptionPreferences(defaults: self.defaults)
        live.activeProvider = .deepgram
        SettingsStore.setMeetingTranscriptionBackendID(.liveCloudNemotron, in: self.defaults)
        SettingsStore.setMeetingLiveCloudProvider(.deepgram, in: self.defaults)
        let store = self.store(keychain)

        let impact = store.removalImpact(for: "deepgram")
        XCTAssertEqual(impact, ProviderRemovalImpact(switchesDictationToLocal: true, switchesFluidMeetToLocal: true))
        try store.setProviderAPIKey(nil, for: "deepgram")

        XCTAssertEqual(keychain.storage, [:])
        XCTAssertEqual(CloudTranscriptionPreferences(defaults: self.defaults).source, .local)
        XCTAssertNil(LiveTranscriptionPreferences(defaults: self.defaults).activeProvider)
        XCTAssertEqual(SettingsStore.meetingTranscriptionBackendID(in: self.defaults), .parakeetNemotron)
        XCTAssertEqual(AIEnhancementSettingsViewModel.providerRows(textRows: [], apiKeys: keychain.storage), [])
    }

    // MARK: - Removal rules (KEY-6)

    func testRemovalAsksFirstOnlyWhenDictationOrFluidMeetUsesTheProvider() {
        let store = self.store(FakeKeychain(["soniox": "s", "openrouter": "r"]))
        XCTAssertFalse(store.removalImpact(for: "soniox").needsConfirmation)

        var cloud = CloudTranscriptionPreferences(defaults: self.defaults)
        cloud.source = .cloud
        let dictation = store.removalImpact(for: "openrouter")
        XCTAssertEqual(dictation.confirmationTitle(providerName: "OpenRouter"), "Remove OpenRouter?")
        XCTAssertEqual(dictation.confirmationMessage, "Dictation switches to your selected local model.")

        SettingsStore.setMeetingTranscriptionBackendID(.openRouterNemotron, in: self.defaults)
        XCTAssertEqual(
            store.removalImpact(for: "openrouter").confirmationMessage,
            "Dictation switches to your selected local model. FluidMeet transcription switches to Local."
        )
        cloud.source = .local
        XCTAssertEqual(store.removalImpact(for: "openrouter").confirmationMessage, "FluidMeet transcription switches to Local.")
    }

    // MARK: - Two keys (KEY-3)

    func testUsingTheTextKeyEverywhereEndsTheSecondKeyAndItsSpeechVerification() throws {
        let keychain = FakeKeychain([
            "openai": "text-key",
            "speech-key.openai": "voice-key",
            "live-transcription.openAI": "voice-key",
        ])
        let store = self.store(keychain)
        store.recordSpeechVerification(for: "openai")
        SettingsStore.setVerifiedProviderFingerprints(["openai": "text"], in: self.defaults)
        XCTAssertTrue(store.hasSeparateSpeechKey("openai"))
        var received: [ProviderAPIKeyChange] = []
        let observer = self.notificationCenter.addObserver(forName: .providerAPIKeyChanged, object: nil, queue: nil) { note in
            if let change = ProviderAPIKeyChange(note) { received.append(change) }
        }
        defer { self.notificationCenter.removeObserver(observer) }

        try store.useTextKeyEverywhere(for: "openai")

        XCTAssertFalse(store.hasSeparateSpeechKey("openai"))
        XCTAssertEqual(keychain.storage, ["openai": "text-key", "live-transcription.openAI": "text-key"])
        XCTAssertEqual(store.speechAPIKey(for: "openai"), "text-key")
        XCTAssertEqual(store.verifiedSpeechProviders, [:])
        XCTAssertEqual(SettingsStore.verifiedProviderFingerprints(in: self.defaults), ["openai": "text"])
        XCTAssertEqual(received, [ProviderAPIKeyChange(providerID: "openai", removed: false, affectedActiveEngine: false)])
    }

    func testUsingTheVoiceEngineKeyEverywhereMovesItToTheTextEntryAndClearsTheTextVerification() throws {
        let keychain = FakeKeychain([
            "openrouter": "text-key",
            "speech-key.openrouter": "voice-key",
            "openrouter-transcription": "voice-key",
        ])
        let store = self.store(keychain)
        SettingsStore.setVerifiedProviderFingerprints(["openrouter": "text", "groq": "text"], in: self.defaults)
        store.recordSpeechVerification(for: "openrouter")
        let speechRecord = store.verifiedSpeechProviders

        try store.useSpeechKeyEverywhere(for: "openrouter")

        XCTAssertEqual(keychain.storage, ["openrouter": "voice-key", "openrouter-transcription": "voice-key"])
        XCTAssertEqual(store.apiKey(for: "openrouter"), "voice-key")
        XCTAssertEqual(SettingsStore.verifiedProviderFingerprints(in: self.defaults), ["groq": "text"])
        XCTAssertEqual(store.verifiedSpeechProviders, speechRecord, "The speech key did not change")
        XCTAssertTrue(store.isSpeechVerified("openrouter"))
    }

    // MARK: - Verification (VER-1, VER-2, VER-4, VER-5)

    func testASpeechCheckInAIProvidersWritesOnlyTheSpeechRecord() async {
        let store = self.store(FakeKeychain(["openai": "openai-key"]))
        var checked: [(LiveTranscriptionProviderID, String)] = []

        let result = await SpeechProviderVerification.verify(providerID: "openai", store: store) { provider, key in
            checked.append((provider, key))
        }

        XCTAssertEqual(result, .success("Verified."))
        XCTAssertEqual(checked.map(\.0), [.openAI])
        XCTAssertEqual(checked.map(\.1), ["openai-key"])
        XCTAssertTrue(store.isSpeechVerified("openai"))
        // The text record is what Command Mode, Edit and the dictation gate read.
        XCTAssertEqual(SettingsStore.verifiedProviderFingerprints(in: self.defaults), [:])
    }

    func testARejectedKeyClearsTheSpeechRecordAndOtherFailuresKeepIt() async {
        let keychain = FakeKeychain(["deepgram": "deepgram-key"])
        let store = self.store(keychain)
        store.recordSpeechVerification(for: "deepgram")

        let offline = await SpeechProviderVerification.verify(providerID: "deepgram", store: store) { _, _ in throw CheckFailure() }
        guard case .failure = offline else { return XCTFail("A failed check is a failure") }
        XCTAssertTrue(store.isSpeechVerified("deepgram"))

        let rejected = await SpeechProviderVerification.verify(providerID: "deepgram", store: store) { _, _ in
            throw LiveTranscriptionError.authentication
        }
        XCTAssertEqual(rejected, .failure(LiveTranscriptionError.authentication.message(providerName: "Deepgram")))
        XCTAssertFalse(store.isSpeechVerified("deepgram"))

        let noKey = await SpeechProviderVerification.verify(providerID: "soniox", store: store) { _, _ in
            XCTFail("No request without a key")
        }
        XCTAssertEqual(noKey, .failure("Add a Soniox API key first."))
    }

    func testChoosingAnotherModelKeepsAVerifiedProviderVerified() {
        XCTAssertEqual(AIEnhancementSettingsViewModel.connectionStatusAfterModelChange(isTextVerified: true), .success)
        XCTAssertEqual(AIEnhancementSettingsViewModel.connectionStatusAfterModelChange(isTextVerified: false), .unknown)
    }

    func testSetAsDefaultVerifiesFirstAndAFailedCheckLeavesTheDefault() async {
        var selected = "anthropic"
        var checks = 0
        let failed = await AIEnhancementSettingsViewModel.setDefaultAfterVerification(
            isVerified: false,
            verify: { checks += 1; return false },
            setDefault: { selected = "openai" }
        )
        XCTAssertFalse(failed)
        XCTAssertEqual(selected, "anthropic")
        XCTAssertEqual(checks, 1)

        let passed = await AIEnhancementSettingsViewModel.setDefaultAfterVerification(
            isVerified: false,
            verify: { checks += 1; return true },
            setDefault: { selected = "openai" }
        )
        XCTAssertTrue(passed)
        XCTAssertEqual(selected, "openai")

        let alreadyVerified = await AIEnhancementSettingsViewModel.setDefaultAfterVerification(
            isVerified: true,
            verify: { checks += 1; return false },
            setDefault: { selected = "groq" }
        )
        XCTAssertTrue(alreadyVerified)
        XCTAssertEqual(selected, "groq")
        XCTAssertEqual(checks, 2, "A verified provider sends no request")
    }

    func testTheDefaultMarkFollowsTheSelectedProviderWhateverTheStyle() {
        // The main shortcut's style is not an input: a custom style no longer hides the default.
        XCTAssertTrue(DictationDefaultProvider.isDefaultTextProvider("openai", selectedProviderID: "openai"))
        XCTAssertFalse(DictationDefaultProvider.isDefaultTextProvider("openai", selectedProviderID: "groq"))
    }

    func testSetupIssueAndTheBadgeShareOneVocabulary() {
        func issue(key: Bool = true, model: Bool = true, verified: Bool = false, failed: Bool = false) -> String? {
            DictationDefaultProvider.setupIssue(requiresAPIKey: true, hasAPIKey: key, hasModel: model, isVerified: verified, verificationFailed: failed)
        }
        XCTAssertEqual(issue(key: false), "API key missing")
        XCTAssertEqual(issue(model: false), "Choose a model")
        XCTAssertEqual(issue(failed: true), "Verification failed")
        XCTAssertEqual(issue(), "Not verified")
        XCTAssertNil(issue(verified: true))

        XCTAssertEqual(ProviderStatus.text(setupIssue: issue(key: false), isVerifying: false), .apiKeyMissing)
        XCTAssertEqual(ProviderStatus.text(setupIssue: issue(model: false), isVerifying: false), .chooseModel)
        XCTAssertEqual(ProviderStatus.text(setupIssue: issue(failed: true), isVerifying: false), .verificationFailed)
        XCTAssertEqual(ProviderStatus.text(setupIssue: issue(), isVerifying: false), .notVerified)
        XCTAssertEqual(ProviderStatus.text(setupIssue: nil, isVerifying: false), .verified)
        XCTAssertEqual(ProviderStatus.text(setupIssue: issue(), isVerifying: true), .verifying)

        XCTAssertEqual(ProviderStatus.speech(hasAPIKey: false, isVerifying: false, isVerified: false, verificationFailed: false), .apiKeyMissing)
        XCTAssertEqual(ProviderStatus.speech(hasAPIKey: true, isVerifying: false, isVerified: false, verificationFailed: false), .notVerified)
        XCTAssertEqual(ProviderStatus.speech(hasAPIKey: true, isVerifying: false, isVerified: true, verificationFailed: false), .verified)
        XCTAssertEqual(ProviderStatus.speech(hasAPIKey: true, isVerifying: false, isVerified: false, verificationFailed: true), .verificationFailed)
        XCTAssertEqual(ProviderStatus.speech(hasAPIKey: true, isVerifying: true, isVerified: true, verificationFailed: false), .verifying)

        XCTAssertEqual(ProviderStatus.allCases.map(\.text), [
            "API key missing", "Choose a model", "Not verified", "Verifying…", "Verified", "Verification failed",
        ])
        XCTAssertEqual(ProviderStatus.notVerified.systemImage, "circle.dashed")
        XCTAssertNil(ProviderStatus.verifying.systemImage)
    }

    // MARK: - Live cloud tab (VE-6)

    func testTheLiveTabConnectsProvidersByKeyPlusTheStoredActiveProvider() {
        let keys: Set<LiveTranscriptionProviderID> = [.deepgram, .openAI]
        let groups = LiveCloudProviderGroups.make(hasKey: { keys.contains($0) }, activeProvider: .soniox)

        XCTAssertEqual(Set(groups.connected), [.deepgram, .openAI, .soniox])
        XCTAssertEqual(Set(groups.connected + groups.notSetUp), Set(LiveTranscriptionProviderID.allCases))
        XCTAssertTrue(Set(groups.connected).isDisjoint(with: groups.notSetUp))
        XCTAssertEqual(LiveCloudProviderGroups.make(hasKey: { _ in false }, activeProvider: nil).connected, [])
    }
}

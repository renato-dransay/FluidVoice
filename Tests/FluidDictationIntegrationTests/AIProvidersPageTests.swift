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

    /// CLD-7, CLD-8: Mistral and AssemblyAI are built-in text providers that also transcribe, under their
    /// bare IDs. A key saved for them is a text row, never a second speech-only row.
    func testMistralAndAssemblyAIAreTextProvidersThatAlsoTranscribe() throws {
        for id in ["mistral", "assemblyai"] {
            XCTAssertTrue(ModelRepository.shared.isBuiltIn(id), id)
            XCTAssertTrue(ModelRepository.shared.builtInProvidersList().contains { $0.id == id }, id)
            XCTAssertFalse(AIProviderCatalog.isSpeechOnly(id), id)
            XCTAssertEqual(AIProviderCatalog.capabilitySummary(for: id), "Text · Cloud transcription · Live", id)
            XCTAssertEqual(ModelRepository.shared.providerKey(for: id), id)
            let live = try XCTUnwrap(ProviderRegistry.liveProviderID(for: id))
            XCTAssertEqual(AIProviderCatalog.keyLink(for: id)?.title, "Get an API key")
            XCTAssertEqual(AIProviderCatalog.keyLink(for: id)?.url, LiveTranscriptionCatalog.info(for: live).keyURL, "The key page comes from the live catalog")
        }
        XCTAssertEqual(ModelRepository.shared.defaultBaseURL(for: "mistral"), "https://api.mistral.ai/v1")
        XCTAssertEqual(ModelRepository.shared.defaultModels(for: "mistral").first, "mistral-small-latest")
        XCTAssertTrue(ModelRepository.listsModels(for: "mistral"))
        XCTAssertEqual(ModelRepository.shared.defaultBaseURL(for: "assemblyai"), "https://llm-gateway.assemblyai.com/v1")
        XCTAssertEqual(ModelRepository.shared.defaultModels(for: "assemblyai").first, "gpt-5-mini")
        XCTAssertFalse(ModelRepository.listsModels(for: "assemblyai"), "The LLM Gateway has no model list endpoint")
        XCTAssertEqual(ModelRepository.shared.displayName(for: "assemblyai"), "AssemblyAI")

        let rows = AIEnhancementSettingsViewModel.providerRows(textRows: [], apiKeys: ["mistral": "m", "assemblyai": "a", "deepgram": "d"])
        XCTAssertEqual(rows.map(\.id), ["deepgram"], "Text providers come through the text rows only")
    }

    /// AssemblyAI's fixed list stands in for a model listing and makes no request.
    func testAssemblyAIModelsComeFromTheFixedList() async throws {
        let models = try await ModelRepository.shared.fetchModels(for: "assemblyai", baseURL: "http://127.0.0.1:9/unreachable", apiKey: "k")
        XCTAssertEqual(models, ModelRepository.assemblyAIGatewayModels)
    }

    /// REG-7: a custom provider the user pointed at Mistral keeps its own entry; saving the built-in
    /// Mistral key neither merges with it nor touches its key.
    func testACustomProviderPointingAtMistralIsLeftAlone() throws {
        let custom = SettingsStore.SavedProvider(name: "Mistral", baseURL: "https://api.mistral.ai/v1", models: ["mistral-large-latest"])
        let customKey = ModelRepository.shared.providerKey(for: custom.id)
        XCTAssertEqual(customKey, "custom:\(custom.id)")
        XCTAssertNotEqual(customKey, "mistral")
        let keychain = FakeKeychain([customKey: "custom-mistral-key"])

        try self.store(keychain).setProviderAPIKey("built-in-mistral-key", for: "mistral")

        XCTAssertEqual(keychain.storage[customKey], "custom-mistral-key")
        XCTAssertEqual(keychain.storage["mistral"], "built-in-mistral-key")
        let rows = AIEnhancementSettingsViewModel.providerRows(
            textRows: [Row(id: custom.id, name: custom.name, isBuiltIn: false), Row(id: "mistral", name: "Mistral", isBuiltIn: true)],
            apiKeys: keychain.storage
        )
        XCTAssertEqual(Set(rows.map(\.id)), [custom.id, "mistral"], "Both stay as separate rows")
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
        XCTAssertEqual(AIProviderCatalog.capabilitySummary(for: "soniox"), "Cloud transcription · Live")
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
        store.recordSpeechVerification(for: "openai", checkedKey: store.speechAPIKey(for: "openai"))
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
        store.recordSpeechVerification(for: "openrouter", checkedKey: store.speechAPIKey(for: "openrouter"))
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
        store.recordSpeechVerification(for: "deepgram", checkedKey: store.speechAPIKey(for: "deepgram"))

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
        typealias Record = TextVerificationRecord
        let server = "https://api.openai.com/v1"
        let record = Record.recording([:], providerKey: "openai", baseURL: server, apiKey: "openai-key")
        func statusAfterModelChange(baseURL: String = server, apiKey: String = "openai-key", record: [String: String] = record) -> AIConnectionStatus {
            AIEnhancementSettingsViewModel.connectionStatusAfterModelChange(
                isTextVerified: Record.isVerified(record, providerKey: "openai", baseURL: baseURL, apiKey: apiKey)
            )
        }

        // The record holds server and key, not the model: a model change keeps the provider verified.
        XCTAssertEqual(statusAfterModelChange(), .success)
        XCTAssertEqual(statusAfterModelChange(apiKey: " openai-key "), .success, "Whitespace is not a different key")
        XCTAssertEqual(statusAfterModelChange(apiKey: "rotated-key"), .unknown)
        XCTAssertEqual(statusAfterModelChange(baseURL: "https://proxy.example.com/v1"), .unknown)
        XCTAssertEqual(statusAfterModelChange(record: [:]), .unknown)
        XCTAssertEqual(Record.recording([:], providerKey: "openai", baseURL: " ", apiKey: "k"), [:], "No server, no record")
        XCTAssertNotNil(Record.recording([:], providerKey: "ollama", baseURL: "http://localhost:11434/v1", apiKey: "")["ollama"],
                        "A local server verifies without a key")
    }

    func testASpeechVerifyWhoseKeyChangedDuringTheCheckRecordsNothing() async throws {
        let keychain = FakeKeychain(["deepgram": "dg-key"])
        let store = self.store(keychain)

        let result = await SpeechProviderVerification.verify(providerID: "deepgram", store: store) { _, _ in
            try store.setProviderAPIKey("dg-new", for: "deepgram")
        }

        XCTAssertEqual(result, .failure(SpeechProviderVerification.keyChangedMessage))
        XCTAssertFalse(store.isSpeechVerified("deepgram"), "Neither the old nor the new key is verified by it")
        XCTAssertEqual(store.verifiedSpeechProviders, [:])
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

    // MARK: - Emptying the key field (KEY-6)

    /// A custom provider keeps its key when the field is emptied unless its server is on this Mac: a
    /// server elsewhere on the network (10.x, 192.168.x, 172.16-31.x) may need its key.
    func testACustomProviderOnTheNetworkKeepsItsKeyWhenTheFieldIsEmptied() {
        typealias Model = AIEnhancementSettingsViewModel
        func keepsKey(_ baseURL: String, custom: Bool) -> Bool {
            Model.keepsSavedKeyWhenFieldIsEmptied(
                requiresAPIKey: false,
                isLocalServer: Model.isLocalServerForKeyRemoval(baseURL: baseURL, isCustomProvider: custom)
            )
        }

        for url in ["http://192.168.1.5:8080/v1", "http://10.0.0.2/v1", "http://172.20.0.3:1234/v1", "https://api.example.com/v1"] {
            XCTAssertTrue(keepsKey(url, custom: true), url)
        }
        for url in ["http://localhost:11434/v1", "http://127.0.0.1:1234/v1", "http://127.1.2.3/v1", "http://[::1]:8080/v1"] {
            XCTAssertFalse(keepsKey(url, custom: true), url)
        }
        XCTAssertFalse(keepsKey("http://192.168.1.5:11434/v1", custom: false), "Built-in local servers keep the wider rule")
        XCTAssertFalse(Model.isLoopbackEndpoint("http://127.example.com/v1"))
        XCTAssertFalse(Model.isLoopbackEndpoint("http://127.0.0.256/v1"))
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

    /// VE-6: the tab groups by the stored live provider, not the usable one, so an active provider whose key
    /// is gone stays under Connected (where its row offers `Set up in AI Providers`).
    func testTheLiveTabKeepsTheStoredActiveProviderConnectedWithoutItsKey() {
        var cloud = CloudTranscriptionPreferences(defaults: self.defaults)
        cloud.source = .liveCloud
        var live = LiveTranscriptionPreferences(defaults: self.defaults)
        live.activeProvider = .soniox

        XCTAssertEqual(SettingsStore.storedLiveProvider(in: self.defaults), .soniox)
        XCTAssertNil(
            SettingsStore.usableLiveProvider(storedSource: .liveCloud, activeProvider: .soniox, apiKey: { _ in "" }),
            "Without its key the provider is not usable, yet the tab still shows it"
        )
        XCTAssertEqual(LiveCloudProviderGroups.make(defaults: self.defaults, hasKey: { _ in false }).connected, [.soniox])

        cloud.source = .local
        XCTAssertNil(SettingsStore.storedLiveProvider(in: self.defaults))
        XCTAssertEqual(LiveCloudProviderGroups.make(defaults: self.defaults, hasKey: { _ in false }).connected, [])
    }
}

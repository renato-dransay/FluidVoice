@testable import FluidVoice_Debug
import Foundation
import XCTest

/// The Voice Engine page (spec section 10) and the screens phase 3 points at AI Providers (section 12),
/// against an in-memory Keychain and a private defaults suite. Nothing here reads or writes the app's
/// own stores or contacts a provider.
@MainActor
final class VoiceEngineSettingsTests: XCTestCase {
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

    private struct CheckFailure: LocalizedError {
        var errorDescription: String? { "The check failed." }
    }

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        self.suiteName = "VoiceEngineSettingsTests.\(UUID().uuidString)"
        self.defaults = try XCTUnwrap(UserDefaults(suiteName: self.suiteName))
        self.defaults.set(true, forKey: ProviderKeyMigration.flagKey)
    }

    override func tearDown() {
        self.defaults.removePersistentDomain(forName: self.suiteName)
        super.tearDown()
    }

    private func store(_ keychain: FakeKeychain) -> ProviderKeyStore {
        ProviderKeyStore(defaults: self.defaults, keychain: keychain.service, notificationCenter: NotificationCenter())
    }

    // MARK: - Header (VE-2)

    func testTheHeaderDescribesTheFiveEngineStates() {
        let keys = ["openrouter": "or-key", "soniox": "soniox-key"]
        let key: (String) -> String = { keys[$0] ?? "" }

        let local = VoiceEngineStatus.make(storedSource: .local, cloudProviderID: "openrouter", storedLiveProvider: nil, speechKey: key)
        XCTAssertEqual(local, VoiceEngineStatus(description: "Local", missingKeyProviderID: nil, tab: .local))

        let cloud = VoiceEngineStatus.make(storedSource: .cloud, cloudProviderID: "openrouter", storedLiveProvider: nil, speechKey: key)
        XCTAssertEqual(cloud, VoiceEngineStatus(description: "OpenRouter · Cloud", missingKeyProviderID: nil, tab: .cloud))

        let live = VoiceEngineStatus.make(storedSource: .liveCloud, cloudProviderID: "openrouter", storedLiveProvider: .soniox, speechKey: key)
        XCTAssertEqual(live, VoiceEngineStatus(description: "Soniox · Live cloud", missingKeyProviderID: nil, tab: .liveCloud))

        let liveWithoutKey = VoiceEngineStatus.make(storedSource: .liveCloud, cloudProviderID: "openrouter", storedLiveProvider: .deepgram, speechKey: key)
        XCTAssertEqual(liveWithoutKey.description, "Local. Deepgram is selected for Live cloud but its API key is missing.")
        XCTAssertEqual(liveWithoutKey.missingKeyProviderID, "deepgram")
        XCTAssertEqual(liveWithoutKey.tab, .liveCloud, "The page browses the Live cloud tab, where the missing key shows")

        let cloudWithoutKey = VoiceEngineStatus.make(storedSource: .cloud, cloudProviderID: "openrouter", storedLiveProvider: nil, speechKey: { _ in "" })
        XCTAssertEqual(cloudWithoutKey.description, "OpenRouter · Cloud. API key missing.")
        XCTAssertEqual(cloudWithoutKey.missingKeyProviderID, "openrouter")

        // A stored Live cloud choice without any provider reads as Local, as dictation does.
        let liveWithoutProvider = VoiceEngineStatus.make(storedSource: .liveCloud, cloudProviderID: "openrouter", storedLiveProvider: nil, speechKey: key)
        XCTAssertEqual(liveWithoutProvider.description, "Local")
        XCTAssertNil(liveWithoutProvider.missingKeyProviderID)
    }

    func testAMissingEngineKeyNamesItsProviderForTheDashboard() {
        let noKey: (String) -> String = { _ in "" }
        XCTAssertEqual(
            VoiceEngineStatus.make(storedSource: .cloud, cloudProviderID: "openrouter", storedLiveProvider: nil, speechKey: noKey).missingKeyMessage,
            "OpenRouter key required"
        )
        XCTAssertEqual(
            VoiceEngineStatus.make(storedSource: .liveCloud, cloudProviderID: "openrouter", storedLiveProvider: .soniox, speechKey: noKey).missingKeyMessage,
            "Soniox key required"
        )
        XCTAssertNil(VoiceEngineStatus.make(storedSource: .local, cloudProviderID: "openrouter", storedLiveProvider: nil, speechKey: noKey).missingKeyMessage)
        XCTAssertNil(VoiceEngineStatus.make(storedSource: .cloud, cloudProviderID: "openrouter", storedLiveProvider: nil, speechKey: { _ in "k" }).missingKeyMessage)
    }

    func testLiveRowShowsTestedOnlyAfterAPassedTest() {
        XCTAssertEqual(LiveCloudSettingsView.modelStatusLine(model: "Nova-3", testPassed: true), "Nova-3 · Tested")
        XCTAssertEqual(LiveCloudSettingsView.modelStatusLine(model: "Nova-3", testPassed: false), "Nova-3")
    }

    func testTheMissingLiveKeyStillBrowsesLiveCloudUnlessATabWasRequested() {
        let status = VoiceEngineStatus.make(storedSource: .liveCloud, cloudProviderID: "openrouter", storedLiveProvider: .deepgram, speechKey: { _ in "" })
        XCTAssertEqual(VoiceEngineSettingsViewModel.tabToBrowse(requested: nil, activeEngine: status.tab), .liveCloud)
        XCTAssertEqual(VoiceEngineSettingsViewModel.tabToBrowse(requested: .cloud, activeEngine: status.tab), .cloud)
    }

    // MARK: - Tabs, Local line and badge (VE-3, VE-8, VE-9)

    func testTheActiveTabCarriesACheckMarkAndTheCloudTabIsNamedCloud() {
        XCTAssertEqual(SpeechExecutionSource.allCases.map(\.displayName), ["Local", "Cloud", "Live cloud"])
        XCTAssertEqual(VoiceEngineSettingsView.tabTitle(for: .cloud, isActive: true), "Cloud ✓")
        XCTAssertEqual(VoiceEngineSettingsView.tabTitle(for: .liveCloud, isActive: false), "Live cloud")
    }

    func testTheLocalTabLineSaysWhoHandlesFilesUnderEachEngine() {
        XCTAssertEqual(
            VoiceEngineSettingsViewModel.selectedLocalModelCaption(engine: .cloud, cloudProviderName: "OpenRouter"),
            "Not in use. OpenRouter handles dictation, imported files and voice commands."
        )
        XCTAssertEqual(
            VoiceEngineSettingsViewModel.selectedLocalModelCaption(engine: .liveCloud, cloudProviderName: "OpenRouter"),
            "Used for imported files, and for dictation when you activate it."
        )
    }

    func testTheEngineBadgeNamesTheCloudVendor() {
        XCTAssertEqual(SettingsStore.dictationEngineBadge(cloudProviderName: "OpenRouter", liveProvider: nil), "OPENROUTER · CLOUD")
        XCTAssertEqual(SettingsStore.dictationEngineBadge(cloudProviderName: nil, liveProvider: .soniox), "SONIOX · LIVE")
    }

    // MARK: - Cloud tab (VE-5). `usesCombinedCloudDictation` (VE-5b) is covered by CloudTranscriptionSettingsTests.

    func testTheProviderMenuListsConnectedCloudProvidersFirst() {
        let connected = VoiceEngineSettingsViewModel.cloudProviderGroups(hasKey: { $0 == "openrouter" })
        XCTAssertEqual(connected.connected.map(\.id), ["openrouter"])
        XCTAssertEqual(connected.notSetUp.map(\.id), ["mistral", "assemblyai", "soniox", "deepgram", "elevenlabs", "speechmatics", "gladia"])

        let none = VoiceEngineSettingsViewModel.cloudProviderGroups(hasKey: { _ in false })
        XCTAssertEqual(none.connected.map(\.id), [])
        XCTAssertEqual(none.notSetUp.map(\.id), ProviderRegistry.providers(with: .cloudTranscription).map(\.id))
        XCTAssertTrue(none.notSetUp.map(\.id).contains("deepgram"))

        let two = VoiceEngineSettingsViewModel.cloudProviderGroups(hasKey: { ["openrouter", "elevenlabs"].contains($0) })
        XCTAssertEqual(two.connected.map(\.id), ["openrouter", "elevenlabs"])
        XCTAssertFalse(two.notSetUp.map(\.id).contains("elevenlabs"))
    }

    func testANonOpenRouterSpeechModelIsCaptionedByWhatItCanDo() {
        typealias Model = VoiceEngineSettingsViewModel
        let base = "Turns speech into text. Used for dictation, imported files and voice commands. Cleanup Styles run afterwards on your default text provider."
        XCTAssertEqual(Model.cloudSpeechModelCaptions(providerID: "deepgram", supportsWordTimings: true), [base])
        XCTAssertEqual(
            Model.cloudSpeechModelCaptions(providerID: "mistral", supportsWordTimings: false),
            [base, "Imported files are transcribed without speaker labels."]
        )
        XCTAssertEqual(
            Model.cloudSpeechModelCaptions(providerID: "soniox", supportsWordTimings: true),
            [base, "This provider answers after a short wait, so dictation feels slower than with Local or Live cloud."]
        )
        XCTAssertEqual(
            Model.cloudSpeechModelCaptions(providerID: "gladia", modelID: "solaria-3", supportsWordTimings: true).last,
            "Solaria-3 cannot detect the language. It needs English, French, German, Spanish or Italian as your Primary or Secondary language."
        )
        XCTAssertTrue(Model.cloudSpeechModelCaptions(providerID: "deepgram", modelID: "nova-3-medical", supportsWordTimings: true).last?.hasPrefix("English only.") == true)
        XCTAssertEqual(Model.cloudSpeechModelCaptions(providerID: "deepgram", modelID: "nova-3", supportsWordTimings: true), [base])
    }

    /// Like Speechmatics Live without a Primary language: a model that would fail every dictation never
    /// becomes the engine, and the check sends nothing.
    func testActivationRefusesAModelThatCannotTakeTheDictationLanguages() async {
        let store = self.store(FakeKeychain(["gladia": "gl-key"]))
        let recorder = CloudRequestRecorder()
        CloudURLProtocol.install { request in
            recorder.append(request)
            return (200, [:], Data())
        }
        let clients: (String) -> any CloudTranscriptionClient = { _ in GladiaTranscriptionClient(session: CloudURLProtocol.session()) }
        let outcome = await CloudEngineActivation(keyStore: store).activate(
            "gladia",
            check: { apiKey in
                try await VoiceEngineSettingsViewModel.checkCloudProvider(
                    "gladia", modelID: "solaria-3", apiKey: apiKey, languageIssue: .unsupportedLanguageForModel, clients: clients
                )
            },
            canSwitch: { true }
        )
        XCTAssertEqual(outcome, .failed(
            message: "Couldn't activate Gladia: This Gladia model doesn't support your dictation language. Choose another model or language in Voice Engine.",
            keyRejected: false
        ))
        XCTAssertTrue(recorder.requests.isEmpty)
        XCTAssertEqual(CloudTranscriptionPreferences(defaults: self.defaults).source, .local)
    }

    func testTheShownCloudProviderIsBrowsedThenStoredThenFirstConnected() {
        typealias Model = VoiceEngineSettingsViewModel
        XCTAssertEqual(Model.shownCloudProviderID(browsed: "b", stored: "a", connected: ["a", "b"]), "b")
        XCTAssertEqual(Model.shownCloudProviderID(browsed: "gone", stored: "a", connected: ["a", "b"]), "a")
        XCTAssertEqual(Model.shownCloudProviderID(browsed: nil, stored: "openrouter", connected: ["b"]), "b")
        XCTAssertNil(Model.shownCloudProviderID(browsed: nil, stored: "openrouter", connected: []))
    }

    func testActivateIsDisabledWithAReasonForAMissingKeyModelOrARecording() {
        typealias Model = VoiceEngineSettingsViewModel
        XCTAssertEqual(Model.cloudActivationBlocker(hasKey: false, hasModel: true, isBusy: false), "Add an API key in AI Providers first.")
        XCTAssertEqual(Model.cloudActivationBlocker(hasKey: true, hasModel: false, isBusy: false), "Choose a speech model first.")
        XCTAssertEqual(Model.cloudActivationBlocker(hasKey: true, hasModel: true, isBusy: true), "Finish the current recording first.")
        XCTAssertNil(Model.cloudActivationBlocker(hasKey: true, hasModel: true, isBusy: false))
    }

    // MARK: - Activation (VE-5a)

    func testAFailedActivationCheckChangesNeitherTheEngineNorTheCloudProvider() async {
        let keychain = FakeKeychain(["openrouter": "or-key", "deepgram": "dg-key"])
        var live = LiveTranscriptionPreferences(defaults: self.defaults)
        live.activeProvider = .deepgram
        var cloud = CloudTranscriptionPreferences(defaults: self.defaults)
        cloud.source = .liveCloud
        cloud.providerID = "someprovider"

        let outcome = await CloudEngineActivation(keyStore: self.store(keychain)).activate(
            "openrouter",
            check: { _ in throw CheckFailure() },
            canSwitch: { true }
        )

        XCTAssertEqual(outcome, .failed(message: "Couldn't activate OpenRouter: The check failed.", keyRejected: false))
        let after = CloudTranscriptionPreferences(defaults: self.defaults)
        XCTAssertEqual(after.source, .liveCloud)
        XCTAssertEqual(after.providerID, "someprovider")
        XCTAssertEqual(LiveTranscriptionPreferences(defaults: self.defaults).activeProvider, .deepgram)
        XCTAssertNil(self.defaults.dictionary(forKey: ProviderKeyStore.verifiedSpeechProvidersKey))
    }

    func testARejectedKeyClearsTheSpeechRecordAndSaysWhereToUpdateIt() async {
        let keychain = FakeKeychain(["openrouter": "or-key"])
        let store = self.store(keychain)
        store.recordSpeechVerification(for: "openrouter", checkedKey: store.speechAPIKey(for: "openrouter"))
        XCTAssertTrue(store.isSpeechVerified("openrouter"))

        let outcome = await CloudEngineActivation(keyStore: store).activate(
            "openrouter",
            check: { _ in throw CloudTranscriptionError.authentication },
            canSwitch: { true }
        )

        XCTAssertEqual(outcome, .failed(
            message: "Couldn't activate OpenRouter: OpenRouter rejected the API key. Update it in AI Providers and retry.",
            keyRejected: true
        ))
        XCTAssertFalse(store.isSpeechVerified("openrouter"))
        XCTAssertEqual(CloudTranscriptionPreferences(defaults: self.defaults).source, .local)
    }

    func testAPassedCheckSwitchesToCloudAndWritesOnlyTheSpeechRecord() async {
        let keychain = FakeKeychain(["openrouter": "or-key"])
        let store = self.store(keychain)
        var live = LiveTranscriptionPreferences(defaults: self.defaults)
        live.activeProvider = .soniox
        var checkedKey: String?

        let outcome = await CloudEngineActivation(keyStore: store).activate(
            "openrouter",
            check: { checkedKey = $0 },
            canSwitch: { true }
        )

        XCTAssertEqual(outcome, .activated)
        XCTAssertEqual(checkedKey, "or-key", "The check uses the provider's own speech key")
        let cloud = CloudTranscriptionPreferences(defaults: self.defaults)
        XCTAssertEqual(cloud.source, .cloud)
        XCTAssertEqual(cloud.providerID, "openrouter")
        XCTAssertNil(LiveTranscriptionPreferences(defaults: self.defaults).activeProvider, "Exactly one engine is active")
        XCTAssertTrue(store.isSpeechVerified("openrouter"))
        XCTAssertTrue(SettingsStore.verifiedProviderFingerprints(in: self.defaults).isEmpty, "A speech check never writes the text record")
    }

    func testActivatingDeepgramChecksItsKeyWithDeepgramOnly() async throws {
        let keychain = FakeKeychain(["openrouter": "or-key", "deepgram": "dg-key"])
        let store = self.store(keychain)
        let recorder = CloudRequestRecorder()
        CloudURLProtocol.install { request in
            recorder.append(request)
            return (200, [:], Data(#"{"projects":[]}"#.utf8))
        }
        let clients: (String) -> any CloudTranscriptionClient = { _ in DeepgramTranscriptionClient(session: CloudURLProtocol.session()) }

        let outcome = await CloudEngineActivation(keyStore: store).activate(
            "deepgram",
            check: { apiKey in try await VoiceEngineSettingsViewModel.checkCloudProvider("deepgram", modelID: "nova-3", apiKey: apiKey, clients: clients) },
            canSwitch: { true }
        )

        XCTAssertEqual(outcome, .activated)
        XCTAssertEqual(recorder.requests.map(\.url?.absoluteString), ["https://api.deepgram.com/v1/projects"])
        XCTAssertEqual(recorder.requests.first?.value(forHTTPHeaderField: "Authorization"), "Token dg-key")
        let cloud = CloudTranscriptionPreferences(defaults: self.defaults)
        XCTAssertEqual(cloud.source, .cloud)
        XCTAssertEqual(cloud.providerID, "deepgram")
        XCTAssertTrue(store.isSpeechVerified("deepgram"))
        XCTAssertFalse(SettingsStore.usesCombinedCloudDictation(source: cloud.source, cloudProviderID: cloud.providerID))
    }

    func testARejectedDeepgramKeyNamesDeepgramAndAnUnknownModelSendsNothing() async throws {
        let store = self.store(FakeKeychain(["deepgram": "dg-key"]))
        let recorder = CloudRequestRecorder()
        CloudURLProtocol.install { request in
            recorder.append(request)
            return (401, [:], Data("PRIVATE".utf8))
        }
        let clients: (String) -> any CloudTranscriptionClient = { _ in DeepgramTranscriptionClient(session: CloudURLProtocol.session()) }

        let rejected = await CloudEngineActivation(keyStore: store).activate(
            "deepgram",
            check: { apiKey in try await VoiceEngineSettingsViewModel.checkCloudProvider("deepgram", modelID: "nova-3", apiKey: apiKey, clients: clients) },
            canSwitch: { true }
        )
        XCTAssertEqual(rejected, .failed(
            message: "Couldn't activate Deepgram: Deepgram rejected the API key. Update it in AI Providers and retry.",
            keyRejected: true
        ))
        XCTAssertEqual(recorder.requests.count, 1)

        let unknownModel = await CloudEngineActivation(keyStore: store).activate(
            "deepgram",
            check: { apiKey in try await VoiceEngineSettingsViewModel.checkCloudProvider("deepgram", modelID: "nova-0", apiKey: apiKey, clients: clients) },
            canSwitch: { true }
        )
        XCTAssertEqual(unknownModel, .failed(
            message: "Couldn't activate Deepgram: The selected speech model is unavailable on Deepgram. Choose another model.",
            keyRejected: false
        ))
        XCTAssertEqual(recorder.requests.count, 1, "An unknown model fails before any request")
        XCTAssertEqual(CloudTranscriptionPreferences(defaults: self.defaults).source, .local)
    }

    func testActivationNeedsAKeyAndNeverSwitchesUnderARecording() async {
        let empty = await CloudEngineActivation(keyStore: self.store(FakeKeychain([:]))).activate(
            "openrouter",
            check: { _ in XCTFail("No request without a key") },
            canSwitch: { true }
        )
        XCTAssertEqual(empty, .failed(message: "Couldn't activate OpenRouter: Add an OpenRouter API key in AI Providers.", keyRejected: false))

        let keychain = FakeKeychain(["openrouter": "or-key"])
        let busy = await CloudEngineActivation(keyStore: self.store(keychain)).activate(
            "openrouter",
            check: { _ in },
            canSwitch: { false }
        )
        XCTAssertEqual(busy, .failed(message: "Couldn't activate OpenRouter: finish the current recording first.", keyRejected: false))
        XCTAssertEqual(CloudTranscriptionPreferences(defaults: self.defaults).source, .local)
    }

    func testUseLocalModelInsteadSetsLocalAndKeepsTheCloudProvider() {
        var cloud = CloudTranscriptionPreferences(defaults: self.defaults)
        cloud.source = .cloud
        cloud.providerID = "openrouter"

        CloudEngineActivation(keyStore: self.store(FakeKeychain(["openrouter": "k"]))).useLocalModelInstead()

        let after = CloudTranscriptionPreferences(defaults: self.defaults)
        XCTAssertEqual(after.source, .local)
        XCTAssertEqual(after.providerID, "openrouter")
    }

    func testACloudKeyReplacedDuringTheCheckIsNotActivated() async {
        let keychain = FakeKeychain(["openrouter": "or-key"])
        let store = self.store(keychain)

        let outcome = await CloudEngineActivation(keyStore: store).activate(
            "openrouter",
            check: { _ in try store.setProviderAPIKey("or-new", for: "openrouter") },
            canSwitch: { true }
        )

        XCTAssertEqual(outcome, .failed(message: "Couldn't activate OpenRouter: Voice settings changed during the check. Try again.", keyRejected: false))
        XCTAssertEqual(CloudTranscriptionPreferences(defaults: self.defaults).source, .local)
        XCTAssertFalse(store.isSpeechVerified("openrouter"), "The new key was never checked")
    }

    // MARK: - OpenRouter check (VE-5a)

    func testOpenRouterActivationNeedsBothChosenModelsListed() async {
        let listed: (String) async throws -> (speech: Set<String>, style: Set<String>) = { _ in (["speech-a"], ["style-a"]) }
        let chosen: () -> (speech: String, style: String) = { ("speech-a", "style-a") }
        do {
            try await VoiceEngineSettingsViewModel.checkOpenRouter(apiKey: "k", selectedModels: chosen, list: listed)
        } catch {
            XCTFail("Both models are listed: \(error)")
        }

        do {
            try await VoiceEngineSettingsViewModel.checkOpenRouter(apiKey: "k", selectedModels: { ("speech-b", "style-a") }, list: listed)
            XCTFail("An unlisted speech model must fail")
        } catch {
            XCTAssertEqual(error as? CloudActivationError, .speechModelUnavailable(providerName: "OpenRouter"))
        }

        do {
            try await VoiceEngineSettingsViewModel.checkOpenRouter(apiKey: "k", selectedModels: { ("speech-a", "style-b") }, list: listed)
            XCTFail("An unlisted style model must fail")
        } catch {
            XCTAssertEqual(error as? CloudActivationError, .styleModelUnavailable(providerName: "OpenRouter"))
        }
    }

    func testOpenRouterActivationListsWithTheCheckedKeyAndRefusesAModelChangedMeanwhile() async {
        var calls = 0
        var listedKeys: [String] = []
        do {
            try await VoiceEngineSettingsViewModel.checkOpenRouter(
                apiKey: "or-key",
                selectedModels: {
                    calls += 1
                    return calls == 1 ? ("speech-a", "style-a") : ("speech-b", "style-a")
                },
                list: { key in
                    listedKeys.append(key)
                    return (["speech-a", "speech-b"], ["style-a"])
                }
            )
            XCTFail("A model changed during the check must fail")
        } catch {
            XCTAssertEqual(error as? CloudActivationError, .settingsChanged)
        }
        XCTAssertEqual(listedKeys, ["or-key"])
    }

    // MARK: - Live activation (VE-5a)

    func testAPassedLiveCheckActivatesLiveCloudAndRecordsTheCheckedKey() async {
        let store = self.store(FakeKeychain(["soniox": "soniox-key", "openrouter": "or-key"]))
        var cloud = CloudTranscriptionPreferences(defaults: self.defaults)
        cloud.source = .cloud
        var checked: [String] = []

        let outcome = await LiveEngineActivation(keyStore: store).activate(.soniox, check: { _, key in checked.append(key) }, canSwitch: { true })

        XCTAssertEqual(outcome, .activated)
        XCTAssertEqual(checked, ["soniox-key"])
        XCTAssertEqual(CloudTranscriptionPreferences(defaults: self.defaults).source, .liveCloud)
        XCTAssertEqual(LiveTranscriptionPreferences(defaults: self.defaults).activeProvider, .soniox)
        XCTAssertTrue(store.isSpeechVerified("soniox"))
        XCTAssertTrue(SettingsStore.verifiedProviderFingerprints(in: self.defaults).isEmpty)
    }

    func testALiveKeyReplacedOrRemovedDuringTheCheckIsNotActivated() async throws {
        let keychain = FakeKeychain(["soniox": "soniox-key"])
        let store = self.store(keychain)

        let replaced = await LiveEngineActivation(keyStore: store).activate(
            .soniox,
            check: { _, _ in try store.setProviderAPIKey("soniox-new", for: "soniox") },
            canSwitch: { true }
        )
        XCTAssertEqual(replaced, .failed(message: "Couldn't activate Soniox: Voice settings changed during the check. Try again.", keyRejected: false))
        XCTAssertFalse(store.isSpeechVerified("soniox"), "The new key was never checked")
        XCTAssertNil(LiveTranscriptionPreferences(defaults: self.defaults).activeProvider)

        let removed = await LiveEngineActivation(keyStore: store).activate(
            .soniox,
            check: { _, _ in try store.setProviderAPIKey(nil, for: "soniox") },
            canSwitch: { true }
        )
        XCTAssertEqual(removed, .failed(message: "Couldn't activate Soniox: Voice settings changed during the check. Try again.", keyRejected: false))
        XCTAssertEqual(CloudTranscriptionPreferences(defaults: self.defaults).source, .local)
        XCTAssertNil(LiveTranscriptionPreferences(defaults: self.defaults).activeProvider)
    }

    func testARejectedLiveKeyClearsItsRecordOnlyWhileItIsStillSaved() async throws {
        let store = self.store(FakeKeychain(["deepgram": "dg-key"]))
        XCTAssertTrue(store.recordSpeechVerification(for: "deepgram", checkedKey: "dg-key"))

        let rejected = await LiveEngineActivation(keyStore: store).activate(
            .deepgram,
            check: { _, _ in throw LiveTranscriptionError.authentication },
            canSwitch: { true }
        )
        XCTAssertEqual(rejected, .failed(
            message: "Couldn't activate Deepgram: Deepgram rejected the API key. Update it in AI Providers and retry.",
            keyRejected: true
        ))
        XCTAssertFalse(store.isSpeechVerified("deepgram"))

        let missing = await LiveEngineActivation(keyStore: store).activate(.gladia, check: { _, _ in XCTFail("No request without a key") }, canSwitch: { true })
        XCTAssertEqual(missing, .failed(message: "Couldn't activate Gladia: Add a Gladia API key in AI Providers.", keyRejected: false))

        let busy = await LiveEngineActivation(keyStore: store).activate(.deepgram, check: { _, _ in }, canSwitch: { false })
        XCTAssertEqual(busy, .failed(message: "Couldn't activate Deepgram: finish the current recording first.", keyRejected: false))
        XCTAssertNil(LiveTranscriptionPreferences(defaults: self.defaults).activeProvider)
    }

    /// A rejection of a key that was replaced while the check ran says nothing about the saved key: no
    /// "Key rejected", and the new key's record stays.
    func testARejectionOfAKeyReplacedMidCheckIsNotReportedAsRejected() async throws {
        let store = self.store(FakeKeychain(["deepgram": "dg-old", "soniox": "sx-old"]))

        let live = await LiveEngineActivation(keyStore: store).activate(
            .deepgram,
            check: { _, _ in
                try store.setProviderAPIKey("dg-new", for: "deepgram")
                XCTAssertTrue(store.recordSpeechVerification(for: "deepgram", checkedKey: "dg-new"))
                throw LiveTranscriptionError.authentication
            },
            canSwitch: { true }
        )
        XCTAssertEqual(live, .failed(message: "Couldn't activate Deepgram: Voice settings changed during the check. Try again.", keyRejected: false))
        XCTAssertTrue(store.isSpeechVerified("deepgram"), "The new key's record is not cleared by the old key's rejection")

        let cloud = await CloudEngineActivation(keyStore: store).activate(
            "soniox",
            check: { _ in
                try store.setProviderAPIKey("sx-new", for: "soniox")
                throw CloudTranscriptionError.authentication
            },
            canSwitch: { true }
        )
        XCTAssertEqual(cloud, .failed(message: "Couldn't activate Soniox: Voice settings changed during the check. Try again.", keyRejected: false))
        XCTAssertEqual(CloudTranscriptionPreferences(defaults: self.defaults).source, .local)
    }

    func testResultsAreKeptOnlyForTheKeyThatIsStillSaved() {
        XCTAssertTrue(VoiceEngineSettingsViewModel.isStillSavedKey("or-key", current: "or-key"))
        XCTAssertFalse(VoiceEngineSettingsViewModel.isStillSavedKey("or-old", current: "or-new"))
        XCTAssertFalse(VoiceEngineSettingsViewModel.isStillSavedKey("or-old", current: ""))
        XCTAssertFalse(VoiceEngineSettingsViewModel.isStillSavedKey("", current: ""))
    }

    func testRemovalHelpNamesWhatBlocksIt() {
        let message = { (recording: Bool, activity: ASRExclusiveActivity?, downloading: Bool, preparing: Bool) in
            ASRService.speechEngineChangeBlockerMessage(isRecording: recording, activity: activity, isDownloadingModel: downloading, isPreparingModel: preparing)
        }
        XCTAssertEqual(message(true, .dictation, false, false), "Finish the current recording first.")
        XCTAssertEqual(message(false, .meeting, false, false), "Finish the current meeting first.")
        XCTAssertEqual(message(false, .fileTranscription, false, false), "Finish the current transcription first.")
        XCTAssertEqual(message(false, .localAPI, false, false), "Finish the current transcription first.")
        XCTAssertEqual(message(false, nil, true, false), "Wait for the model download to finish.")
        XCTAssertEqual(message(false, .modelMaintenance, false, false), "Wait for the speech model to finish loading.")
        XCTAssertEqual(message(false, nil, false, true), "Wait for the speech model to finish loading.")
        XCTAssertNil(message(false, nil, false, false))
    }

    func testTheUsedForCloudLineShowsThatProviderOnTheCloudTab() {
        XCTAssertEqual(AppNavigationDestination.usedFor(.cloudTranscription, providerID: "deepgram"), .voiceEngine(tab: .cloud, cloudProviderID: "deepgram"))
        XCTAssertEqual(AppNavigationDestination.usedFor(.liveTranscription, providerID: "deepgram"), .voiceEngine(tab: .liveCloud))
        XCTAssertNil(AppNavigationDestination.usedFor(.text, providerID: "deepgram"))
    }

    func testTheStyleTestNamesOneRemedyAtATime() {
        XCTAssertEqual(
            AIEnhancementSettingsView.combinedCloudPromptTestBlocker(hasOpenRouterKey: false, hasStyleModel: false),
            "Add an OpenRouter API key in AI Providers."
        )
        XCTAssertEqual(
            AIEnhancementSettingsView.combinedCloudPromptTestBlocker(hasOpenRouterKey: true, hasStyleModel: false),
            "Choose a style model in Voice Engine to test your style."
        )
        XCTAssertNil(AIEnhancementSettingsView.combinedCloudPromptTestBlocker(hasOpenRouterKey: true, hasStyleModel: true))
    }

    func testTheBenchmarkNamesTheModelThatServedTheRequest() {
        let speech = CloudTranscriptionConfiguration(providerID: "openrouter", modelID: "openai/whisper-large-v3")
        XCTAssertEqual(ASRService.cloudModelIDServingRequest(speech), "openai/whisper-large-v3")
        let styled = CloudTranscriptionConfiguration(
            providerID: "openrouter",
            modelID: "openai/whisper-large-v3",
            audioDictation: CloudAudioDictationInstructions(modelID: "google/gemini-3.8-flash", promptText: "Tidy")
        )
        XCTAssertEqual(ASRService.cloudModelIDServingRequest(styled), "google/gemini-3.8-flash")
        XCTAssertNil(ASRService.cloudModelIDServingRequest(nil))
    }

    func testNeitherEngineActivatesWhileTheOtherEnginesCheckRuns() {
        typealias Model = VoiceEngineSettingsViewModel
        let cloudRunning = Model.isEngineCheckRunning(cloudProviderBeingChecked: "openrouter", liveProviderBeingChecked: nil)
        let liveRunning = Model.isEngineCheckRunning(cloudProviderBeingChecked: nil, liveProviderBeingChecked: .soniox)
        XCTAssertTrue(cloudRunning)
        XCTAssertTrue(liveRunning)
        XCTAssertFalse(Model.isEngineCheckRunning(cloudProviderBeingChecked: nil, liveProviderBeingChecked: nil))

        XCTAssertNotNil(Model.liveActivationBlocker(isBusy: false, isEngineCheckRunning: cloudRunning), "A Cloud check blocks Live activation")
        XCTAssertNotNil(Model.cloudActivationBlocker(hasKey: true, hasModel: true, isBusy: liveRunning), "A Live check blocks Cloud activation")
        XCTAssertNotNil(Model.liveActivationBlocker(isBusy: true, isEngineCheckRunning: false))
        XCTAssertNil(Model.liveActivationBlocker(isBusy: false, isEngineCheckRunning: false))
    }

    // MARK: - Key changes (KEY-5)

    func testAKeyChangeForgetsWhatTheChecksSaidAboutThatProviderOnly() {
        var checks = VoiceEngineSettingsViewModel.EngineCheckResults(
            liveActivationStatus: [.openAI: "Couldn't activate OpenAI", .soniox: "Couldn't activate Soniox"],
            liveRejectedKeys: [.openAI, .soniox],
            cloudActivationStatus: ["openai": "x", "deepgram": "y"],
            cloudRejectedKeys: ["openai", "deepgram"]
        )

        let clearsCatalogs = checks.forget(after: ProviderAPIKeyChange(providerID: "openai", removed: true, affectedActiveEngine: false))

        XCTAssertFalse(clearsCatalogs)
        XCTAssertEqual(checks, VoiceEngineSettingsViewModel.EngineCheckResults(
            liveActivationStatus: [.soniox: "Couldn't activate Soniox"],
            liveRejectedKeys: [.soniox],
            cloudActivationStatus: ["deepgram": "y"],
            cloudRejectedKeys: ["deepgram"]
        ))
        XCTAssertTrue(checks.forget(after: ProviderAPIKeyChange(providerID: "openrouter", removed: false, affectedActiveEngine: false)))
    }

    // MARK: - FluidMeet and key messages (FM-3, COPY-2)

    func testFluidMeetLiveChoicesAreTheProvidersWithAKey() {
        let keys: Set<LiveTranscriptionProviderID> = [.speechmatics, .deepgram]
        XCTAssertEqual(SettingsStore.meetingLiveCloudProviderChoices(hasKey: { keys.contains($0) }), [.deepgram, .speechmatics])
        XCTAssertEqual(SettingsStore.meetingLiveCloudProviderChoices(hasKey: { _ in false }), [])
    }

    func testKeyErrorsSendTheUserToAIProviders() {
        XCTAssertEqual(CloudTranscriptionError.missingAPIKey.localizedDescription, "Add an OpenRouter API key in AI Providers.")
        XCTAssertEqual(CloudTranscriptionError.authentication.localizedDescription, "OpenRouter rejected the API key. Update it in AI Providers and retry.")
        XCTAssertEqual(LiveTranscriptionError.missingAPIKey.message(providerName: "Deepgram"), "Add a Deepgram API key in AI Providers.")
        XCTAssertEqual(LiveTranscriptionError.missingAPIKey.message(providerName: "AssemblyAI"), "Add an AssemblyAI API key in AI Providers.")
        XCTAssertEqual(LiveTranscriptionError.authentication.message(providerName: "Gladia"), "Gladia rejected the API key. Update it in AI Providers and retry.")
        XCTAssertEqual(MeetingCloudConfigurationError.missingAPIKey.localizedDescription, "Add an OpenRouter API key in AI Providers.")
        XCTAssertEqual(
            MeetingCloudCaptionText.failureMessage(.missingAPIKey, providerName: "Soniox"),
            "Live captions need a Soniox API key. Add it in AI Providers. Recording continues."
        )
    }

    func testAKeyErrorAlertKeepsOneRemedy() {
        let rejected = CloudTranscriptionError.authentication.localizedDescription
        XCTAssertEqual(ASRService.failedDictationMessage(rejected, error: CloudTranscriptionError.authentication), rejected)
        let missing = LiveTranscriptionError.missingAPIKey.message(providerName: "Soniox")
        XCTAssertEqual(ASRService.failedDictationMessage(missing, error: LiveTranscriptionError.missingAPIKey), missing)
        XCTAssertEqual(
            ASRService.failedDictationMessage("OpenRouter transcription timed out.", error: CloudTranscriptionError.timeout),
            "OpenRouter transcription timed out. Open Voice Engine settings to retry, transcribe locally, or discard the recording."
        )
    }
}

/// The rows of the one searchable model picker that Voice Engine's Cloud tab and Live cloud sheet share
/// with AI Providers: which models it offers, the second line each one shows, and which can be chosen.
final class SpeechModelPickerTests: XCTestCase {
    func testSearchMatchesIDNameAndSecondLine() {
        let items = [
            SearchableModelPickerItem(id: "nova-3", name: "Nova-3", detail: "Default"),
            SearchableModelPickerItem(id: "nova-3-medical", name: "Nova-3 Medical", detail: "English only · Medical terms"),
        ]
        XCTAssertEqual(SearchableModelPickerItem.filtered(items, query: "").map(\.id), ["nova-3", "nova-3-medical"])
        XCTAssertEqual(SearchableModelPickerItem.filtered(items, query: "MEDICAL").map(\.id), ["nova-3-medical"])
        XCTAssertEqual(SearchableModelPickerItem.filtered(items, query: "english").map(\.id), ["nova-3-medical"])
        XCTAssertEqual(SearchableModelPickerItem.filtered(items, query: " default ").map(\.id), ["nova-3"])
        XCTAssertTrue(SearchableModelPickerItem.filtered(items, query: "whisper").isEmpty)
    }

    func testCloudRowsMarkTheDefaultAndModelsWithoutWordTimings() {
        let deepgram = SpeechModelPickerItems.cloud(providerID: "deepgram", selected: "nova-3")
        XCTAssertEqual(deepgram.map(\.id), ["nova-3", "nova-2", "nova-3-medical"])
        XCTAssertEqual(deepgram.first?.detail, "Default")
        XCTAssertEqual(deepgram.last?.detail, "English only · Medical terms")
        XCTAssertTrue(deepgram.allSatisfy(\.isEnabled))
        let mistral = SpeechModelPickerItems.cloud(providerID: "mistral", selected: "voxtral-mini-latest")
        XCTAssertEqual(mistral.first?.detail, "Default · No word timings")
    }

    func testAStoredModelNoLongerListedStaysVisibleAsTheSelection() {
        let cloud = SpeechModelPickerItems.cloud(providerID: "deepgram", selected: "nova-0")
        XCTAssertEqual(cloud.first, SearchableModelPickerItem(id: "nova-0", name: "nova-0", detail: "No longer listed"))
        XCTAssertEqual(cloud.count, CloudTranscriptionCatalog.models(for: "deepgram").count + 1)
        let live = SpeechModelPickerItems.live(provider: .assemblyAI, selected: "retired-model")
        XCTAssertEqual(live.first?.id, "retired-model")
        XCTAssertEqual(SpeechModelPickerItems.live(provider: .assemblyAI, selected: "universal-3-6-pro").count, 4, "A listed selection adds no row")
    }

    func testLiveRowsCarryEachModelsNote() {
        let rows = SpeechModelPickerItems.live(provider: .assemblyAI, selected: "universal-3-6-pro")
        XCTAssertEqual(rows.map(\.id), LiveTranscriptionCatalog.info(for: .assemblyAI).models.map(\.id))
        XCTAssertEqual(rows.first?.detail, "Default")
        XCTAssertEqual(rows.last?.detail, "English only")
    }

    func testOpenRouterRowsKeepCheckedModelsOnlySelectableAndOfferAutomaticFirst() {
        let models = [
            CloudTranscriptionModel(id: CloudTranscriptionModel.defaultDictationID, name: "Whisper Large v3 Turbo", wordTimingSupport: .supported, languageHintProviderTags: []),
            CloudTranscriptionModel(id: "openai/gpt-4o-transcribe", name: "GPT-4o Transcribe", wordTimingSupport: .unsupported, languageHintProviderTags: []),
            CloudTranscriptionModel(id: "vendor/new", name: "New", wordTimingSupport: .unverified, languageHintProviderTags: []),
        ]
        let unchecked = SpeechModelPickerItems.openRouterSpeech(models: models, selected: CloudTranscriptionModel.defaultDictationID, validatedIDs: nil)
        XCTAssertEqual(unchecked.map(\.detail), ["Default", "No word timings", "Word timings not checked"])
        XCTAssertTrue(unchecked.allSatisfy(\.isEnabled), "Before a listing check every model stays selectable")
        let checked = SpeechModelPickerItems.openRouterSpeech(models: models, selected: CloudTranscriptionModel.defaultDictationID, validatedIDs: [CloudTranscriptionModel.defaultDictationID])
        XCTAssertEqual(checked.map(\.isEnabled), [true, false, false])
        XCTAssertEqual(checked.last?.detail, "Not offered for this key")

        let style = SpeechModelPickerItems.openRouterStyle(
            models: [CloudAudioDictationModel(id: "google/gemini-3.8-flash", name: "Gemini 3.8 Flash")],
            automaticName: "Gemini 3.8 Flash",
            validatedIDs: nil
        )
        XCTAssertEqual(style.map(\.id), [CloudAudioDictationModel.automaticID, "google/gemini-3.8-flash"])
        XCTAssertEqual(style.first?.name, "Automatic (Gemini 3.8 Flash)")
    }
}

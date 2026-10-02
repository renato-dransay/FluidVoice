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
        XCTAssertEqual(connected.notSetUp.map(\.id), [])

        let none = VoiceEngineSettingsViewModel.cloudProviderGroups(hasKey: { _ in false })
        XCTAssertEqual(none.connected.map(\.id), [])
        XCTAssertEqual(none.notSetUp.map(\.id), ["openrouter"], "OpenRouter is the only Cloud provider in this phase")
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
        store.recordSpeechVerification(for: "openrouter")
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

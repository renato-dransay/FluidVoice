#if canImport(LiveTranscriptionHarness)
@testable import LiveTranscriptionHarness
#else
@testable import FluidVoice_Debug
#endif
import XCTest

@MainActor
final class LiveCloudSettingsTests: XCTestCase {
    func testNewInstallationHasNoLiveProviders() throws {
        let (defaults, cleanup) = try self.defaults()
        defer { cleanup() }
        let preferences = LiveTranscriptionPreferences(defaults: defaults)
        XCTAssertEqual(preferences.addedProviders, [])
        XCTAssertNil(preferences.activeProvider)
        XCTAssertEqual(preferences.modelID(for: .soniox), "stt-rt-v5")
    }

    func testAddedProvidersKeepOrderWithoutDuplicatesAndIgnoreUnknownValues() throws {
        let (defaults, cleanup) = try self.defaults()
        defer { cleanup() }
        var preferences = LiveTranscriptionPreferences(defaults: defaults)
        preferences.addedProviders = [.deepgram, .soniox, .deepgram]
        XCTAssertEqual(preferences.addedProviders, [.deepgram, .soniox])
        defaults.set(["soniox", "retired-vendor"], forKey: "LiveTranscriptionProviders")
        XCTAssertEqual(LiveTranscriptionPreferences(defaults: defaults).addedProviders, [.soniox])
    }

    func testModelSelectionFallsBackToTheDefaultWhenWithdrawn() throws {
        let (defaults, cleanup) = try self.defaults()
        defer { cleanup() }
        var preferences = LiveTranscriptionPreferences(defaults: defaults)
        preferences.setModelID("universal-streaming-multilingual", for: .assemblyAI)
        XCTAssertEqual(preferences.modelID(for: .assemblyAI), "universal-streaming-multilingual")
        defaults.set("withdrawn-model", forKey: "LiveTranscriptionModel.assemblyAI")
        XCTAssertEqual(preferences.modelID(for: .assemblyAI), "universal-3-6-pro")
    }

    func testUnknownModelIsNotStored() throws {
        let (defaults, cleanup) = try self.defaults()
        defer { cleanup() }
        var preferences = LiveTranscriptionPreferences(defaults: defaults)
        preferences.setModelID("not-a-model", for: .deepgram)
        XCTAssertNil(defaults.string(forKey: "LiveTranscriptionModel.deepgram"))
        XCTAssertEqual(preferences.modelID(for: .deepgram), "nova-3")
    }

    func testActiveProviderRoundTripsAndIgnoresUnknownValues() throws {
        let (defaults, cleanup) = try self.defaults()
        defer { cleanup() }
        var preferences = LiveTranscriptionPreferences(defaults: defaults)
        preferences.activeProvider = .deepgram
        XCTAssertEqual(LiveTranscriptionPreferences(defaults: defaults).activeProvider, .deepgram)
        defaults.set("retired-vendor", forKey: "LiveTranscriptionActiveProvider")
        XCTAssertNil(LiveTranscriptionPreferences(defaults: defaults).activeProvider)
    }

    func testOlderSourceValuesKeepTheirMeaning() {
        XCTAssertEqual(SpeechExecutionSource(rawValue: "local"), .local)
        XCTAssertEqual(SpeechExecutionSource(rawValue: "openRouter"), .cloud)
        XCTAssertEqual(SpeechExecutionSource(rawValue: "liveCloud"), .liveCloud)
        XCTAssertEqual(SpeechExecutionSource.liveCloud.displayName, "Live cloud")
        XCTAssertEqual(SpeechExecutionSource.cloud.displayName, "Cloud")
    }

    func testStoredLocalAndOpenRouterSourcesAreKept() throws {
        XCTAssertEqual(try self.effectiveSource(stored: .local, activeProvider: .soniox, apiKey: "key"), .local)
        XCTAssertEqual(try self.effectiveSource(stored: .cloud, activeProvider: nil, apiKey: ""), .cloud)
        XCTAssertEqual(try self.effectiveSource(stored: .cloud, activeProvider: .soniox, apiKey: "key"), .cloud)
    }

    func testLiveCloudWithoutAnActiveProviderReadsAsLocal() throws {
        XCTAssertEqual(try self.effectiveSource(stored: .liveCloud, activeProvider: nil, apiKey: "key"), .local)
    }

    func testLiveCloudWithAnActiveProviderButNoSavedKeyReadsAsLocal() throws {
        XCTAssertEqual(try self.effectiveSource(stored: .liveCloud, activeProvider: .deepgram, apiKey: ""), .local)
    }

    func testLiveCloudWithAnActiveProviderAndASavedKeyReadsAsLiveCloud() throws {
        XCTAssertEqual(try self.effectiveSource(stored: .liveCloud, activeProvider: .deepgram, apiKey: "key"), .liveCloud)
        XCTAssertEqual(try self.usableProvider(stored: .liveCloud, activeProvider: .deepgram, apiKey: "key"), .deepgram)
    }

    func testNoLiveProviderIsUsableUnlessLiveCloudIsTheStoredSource() throws {
        XCTAssertNil(try self.usableProvider(stored: .local, activeProvider: .soniox, apiKey: "key"))
        XCTAssertNil(try self.usableProvider(stored: .cloud, activeProvider: .soniox, apiKey: "key"))
        XCTAssertNil(try self.usableProvider(stored: .liveCloud, activeProvider: nil, apiKey: "key"))
        XCTAssertNil(try self.usableProvider(stored: .liveCloud, activeProvider: .soniox, apiKey: ""))
    }

    /// Live keys are the providers' own entries, looked up by registry ID like every other key.
    func testTheKeyIsLookedUpForTheActiveProviderOnly() throws {
        let (defaults, cleanup) = try self.defaults()
        defer { cleanup() }
        var preferences = LiveTranscriptionPreferences(defaults: defaults)
        preferences.activeProvider = .assemblyAI
        var stored = ["soniox": "soniox-key"]
        let store = ProviderKeyStore(
            defaults: defaults,
            keychain: KeychainService(testingLoad: { stored }, testingSave: { stored = $0 })
        )
        let speechKey: (LiveTranscriptionProviderID) -> String = { store.speechAPIKey(for: ProviderRegistry.providerID(for: $0)) }
        XCTAssertNil(SettingsStore.usableLiveProvider(
            storedSource: .liveCloud,
            activeProvider: preferences.activeProvider,
            apiKey: speechKey
        ))
        stored["assemblyai"] = "assembly-key"
        try store.keychain.refreshCachedKeys()
        XCTAssertEqual(SettingsStore.usableLiveProvider(
            storedSource: .liveCloud,
            activeProvider: preferences.activeProvider,
            apiKey: speechKey
        ), .assemblyAI)
    }

    func testTheEngineBadgeNamesTheEngineThatReceivesTheAudio() {
        XCTAssertEqual(SettingsStore.dictationEngineBadge(cloudProviderName: nil, liveProvider: nil), "ON-DEVICE")
        XCTAssertEqual(SettingsStore.dictationEngineBadge(cloudProviderName: "OpenRouter", liveProvider: nil), "OPENROUTER · CLOUD")
        XCTAssertEqual(SettingsStore.dictationEngineBadge(cloudProviderName: nil, liveProvider: .deepgram), "DEEPGRAM · LIVE")
    }

    private func usableProvider(
        stored: SpeechExecutionSource,
        activeProvider: LiveTranscriptionProviderID?,
        apiKey: String
    ) throws -> LiveTranscriptionProviderID? {
        let (defaults, cleanup) = try self.defaults()
        defer { cleanup() }
        var cloud = CloudTranscriptionPreferences(defaults: defaults)
        cloud.source = stored
        var live = LiveTranscriptionPreferences(defaults: defaults)
        live.activeProvider = activeProvider
        return SettingsStore.usableLiveProvider(
            storedSource: cloud.source,
            activeProvider: live.activeProvider,
            apiKey: { _ in apiKey }
        )
    }

    private func effectiveSource(
        stored: SpeechExecutionSource,
        activeProvider: LiveTranscriptionProviderID?,
        apiKey: String
    ) throws -> SpeechExecutionSource {
        let provider = try self.usableProvider(stored: stored, activeProvider: activeProvider, apiKey: apiKey)
        return SpeechExecutionSource.effective(stored: stored, usableLiveProvider: provider)
    }

    func testLanguageSupportFollowsEachProvidersList() {
        let deepgram = LiveTranscriptionCatalog.info(for: .deepgram)
        XCTAssertTrue(deepgram.supports(languageCode: "pt"))
        XCTAssertFalse(deepgram.supports(languageCode: "pl"))
        XCTAssertTrue(LiveTranscriptionCatalog.info(for: .soniox).supports(languageCode: "pl"))
    }

    private func defaults() throws -> (UserDefaults, () -> Void) {
        let suite = "LiveCloudSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (defaults, { defaults.removePersistentDomain(forName: suite) })
    }
}

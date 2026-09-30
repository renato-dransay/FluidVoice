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
        XCTAssertEqual(SpeechExecutionSource(rawValue: "openRouter"), .openRouter)
        XCTAssertEqual(SpeechExecutionSource(rawValue: "liveCloud"), .liveCloud)
        XCTAssertEqual(SpeechExecutionSource.liveCloud.displayName, "Live cloud")
    }

    private func defaults() throws -> (UserDefaults, () -> Void) {
        let suite = "LiveCloudSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (defaults, { defaults.removePersistentDomain(forName: suite) })
    }
}

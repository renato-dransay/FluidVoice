#if canImport(CloudTranscriptionHarness)
@testable import CloudTranscriptionHarness
#else
@testable import FluidVoice_Debug
#endif
import XCTest

@MainActor
final class CloudTranscriptionSettingsTests: XCTestCase {
    func testNewInstallationStaysLocalAndUsesAutomaticLanguage() throws {
        let suite = "CloudTranscriptionSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = CloudTranscriptionPreferences(defaults: defaults)
        XCTAssertEqual(preferences.source, .local)
        XCTAssertEqual(preferences.configuration.modelID, "openai/whisper-large-v3-turbo")
        XCTAssertNil(preferences.configuration.languageCode)
        XCTAssertEqual(preferences.dictationMode, .transcriptionOnly)
        XCTAssertEqual(preferences.dictationModelID, CloudAudioDictationModel.defaultID)
        XCTAssertNil(preferences.configuration.audioDictation)
    }

    func testCapturedConfigurationDoesNotFollowLaterPreferenceChanges() throws {
        let suite = "CloudTranscriptionSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var preferences = CloudTranscriptionPreferences(defaults: defaults)
        preferences.source = .openRouter
        preferences.modelID = "openai/whisper-large-v3"
        preferences.languageCode = "pt"
        let snapshot = preferences.configuration
        preferences.modelID = "openai/gpt-4o-transcribe"
        preferences.languageCode = "de"
        XCTAssertEqual(snapshot.modelID, "openai/whisper-large-v3")
        XCTAssertEqual(snapshot.languageCode, "pt")
        XCTAssertEqual(preferences.configuration.languageCode, "de")
        XCTAssertTrue(preferences.source == .openRouter)
    }

    func testUnknownModelCannotBecomeSelectedAndCredentialsAreNotPreferences() throws {
        let suite = "CloudTranscriptionSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var preferences = CloudTranscriptionPreferences(defaults: defaults)
        preferences.modelID = "unvalidated/model"
        XCTAssertEqual(preferences.modelID, "openai/whisper-large-v3-turbo")
        XCTAssertFalse((defaults.persistentDomain(forName: suite) ?? [:]).keys.contains { $0.lowercased().contains("apikey") })
    }

    func testCombinedModePersistsSeparatelyFromFileTranscriptionConfiguration() throws {
        let suite = "CloudTranscriptionSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var preferences = CloudTranscriptionPreferences(defaults: defaults)
        preferences.dictationMode = .transcribeAndStyle
        preferences.dictationModelID = "google/gemini-2.5-pro"
        preferences.modelID = "openai/whisper-large-v3"
        let restored = CloudTranscriptionPreferences(defaults: defaults)
        XCTAssertEqual(restored.dictationMode, .transcribeAndStyle)
        XCTAssertEqual(restored.dictationModelID, "google/gemini-2.5-pro")
        XCTAssertEqual(restored.configuration.modelID, "openai/whisper-large-v3")
        XCTAssertNil(restored.configuration.audioDictation)
        preferences.dictationModelID = "unvalidated/audio-model"
        XCTAssertEqual(preferences.dictationModelID, "google/gemini-2.5-pro")
    }

    func testUnknownStoredModeKeepsLegacyTranscription() throws {
        let suite = "CloudTranscriptionSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("unknown-mode", forKey: "CloudDictationMode")
        let preferences = CloudTranscriptionPreferences(defaults: defaults)
        XCTAssertEqual(preferences.dictationMode, .transcriptionOnly)
    }
}

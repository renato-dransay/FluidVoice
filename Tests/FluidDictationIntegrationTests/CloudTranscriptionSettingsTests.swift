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
        XCTAssertNil(preferences.primaryLanguageCode)
        XCTAssertNil(preferences.secondaryLanguageCode)
    }

    func testCapturedConfigurationDoesNotFollowLaterPreferenceChanges() throws {
        let suite = "CloudTranscriptionSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var preferences = CloudTranscriptionPreferences(defaults: defaults)
        preferences.source = .openRouter
        preferences.modelID = "openai/whisper-large-v3"
        preferences.primaryLanguageCode = "pt"
        preferences.secondaryLanguageCode = "en"
        let snapshot = preferences.configuration
        preferences.modelID = "openai/gpt-4o-transcribe"
        preferences.primaryLanguageCode = "de"
        preferences.secondaryLanguageCode = "fr"
        XCTAssertEqual(snapshot.modelID, "openai/whisper-large-v3")
        XCTAssertEqual(snapshot.primaryLanguageCode, "pt")
        XCTAssertEqual(snapshot.secondaryLanguageCode, "en")
        XCTAssertNil(snapshot.languageCode)
        XCTAssertEqual(preferences.configuration.primaryLanguageCode, "de")
        XCTAssertEqual(preferences.configuration.secondaryLanguageCode, "fr")
        XCTAssertNil(preferences.configuration.languageCode)
        XCTAssertTrue(preferences.source == .openRouter)
    }

    func testFormerManualLanguageBecomesOptionalHintWithoutForcingDetection() throws {
        let suite = "CloudTranscriptionSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("pt", forKey: "CloudTranscriptionLanguage")
        var preferences = CloudTranscriptionPreferences(defaults: defaults)
        XCTAssertEqual(preferences.primaryLanguageCode, "pt")
        XCTAssertNil(preferences.configuration.languageCode)
        preferences.primaryLanguageCode = nil
        XCTAssertNil(CloudTranscriptionPreferences(defaults: defaults).primaryLanguageCode)
        XCTAssertNil(preferences.configuration.languageHintPrompt)
    }

    func testHintsPersistWithoutActivatingCloudAndCannotDuplicate() throws {
        let suite = "CloudTranscriptionSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var preferences = CloudTranscriptionPreferences(defaults: defaults)
        preferences.primaryLanguageCode = " PT "
        preferences.secondaryLanguageCode = "en"
        var restored = CloudTranscriptionPreferences(defaults: defaults)
        XCTAssertEqual(restored.primaryLanguageCode, "pt")
        XCTAssertEqual(restored.secondaryLanguageCode, "en")
        XCTAssertEqual(restored.source, .local)
        XCTAssertNil(restored.configuration.languageCode)
        restored.primaryLanguageCode = "en"
        XCTAssertNil(restored.secondaryLanguageCode)
        restored.primaryLanguageCode = "pt"
        XCTAssertNil(restored.secondaryLanguageCode, "A cleared duplicate must not reappear after changing the primary hint")
        restored.secondaryLanguageCode = "pt"
        XCTAssertNil(restored.secondaryLanguageCode)
        restored.secondaryLanguageCode = "de"
        restored.primaryLanguageCode = nil
        XCTAssertNil(restored.primaryLanguageCode)
        XCTAssertNil(restored.secondaryLanguageCode)
    }

    func testInvalidStoredHintsAreIgnored() throws {
        let suite = "CloudTranscriptionSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("unsupported-language", forKey: "CloudTranscriptionPrimaryLanguage")
        defaults.set("en", forKey: "CloudTranscriptionSecondaryLanguage")
        var preferences = CloudTranscriptionPreferences(defaults: defaults)
        XCTAssertNil(preferences.primaryLanguageCode)
        XCTAssertNil(preferences.secondaryLanguageCode)
        preferences.primaryLanguageCode = "de"
        preferences.primaryLanguageCode = "bad-code"
        XCTAssertEqual(preferences.primaryLanguageCode, "de")
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

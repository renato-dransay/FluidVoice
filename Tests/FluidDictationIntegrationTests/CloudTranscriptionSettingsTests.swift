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
        XCTAssertEqual(preferences.dictationModelID(inheriting: nil), CloudAudioDictationModel.defaultID)
        XCTAssertNil(preferences.configuration.audioDictation)
        XCTAssertNil(preferences.primaryLanguageCode)
        XCTAssertNil(preferences.secondaryLanguageCode)
        XCTAssertNil(preferences.dictationLanguageCode)
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
        XCTAssertNil(preferences.dictationConfiguration.languageCode)
        XCTAssertEqual(preferences.dictationConfiguration.primaryLanguageCode, "pt")
        XCTAssertNil(preferences.configuration.languageCode)
        preferences.primaryLanguageCode = nil
        XCTAssertNil(CloudTranscriptionPreferences(defaults: defaults).primaryLanguageCode)
        XCTAssertNil(preferences.dictationConfiguration.languageCode)
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

    func testDictationLanguageDefaultsToAutomaticAndRemembersManualChoice() throws {
        let suite = "CloudTranscriptionSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var preferences = CloudTranscriptionPreferences(defaults: defaults)
        preferences.primaryLanguageCode = "pt"
        preferences.secondaryLanguageCode = "en"

        XCTAssertNil(preferences.dictationLanguageCode)
        XCTAssertNil(preferences.dictationConfiguration.languageCode)
        XCTAssertEqual(preferences.dictationConfiguration.primaryLanguageCode, "pt")
        XCTAssertEqual(preferences.dictationConfiguration.secondaryLanguageCode, "en")
        XCTAssertNil(preferences.configuration.languageCode, "Imported files keep automatic detection")

        preferences.dictationLanguageCode = "en"
        XCTAssertEqual(CloudTranscriptionPreferences(defaults: defaults).dictationLanguageCode, "en")
        XCTAssertEqual(preferences.dictationConfiguration.languageCode, "en")
        preferences.dictationLanguageCode = nil
        XCTAssertNil(CloudTranscriptionPreferences(defaults: defaults).dictationLanguageCode)
        XCTAssertNil(preferences.dictationConfiguration.languageCode)
        XCTAssertNotNil(preferences.dictationConfiguration.languageHintPrompt, "Configured languages remain optional hints")

        preferences.dictationLanguageCode = "de"
        XCTAssertNil(preferences.dictationLanguageCode, "Unconfigured languages must not replace Automatic")
        preferences.dictationLanguageCode = "en"
        preferences.secondaryLanguageCode = nil
        XCTAssertNil(preferences.dictationLanguageCode, "Removed secondary falls back to automatic detection")
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

    func testDictationModelPersistsSeparatelyFromFileTranscriptionConfiguration() throws {
        let suite = "CloudTranscriptionSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var preferences = CloudTranscriptionPreferences(defaults: defaults)
        preferences.dictationModelSelection = "google/gemini-3.5-flash-lite"
        preferences.modelID = "openai/whisper-large-v3"
        let restored = CloudTranscriptionPreferences(defaults: defaults)
        XCTAssertEqual(restored.dictationModelID(inheriting: nil), "google/gemini-3.5-flash-lite")
        XCTAssertEqual(restored.configuration.modelID, "openai/whisper-large-v3")
        XCTAssertNil(restored.configuration.audioDictation)
        preferences.dictationModelSelection = "unvalidated/audio-model"
        XCTAssertEqual(preferences.dictationModelSelection, "google/gemini-3.5-flash-lite")
    }

    func testAutomaticDictationModelInheritsAnAudioCapableAIProviderModel() throws {
        let suite = "CloudTranscriptionSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var preferences = CloudTranscriptionPreferences(defaults: defaults)
        XCTAssertEqual(preferences.dictationModelSelection, CloudAudioDictationModel.automaticID)
        XCTAssertEqual(preferences.dictationModelID(inheriting: "google/gemini-3.5-flash-lite"), "google/gemini-3.5-flash-lite")
        XCTAssertEqual(preferences.dictationModelID(inheriting: " google/gemini-3.5-flash-lite "), "google/gemini-3.5-flash-lite")

        // A text-only model cannot hear the recording, so Automatic keeps the default audio model.
        XCTAssertEqual(preferences.dictationModelID(inheriting: "anthropic/claude-haiku-4.5"), CloudAudioDictationModel.defaultID)
        XCTAssertEqual(preferences.dictationModelID(inheriting: nil), CloudAudioDictationModel.defaultID)

        // A model the user picked wins over the inherited one until they choose Automatic again.
        preferences.dictationModelSelection = CloudAudioDictationModel.defaultID
        XCTAssertEqual(preferences.dictationModelID(inheriting: "google/gemini-3.5-flash-lite"), CloudAudioDictationModel.defaultID)
        preferences.dictationModelSelection = CloudAudioDictationModel.automaticID
        XCTAssertEqual(preferences.dictationModelID(inheriting: "google/gemini-3.5-flash-lite"), "google/gemini-3.5-flash-lite")
    }

    func testWithdrawnDictationModelReadsAsAutomatic() throws {
        let suite = "CloudTranscriptionSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("vendor/withdrawn-audio-model", forKey: "CloudDictationModel")
        let preferences = CloudTranscriptionPreferences(defaults: defaults)
        XCTAssertEqual(preferences.dictationModelSelection, CloudAudioDictationModel.automaticID)
        XCTAssertEqual(preferences.dictationModelID(inheriting: nil), CloudAudioDictationModel.defaultID)
    }
}

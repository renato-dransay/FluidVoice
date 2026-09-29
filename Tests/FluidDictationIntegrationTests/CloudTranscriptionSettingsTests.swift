@testable import FluidVoice_Debug
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
}

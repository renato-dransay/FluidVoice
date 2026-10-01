import Combine
import Foundation

/// The provider test a dictation lease ran, kept past the lease so the stop path can route its result.
struct LiveProviderTestRun: Equatable {
    let provider: LiveTranscriptionProviderID
    /// Why the provider failed, when it did. Shown in the Manage sheet instead of the failure alert.
    var failureMessage: String?
}

/// Like the Cleanup Styles prompt test: while armed, the next dictation uses this provider and
/// its result is shown in the Manage sheet instead of being typed, saved or styled.
@MainActor
final class LiveProviderTestCoordinator: ObservableObject {
    static let shared = LiveProviderTestCoordinator(defaults: .standard)

    @Published private(set) var armedProvider: LiveTranscriptionProviderID?
    @Published private(set) var lastTranscript = ""
    @Published private(set) var lastLatencyMilliseconds: Int?
    @Published private(set) var lastError = ""
    private let defaults: UserDefaults
    private static let passedKey = "LiveTranscriptionTestedProviders"

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var overrideConfiguration: LiveTranscriptionConfiguration? {
        self.armedProvider.map { SettingsStore.shared.liveDictationConfiguration(for: $0) }
    }

    func arm(_ provider: LiveTranscriptionProviderID) {
        self.armedProvider = provider
        self.clearResult()
    }

    func disarm() {
        self.armedProvider = nil
        self.clearResult()
    }

    func record(transcript: String, latencyMilliseconds: Int?, error: String?) {
        guard let provider = self.armedProvider else { return }
        self.lastTranscript = transcript
        self.lastLatencyMilliseconds = latencyMilliseconds
        if let error {
            self.lastError = "Test failed: \(error)"
        } else if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.lastError = "No speech heard. Check your microphone and try again."
        } else {
            self.lastError = ""
            var passed = Set(self.defaults.stringArray(forKey: Self.passedKey) ?? [])
            passed.insert(provider.rawValue)
            self.defaults.set(Array(passed).sorted(), forKey: Self.passedKey)
            self.objectWillChange.send()
        }
    }

    func hasPassed(_ provider: LiveTranscriptionProviderID) -> Bool {
        (self.defaults.stringArray(forKey: Self.passedKey) ?? []).contains(provider.rawValue)
    }

    /// "Tested" describes the key that passed; a replaced or removed key is untested again.
    func forgetPassedTest(for provider: LiveTranscriptionProviderID) {
        let passed = (self.defaults.stringArray(forKey: Self.passedKey) ?? []).filter { $0 != provider.rawValue }
        self.defaults.set(passed, forKey: Self.passedKey)
        self.objectWillChange.send()
    }

    private func clearResult() {
        self.lastTranscript = ""
        self.lastLatencyMilliseconds = nil
        self.lastError = ""
    }
}

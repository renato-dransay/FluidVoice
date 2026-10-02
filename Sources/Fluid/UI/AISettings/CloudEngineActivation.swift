import Foundation

/// Why a Cloud provider's check refused it before the engine switched (VE-5a).
enum CloudActivationError: LocalizedError, Equatable {
    case speechModelUnavailable(providerName: String)
    case styleModelUnavailable(providerName: String)
    case settingsChanged

    var errorDescription: String? {
        switch self {
        case let .speechModelUnavailable(name): "The selected speech model is unavailable on \(name). Choose another model."
        case let .styleModelUnavailable(name): "The selected style model is unavailable on \(name). Choose another model."
        case .settingsChanged: "Voice settings changed during the check. Try again."
        }
    }
}

/// What an `Activate` on the Cloud tab did.
enum CloudActivationOutcome: Equatable {
    case activated
    /// The engine did not change. `keyRejected` is true when the provider refused the key.
    case failed(message: String, keyRejected: Bool)
    case cancelled
}

/// Makes a Cloud provider the voice engine once its check passes, and leaves Cloud for Local (VE-5a).
/// Defaults and Keychain come through the key store, so tests never touch the app's own stores.
struct CloudEngineActivation {
    let keyStore: ProviderKeyStore

    /// Runs the provider's check with its speech key and switches the engine only when it passes.
    /// - Parameters:
    ///   - check: the provider's key and model check, given the key it must use; throws when it fails.
    ///   - canSwitch: false when the engine must not change now, such as a recording that started meanwhile.
    func activate(
        _ providerID: String,
        check: (_ apiKey: String) async throws -> Void,
        canSwitch: () -> Bool
    ) async -> CloudActivationOutcome {
        let name = VoiceEngineStatus.providerName(providerID)
        let apiKey = self.keyStore.speechAPIKey(for: providerID)
        guard !apiKey.isEmpty else {
            return .failed(message: Self.failure(name, ProviderKeyMessage.missing(providerName: name)), keyRejected: false)
        }
        do {
            try await check(apiKey)
        } catch is CancellationError {
            return .cancelled
        } catch {
            // The key was replaced while the check ran: the failure says nothing about the saved key.
            guard self.keyStore.speechAPIKey(for: providerID) == apiKey else {
                return .failed(message: Self.failure(name, CloudActivationError.settingsChanged.localizedDescription), keyRejected: false)
            }
            let rejected = (error as? CloudTranscriptionError) == .authentication
            if rejected {
                self.keyStore.clearSpeechVerification(for: providerID, rejectedKey: apiKey)
            }
            return .failed(message: Self.failure(name, CloudTranscriptionError.message(for: error, providerName: name)), keyRejected: rejected)
        }
        guard canSwitch() else {
            return .failed(message: Self.failure(name, "finish the current recording first."), keyRejected: false)
        }
        // The key was replaced while the check ran: the check said nothing about the new one.
        guard self.keyStore.speechAPIKey(for: providerID) == apiKey else {
            return .failed(message: Self.failure(name, CloudActivationError.settingsChanged.localizedDescription), keyRejected: false)
        }
        self.keyStore.recordSpeechVerification(for: providerID, checkedKey: apiKey)
        var live = LiveTranscriptionPreferences(defaults: self.keyStore.defaults)
        live.activeProvider = nil
        var cloud = CloudTranscriptionPreferences(defaults: self.keyStore.defaults)
        cloud.providerID = providerID
        cloud.source = .cloud
        return .activated
    }

    /// `Use local model instead`: dictation returns to the selected local model. The Cloud provider and its
    /// models stay chosen for the next activation.
    func useLocalModelInstead() {
        var cloud = CloudTranscriptionPreferences(defaults: self.keyStore.defaults)
        cloud.source = .local
    }

    static func failure(_ providerName: String, _ reason: String) -> String {
        "Couldn't activate \(providerName): \(reason)"
    }
}

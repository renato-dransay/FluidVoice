import Foundation

/// Makes a live provider the voice engine once its key check passes (VE-5a). The check speaks only for the
/// key it sent: when the key was replaced or removed while it ran, the engine does not change and nothing
/// is recorded. Defaults and Keychain come through the key store, so tests never touch the app's own stores.
struct LiveEngineActivation {
    typealias KeyCheck = (LiveTranscriptionProviderID, String) async throws -> Void

    let keyStore: ProviderKeyStore

    /// - Parameters:
    ///   - check: the provider's key check, given the key it must use; throws when it fails.
    ///   - canSwitch: false when the engine must not change now, such as a recording that started meanwhile.
    func activate(
        _ provider: LiveTranscriptionProviderID,
        check: KeyCheck = { try await LiveTranscriptionKeyChecker.check(provider: $0, apiKey: $1) },
        canSwitch: () -> Bool
    ) async -> CloudActivationOutcome {
        let name = LiveTranscriptionCatalog.info(for: provider).name
        let providerID = ProviderRegistry.providerID(for: provider)
        let apiKey = self.keyStore.speechAPIKey(for: providerID)
        guard !apiKey.isEmpty else {
            return .failed(message: Self.failure(name, LiveTranscriptionError.missingAPIKey.message(providerName: name)), keyRejected: false)
        }
        do {
            try await check(provider, apiKey)
        } catch is CancellationError {
            return .cancelled
        } catch let error as LiveTranscriptionError {
            let rejected = error == .authentication
            if rejected {
                self.keyStore.clearSpeechVerification(for: providerID, rejectedKey: apiKey)
            }
            return .failed(message: Self.failure(name, error.message(providerName: name)), keyRejected: rejected)
        } catch {
            return .failed(message: Self.failure(name, error.localizedDescription), keyRejected: false)
        }
        // A recording may have started while the check ran; the engine never changes under it.
        guard canSwitch() else {
            return .failed(message: Self.failure(name, "finish the current recording first."), keyRejected: false)
        }
        guard self.keyStore.recordSpeechVerification(for: providerID, checkedKey: apiKey) else {
            return .failed(message: Self.failure(name, CloudActivationError.settingsChanged.localizedDescription), keyRejected: false)
        }
        var live = LiveTranscriptionPreferences(defaults: self.keyStore.defaults)
        live.activeProvider = provider
        var cloud = CloudTranscriptionPreferences(defaults: self.keyStore.defaults)
        cloud.source = .liveCloud
        return .activated
    }

    static func failure(_ providerName: String, _ reason: String) -> String {
        "Couldn't activate \(providerName): \(reason)"
    }
}

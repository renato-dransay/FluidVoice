import Foundation

/// Activation check: one authenticated REST request, no audio (UX §C Design 1, "Activation").
nonisolated enum LiveTranscriptionKeyChecker {
    static func check(provider: LiveTranscriptionProviderID, apiKey: String, session: URLSession = .shared) async throws {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LiveTranscriptionError.missingAPIKey }
        let adapter = LiveTranscriptionAdapters.make(provider)
        let request = try adapter.keyCheckRequest(apiKey: apiKey)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LiveTranscriptionError.connectionFailed
        }
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw LiveTranscriptionError.connectionFailed }
        if let failure = adapter.keyCheckFailure(status: status, body: data) { throw failure }
    }
}

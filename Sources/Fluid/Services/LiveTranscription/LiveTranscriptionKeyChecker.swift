import Foundation

/// Activation check: one authenticated REST request, no audio (UX §C Design 1, "Activation").
nonisolated enum LiveTranscriptionKeyChecker {
    static func check(provider: LiveTranscriptionProviderID, apiKey: String, session: URLSession = .shared) async throws {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LiveTranscriptionError.missingAPIKey }
        let request = try LiveTranscriptionAdapters.make(provider).keyCheckRequest(apiKey: apiKey)
        let response: URLResponse
        do {
            (_, response) = try await session.data(for: request)
        } catch {
            throw LiveTranscriptionError.connectionFailed
        }
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw LiveTranscriptionError.connectionFailed }
        guard (200 ..< 300).contains(status) else { throw LiveHTTPStatus.failure(for: status) }
    }
}

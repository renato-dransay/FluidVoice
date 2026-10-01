import Foundation

/// Wraps one live session per recording in the `TranscriptionProvider` contract ASRService uses.
/// Frozen per activity lease with its configuration and key, like `CloudTranscriptionProvider`.
final class LiveCloudTranscriptionProvider: TranscriptionProvider {
    let configuration: LiveTranscriptionConfiguration
    private let apiKey: String
    private let localProvider: (any TranscriptionProvider)?
    // JUDGMENT: in the app's Swift 5 mode a main-actor stored closure reads back as non-Sendable when passed
    // to the session (a data-race warning); the closure is immutable and @Sendable, so nonisolated is exact.
    nonisolated private let makeTransport: LiveTranscriptionSession.TransportFactory
    private let finishTimeout: Duration
    private var session: LiveTranscriptionSession?
    private var startFailure: Error?
    private var appendedSamples = 0
    /// The recording's stream was cancelled, so its final pass returns no text.
    private var isCancelled = false

    init(
        configuration: LiveTranscriptionConfiguration,
        apiKey: String,
        localProvider: (any TranscriptionProvider)?,
        makeTransport: @escaping LiveTranscriptionSession.TransportFactory = { URLSessionWebSocketTransport() },
        finishTimeout: Duration = .seconds(5)
    ) {
        self.configuration = configuration
        self.apiKey = apiKey
        self.localProvider = localProvider
        self.makeTransport = makeTransport
        self.finishTimeout = finishTimeout
    }

    var name: String { LiveTranscriptionCatalog.info(for: self.configuration.provider).name }
    var isAvailable: Bool { true }
    var isReady: Bool { !self.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    func modelsExistOnDisk() -> Bool { self.isReady }
    var shouldClearCacheAfterCancellation: Bool { false }

    func prepare(progressHandler: ((ModelPreparationProgress) -> Void)?) async throws {
        guard self.isReady else { throw LiveTranscriptionError.missingAPIKey }
    }

    private func makeSession() -> LiveTranscriptionSession {
        LiveTranscriptionSession(
            adapter: LiveTranscriptionAdapters.make(self.configuration.provider),
            configuration: self.configuration,
            apiKey: self.apiKey,
            makeTransport: self.makeTransport,
            finishTimeout: self.finishTimeout
        )
    }

    /// Opens the stream for a new recording. A failure is kept and thrown by `transcribeFinal`.
    func begin() async {
        self.startFailure = nil
        self.appendedSamples = 0
        self.isCancelled = false
        // Without a key the provider is never contacted; the final pass reports the missing key.
        guard self.isReady else {
            self.session = nil
            self.startFailure = LiveTranscriptionError.missingAPIKey
            return
        }
        let session = self.makeSession()
        self.session = session
        do { try await session.start() } catch { self.startFailure = error }
    }

    var partials: AsyncStream<String>? { self.session?.partials }

    /// New samples only, in capture order.
    func append(_ samples: [Float]) async {
        guard let session, self.startFailure == nil else { return }
        self.appendedSamples += samples.count
        await session.append(samples)
    }

    func reconfigure(languageCode: String?) async {
        // JUDGMENT: a provider that takes no language would reconnect and replay the whole recording
        // for an identical stream, so the choice is ignored for it.
        guard LiveTranscriptionCatalog.info(for: self.configuration.provider).sendsLanguageChoice else { return }
        await self.session?.reconfigure(languageCode: languageCode)
    }

    func cancel() async {
        self.isCancelled = true
        await self.session?.cancel()
        self.session = nil
    }

    var streamedMilliseconds: Int {
        get async { await self.session?.streamedMilliseconds ?? 0 }
    }

    func transcribeFinal(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        // JUDGMENT: a cancel clears the session; without this the final pass would take the Retry path and
        // stream the discarded recording on a new connection.
        if self.isCancelled { throw CancellationError() }
        if let startFailure { throw startFailure }
        guard let session else { return try await self.transcribe(samples) }
        let tail = samples.count > self.appendedSamples ? Array(samples[self.appendedSamples...]) : []
        self.appendedSamples = max(self.appendedSamples, samples.count)
        // The tail goes out inside `finish`, so the finish deadline covers sending it.
        let text = try await session.finish(appending: tail)
        return ASRTranscriptionResult(text: text)
    }

    /// Retry of a saved recording: a new connection, replayed at the provider's accepted speed.
    func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        guard self.isReady else { throw LiveTranscriptionError.missingAPIKey }
        let text = try await self.makeSession().replay(samples)
        return ASRTranscriptionResult(text: text)
    }

    func transcribeStreaming(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        throw LiveTranscriptionError.sessionClosed("preview_not_supported")
    }

    /// Dictionary training compares against the local model's pronunciation, so it stays local.
    func transcribeDictionaryTraining(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        guard let localProvider else { throw LiveTranscriptionError.sessionClosed("no_local_model") }
        return try await localProvider.transcribeDictionaryTraining(samples)
    }
}

import Foundation

/// Soniox async transcription: the audio is uploaded as a file, a transcription is created for it and
/// polled, its transcript read, and both the transcription and the file deleted.
///
/// EVIDENCE: https://soniox.com/docs/api-reference/stt/files/upload_file (checked 2026-10-02):
/// `POST https://api.soniox.com/v1/files`, `Authorization: Bearer <key>`, multipart field `file`; the
/// response has `id`. Stored files count against a quota (429 `limit_exceeded`), so they are deleted.
/// EVIDENCE: https://soniox.com/docs/api-reference/stt/transcriptions/create_transcription (checked 2026-10-02):
/// `POST /v1/transcriptions` with `model`, `file_id`, `language_hints` and `language_hints_strict`; the
/// response has `id` and `status`.
/// EVIDENCE: https://soniox.com/docs/api-reference/stt/transcriptions/get_transcription (checked 2026-10-02):
/// `GET /v1/transcriptions/{id}`, `status` is `queued`, `processing`, `completed` or `error`.
/// EVIDENCE: https://soniox.com/docs/api-reference/stt/transcriptions/get_transcription_transcript (checked
/// 2026-10-02): `GET /v1/transcriptions/{id}/transcript` returns `text` and `tokens[]` with `text`,
/// `start_ms` and `end_ms`.
/// EVIDENCE: https://soniox.com/docs/stt/concepts/timestamps (checked 2026-10-02): tokens are words or sub-words
/// ("Beau", "ti", "ful"); a token that starts a word carries its leading space, as the live adapter relies on.
/// EVIDENCE: https://soniox.com/docs/api-reference/stt/transcriptions/delete_transcription (checked 2026-10-02):
/// `DELETE /v1/transcriptions/{id}` keeps the uploaded file and answers 409 while the transcription is
/// processing ("Wait until `status` reaches `completed` or `error` ... then retry the delete");
/// EVIDENCE: https://soniox.com/docs/api-reference/stt/files/delete_file (checked 2026-10-02): `DELETE
/// /v1/files/{id}` works in any state; a transcription that has not started yet and still references the
/// file then fails with `file_not_found`, which is why the page suggests waiting for a transcription that
/// should still produce a result. The file is deleted once the transcript was read, or after a failure or a
/// cancellation, when no result is wanted any more, so its delete goes out at once and never waits behind a
/// transcription delete that is refused while processing.
/// EVIDENCE: https://soniox.com/docs/api-reference/errors (checked 2026-10-02): 401 unauthenticated, 402 for an
/// exhausted balance or monthly budget, 403 `permission_denied`, 429 `limit_exceeded`.
/// EVIDENCE: https://soniox.com/docs/stt/models (checked 2026-10-02): `stt-async-v5` is the current async model.
nonisolated struct SonioxTranscriptionClient: CloudTranscriptionClient {
    static let id = "soniox"
    static let name = "Soniox"
    static let models: [CloudTranscriptionModel] = [
        .init(id: "stt-async-v5", name: "Soniox v5 Async", wordTimingSupport: .supported, languageHintProviderTags: []),
    ]
    static let shared = SonioxTranscriptionClient()

    private static let baseURL = "https://api.soniox.com/v1"
    /// The key check the Soniox live adapter uses.
    private static let keyCheckEndpoint = "https://api.soniox.com/v1/models"

    private let http: CloudVendorHTTP
    private let poller: CloudJobPoller
    private let cleanupRetry: CloudCleanupRetry

    init(session: URLSession? = nil, poller: CloudJobPoller = CloudJobPoller(), cleanupRetry: CloudCleanupRetry = CloudCleanupRetry()) {
        self.http = CloudVendorHTTP(providerID: Self.id, session: session ?? CloudVendorHTTP.makeSession())
        self.poller = poller
        self.cleanupRetry = cleanupRetry
    }

    var providerID: String { Self.id }
    var providerName: String { Self.name }
    var maximumRequestSeconds: Int { CloudVendorHTTP.maximumRequestSeconds }

    func warmConnection() async -> ConnectionWarmer.Outcome {
        await self.http.warm(Self.baseURL)
    }

    func checkKey(apiKey: String) async throws {
        let key = try CloudVendorHTTP.trimmedKey(apiKey)
        guard let url = URL(string: Self.keyCheckEndpoint) else { throw CloudTranscriptionError.network }
        _ = try await self.http.send(CloudVendorHTTP.request(url, headers: Self.headers(key)), endpoint: "models")
    }

    func transcribe(samples: [Float], configuration: CloudTranscriptionConfiguration, apiKey: String, wordTimings: Bool) async throws -> CloudTranscriptionResult {
        try Task.checkCancellation()
        guard configuration.providerID == Self.id else { throw CloudTranscriptionError.unsupportedModel }
        try configuration.validate(wordTimings: wordTimings)
        let key = try CloudVendorHTTP.trimmedKey(apiKey)
        let audio = try CloudEncodedAudio.best(samples: samples)
        let started = ProcessInfo.processInfo.systemUptime
        let transcript = try await CloudRemoteCleanup.run(providerID: Self.id, retry: self.cleanupRetry) { cleanup in
            let fileID = try await self.uploadFile(audio: audio, key: key, audioSamples: samples.count)
            cleanup.register("file") { try await self.delete("files/\(fileID)", key: key) }
            let transcriptionID = try await self.createTranscription(fileID: fileID, configuration: configuration, key: key)
            // A transcription that is still processing cannot be deleted yet (409); the cleanup tries again
            // until it can. The file is deleted at once either way.
            cleanup.register("transcription", refusedWhileProcessing: CloudRemoteCleanup.refused(withStatus: 409)) {
                try await self.delete("transcriptions/\(transcriptionID)", key: key)
            }
            try await self.poller.poll(audioSeconds: CloudVendorHTTP.audioSeconds(samples.count)) {
                try await self.transcriptionStatus(transcriptionID, key: key)
            }
            return try await self.transcript(transcriptionID, key: key)
        }
        let result = CloudTranscriptionResult(
            text: transcript.text,
            words: wordTimings ? Self.words(from: transcript.tokens) : nil,
            usage: nil,
            requestID: nil,
            processingDuration: ProcessInfo.processInfo.systemUptime - started
        )
        if wordTimings { try result.validateTimings(duration: CloudVendorHTTP.audioSeconds(samples.count)) }
        try Task.checkCancellation()
        return result
    }

    /// A chosen language is the only hint and is strict; otherwise the Primary and Secondary languages
    /// are hints and Soniox detects the language itself.
    static func transcriptionBody(fileID: String, configuration: CloudTranscriptionConfiguration) throws -> Data {
        var body: [String: Any] = ["model": configuration.modelID, "file_id": fileID]
        if let language = configuration.languageCode {
            body["language_hints"] = [language]
            body["language_hints_strict"] = true
        } else {
            let hints = [configuration.primaryLanguageCode, configuration.secondaryLanguageCode].compactMap { $0 }
            if !hints.isEmpty { body["language_hints"] = hints }
        }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    /// Tokens are words or pieces of words. A token that starts with whitespace begins a new word; one
    /// without continues the previous word, as do punctuation marks. Scripts written without spaces
    /// (Chinese, Japanese, Thai and the like) have no whitespace to merge at, so each of their tokens is a
    /// word of its own. A word spans its first piece's start to its last piece's end, in seconds.
    static func words(from tokens: [Token]) -> [CloudTranscriptionWord] {
        var words: [CloudTranscriptionWord] = []
        var startsNewWord = true
        for token in tokens {
            let piece = token.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let beginsWithSpace = token.text.first?.isWhitespace == true
            guard !piece.isEmpty else {
                // A whitespace-only token separates words and carries no text.
                startsNewWord = true
                continue
            }
            let start = Double(token.startMs) / 1000
            let end = Double(token.endMs) / 1000
            let isPunctuation = piece.allSatisfy(\.isPunctuation)
            let isUnspacedScript = piece.unicodeScalars.first.map(CloudTranscriptionWord.isWrittenWithoutSpaces) ?? false
            let followsUnspacedScript = words.last?.word.unicodeScalars.last.map(CloudTranscriptionWord.isWrittenWithoutSpaces) ?? false
            let continuesWord = isPunctuation || (!isUnspacedScript && !followsUnspacedScript)
            if let last = words.last, !startsNewWord, !beginsWithSpace, continuesWord {
                words[words.count - 1] = CloudTranscriptionWord(word: last.word + piece, start: last.start, end: max(last.end, end))
            } else {
                words.append(CloudTranscriptionWord(word: piece, start: start, end: end))
            }
            startsNewWord = token.text.last?.isWhitespace == true
        }
        return words
    }

    // MARK: - Requests

    private static func headers(_ key: String) -> [String: String] {
        ["Authorization": "Bearer \(key)"]
    }

    private func uploadFile(audio: CloudEncodedAudio, key: String, audioSamples: Int) async throws -> String {
        guard let url = URL(string: "\(Self.baseURL)/files") else { throw CloudTranscriptionError.network }
        var form = CloudMultipartForm()
        form.append(audio: audio)
        var request = CloudVendorHTTP.request(
            url,
            method: "POST",
            headers: Self.headers(key).merging(["Content-Type": form.contentType]) { $1 },
            timeout: CloudVendorHTTP.singleRequestTimeout(audioSamples: audioSamples)
        )
        request.httpBody = form.data
        let (data, _) = try await self.http.send(request, endpoint: "files", audioBytes: audio.data.count, audioSamples: audioSamples)
        return try CloudVendorHTTP.decode(Created.self, from: data).id
    }

    private func createTranscription(fileID: String, configuration: CloudTranscriptionConfiguration, key: String) async throws -> String {
        guard let url = URL(string: "\(Self.baseURL)/transcriptions") else { throw CloudTranscriptionError.network }
        var request = CloudVendorHTTP.request(url, method: "POST", headers: Self.headers(key).merging(["Content-Type": "application/json"]) { $1 })
        request.httpBody = try Self.transcriptionBody(fileID: fileID, configuration: configuration)
        let (data, _) = try await self.http.send(request, endpoint: "transcriptions", modelID: configuration.modelID)
        return try CloudVendorHTTP.decode(Created.self, from: data).id
    }

    private func transcriptionStatus(_ transcriptionID: String, key: String) async throws -> CloudJobStatus<Void> {
        guard let url = URL(string: "\(Self.baseURL)/transcriptions/\(transcriptionID)") else { throw CloudTranscriptionError.network }
        let (data, _) = try await self.http.send(CloudVendorHTTP.request(url, headers: Self.headers(key)), endpoint: "transcriptions/status")
        struct Status: Decodable {
            let status: String
            let errorType: String?

            enum CodingKeys: String, CodingKey {
                case status
                case errorType = "error_type"
            }
        }
        let status = try CloudVendorHTTP.decode(Status.self, from: data)
        switch status.status {
        case "completed": return .completed(())
        case "queued", "processing": return .pending
        default:
            // `error_type` is a short code; `error_message` is a provider error body and is never logged.
            DebugLogger.shared.warning("CLOUD_JOB_FAILED provider=soniox errorType=\(status.errorType ?? "none")", source: "CloudTranscription")
            return .failed(Self.jobError(forErrorType: status.errorType))
        }
    }

    /// EVIDENCE: https://soniox.com/docs/api-reference/errors (checked 2026-10-03): a failed transcription carries
    /// an `error_type` such as `organization_monthly_budget_exhausted`, `project_monthly_budget_exhausted` or
    /// `model_not_available`. A real account with no prepaid balance left returned the undocumented
    /// `organization_balance_exhausted` (2026-10-03), so every balance or budget code reads as missing credits;
    /// anything else stays a plain job failure.
    static func jobError(forErrorType errorType: String?) -> CloudTranscriptionError {
        guard let errorType else { return .jobFailed }
        return errorType.hasSuffix("_balance_exhausted") || errorType.hasSuffix("_budget_exhausted") ? .creditsExhausted : .jobFailed
    }

    private func transcript(_ transcriptionID: String, key: String) async throws -> TranscriptResponse {
        guard let url = URL(string: "\(Self.baseURL)/transcriptions/\(transcriptionID)/transcript") else { throw CloudTranscriptionError.network }
        let (data, _) = try await self.http.send(CloudVendorHTTP.request(url, headers: Self.headers(key)), endpoint: "transcriptions/transcript")
        return try CloudVendorHTTP.decode(TranscriptResponse.self, from: data)
    }

    private func delete(_ path: String, key: String) async throws {
        guard let url = URL(string: "\(Self.baseURL)/\(path)") else { throw CloudTranscriptionError.network }
        let endpoint = path.hasPrefix("files") ? "files/delete" : "transcriptions/delete"
        _ = try await self.http.send(CloudVendorHTTP.request(url, method: "DELETE", headers: Self.headers(key), timeout: CloudVendorHTTP.deleteTimeout), endpoint: endpoint)
    }

    private struct Created: Decodable { let id: String }

    struct Token: Decodable, Equatable {
        let text: String
        let startMs: Int
        let endMs: Int
        private enum CodingKeys: String, CodingKey {
            case text
            case startMs = "start_ms"
            case endMs = "end_ms"
        }
    }

    private struct TranscriptResponse: Decodable {
        let text: String
        let tokens: [Token]
    }
}

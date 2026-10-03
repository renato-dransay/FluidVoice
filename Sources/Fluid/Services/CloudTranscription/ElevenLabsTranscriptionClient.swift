import Foundation

/// ElevenLabs speech to text: one multipart request carries the whole chunk and returns the transcript.
///
/// EVIDENCE: https://elevenlabs.io/docs/api-reference/speech-to-text/convert (checked 2026-10-02):
/// `POST https://api.elevenlabs.io/v1/speech-to-text`, header `xi-api-key`, multipart fields `file`,
/// `model_id`, optional `language_code`, `timestamps_granularity` (`none`, `word`, `character`) and
/// `tag_audio_events`. The response has `text` and `words[]` with `text`, `start`, `end` (seconds) and
/// `type` (`word`, `spacing`, `audio_event`). No hint field exists, so only a chosen language is sent.
/// EVIDENCE: https://elevenlabs.io/docs/overview/models (checked 2026-10-02): `scribe_v2` is the batch model and
/// `scribe_v2_medical`, its clinical fine-tune, takes the same request (batch only). `scribe_v1` was removed on
/// 2026-07-09 (https://elevenlabs.io/docs/changelog/2026/6/8).
/// EVIDENCE: https://elevenlabs.io/docs/overview/capabilities/speech-to-text (checked 2026-10-02): FLAC and WAV
/// are accepted.
/// EVIDENCE: https://elevenlabs.io/docs/eleven-api/resources/errors (checked 2026-10-02): 401
/// `authentication_error`, 402 `insufficient_credits`, 403 `insufficient_permissions` for a key without
/// access to the endpoint, 429 rate limits. The help centre also documents a legacy 401 `quota_exceeded`.
/// EVIDENCE: https://elevenlabs.io/docs/api-reference/authentication and
/// https://elevenlabs.io/docs/api-reference/service-accounts/api-keys/list (checked 2026-10-02): a key can be
/// limited to some endpoints; `GET /v1/models` needs the `models_read` permission and speech to text the
/// separate `speech_to_text` one, so a speech-to-text-only key is refused the model list with 403
/// `insufficient_permissions` (`authorization_error`, "You do not have the required permissions for this
/// action"). No endpoint under `speech_to_text` checks a key without audio, so the key check keeps the
/// model list and reads that answer as a valid but restricted key; a missing speech-to-text permission
/// then shows on the first transcription, whose 403 message says so.
nonisolated struct ElevenLabsTranscriptionClient: CloudTranscriptionClient {
    static let id = "elevenlabs"
    static let name = "ElevenLabs"
    static let models: [CloudTranscriptionModel] = [
        .init(id: "scribe_v2", name: "Scribe v2", wordTimingSupport: .supported, languageHintProviderTags: []),
        .init(id: "scribe_v2_medical", name: "Scribe v2 Medical", wordTimingSupport: .supported, languageHintProviderTags: [], note: "Medical terms"),
    ]
    static let shared = ElevenLabsTranscriptionClient()

    private static let speechToTextEndpoint = "https://api.elevenlabs.io/v1/speech-to-text"
    /// The key check the ElevenLabs live adapter uses. A key without `models_read` still passes (see above).
    private static let keyCheckEndpoint = "https://api.elevenlabs.io/v1/models"

    private let http: CloudVendorHTTP

    init(session: URLSession? = nil) {
        self.http = CloudVendorHTTP(providerID: Self.id, session: session ?? CloudVendorHTTP.makeSession())
    }

    var providerID: String { Self.id }
    var providerName: String { Self.name }
    var maximumRequestSeconds: Int { CloudVendorHTTP.maximumRequestSeconds }

    func warmConnection() async -> ConnectionWarmer.Outcome {
        await self.http.warm(Self.speechToTextEndpoint)
    }

    func checkKey(apiKey: String) async throws {
        let key = try CloudVendorHTTP.trimmedKey(apiKey)
        guard let url = URL(string: Self.keyCheckEndpoint) else { throw CloudTranscriptionError.network }
        do {
            _ = try await self.http.send(CloudVendorHTTP.request(url, headers: ["xi-api-key": key]), endpoint: "models", classify: Self.classifyKeyCheck)
        } catch CloudTranscriptionError.server(403) {
            // The key authenticated but may not list models: valid, restricted to other endpoints.
            return
        }
    }

    func transcribe(samples: [Float], configuration: CloudTranscriptionConfiguration, apiKey: String, wordTimings: Bool) async throws -> CloudTranscriptionResult {
        try Task.checkCancellation()
        guard configuration.providerID == Self.id else { throw CloudTranscriptionError.unsupportedModel }
        try configuration.validate(wordTimings: wordTimings)
        let key = try CloudVendorHTTP.trimmedKey(apiKey)
        let audio = try CloudEncodedAudio.best(samples: samples)
        guard let url = URL(string: Self.speechToTextEndpoint) else { throw CloudTranscriptionError.network }
        var form = CloudMultipartForm()
        form.append(field: "model_id", value: configuration.modelID)
        if let language = configuration.languageCode { form.append(field: "language_code", value: language) }
        form.append(field: "timestamps_granularity", value: wordTimings ? "word" : "none")
        form.append(field: "tag_audio_events", value: "false")
        form.append(audio: audio)
        var request = CloudVendorHTTP.request(
            url,
            method: "POST",
            headers: ["xi-api-key": key, "Content-Type": form.contentType],
            timeout: CloudVendorHTTP.singleRequestTimeout(audioSamples: samples.count)
        )
        request.httpBody = form.data
        let started = ProcessInfo.processInfo.systemUptime
        let (data, response) = try await self.http.send(
            request,
            endpoint: "speech-to-text",
            modelID: configuration.modelID,
            audioBytes: audio.data.count,
            audioSamples: samples.count,
            classify: Self.classify
        )
        let decoded = try CloudVendorHTTP.decode(Response.self, from: data)
        let result = CloudTranscriptionResult(
            text: decoded.text,
            // Spacing and audio events are not words.
            words: wordTimings ? decoded.words?.filter { $0.type == "word" }.map {
                CloudTranscriptionWord(word: $0.text, start: $0.start, end: $0.end)
            } : nil,
            usage: nil,
            requestID: response.value(forHTTPHeaderField: "request-id"),
            processingDuration: ProcessInfo.processInfo.systemUptime - started
        )
        if wordTimings { try result.validateTimings(duration: CloudVendorHTTP.audioSeconds(samples.count)) }
        try Task.checkCancellation()
        return result
    }

    /// A legacy 401 `quota_exceeded` means no credits, not a bad key. The body is read for its code only.
    static let classify: @Sendable (Int, Data) -> CloudTranscriptionError? = { status, data in
        guard status == 401,
              let error = try? JSONDecoder().decode(ErrorBody.self, from: data),
              [error.detail.code, error.detail.status].contains("quota_exceeded")
        else { return nil }
        return .creditsExhausted
    }

    /// The key check also reads a 403 for a missing permission (`insufficient_permissions`, or the
    /// legacy `missing_permissions`) as a key that authenticated, keeping its status apart from a refused key.
    static let classifyKeyCheck: @Sendable (Int, Data) -> CloudTranscriptionError? = { status, data in
        if status == 403,
           let error = try? JSONDecoder().decode(ErrorBody.self, from: data),
           [error.detail.code, error.detail.status].contains(where: { $0 == "insufficient_permissions" || $0 == "missing_permissions" })
        {
            return .server(403)
        }
        return classify(status, data)
    }

    private struct ErrorBody: Decodable {
        struct Detail: Decodable {
            let code: String?
            let status: String?
        }
        let detail: Detail
    }

    private struct Response: Decodable {
        struct Word: Decodable {
            let text: String
            let start: TimeInterval
            let end: TimeInterval
            let type: String?
        }
        let text: String
        // Missing timings and a successful empty transcript have different meanings.
        // swiftlint:disable:next discouraged_optional_collection
        let words: [Word]?
    }
}

import Foundation

/// Gladia pre-recorded transcription: the audio is uploaded, a job is created for it and polled until it
/// is done, and the job is deleted, which deletes the uploaded audio with it.
///
/// EVIDENCE: https://docs.gladia.io/api-reference/v2/upload/audio-file (checked 2026-10-02):
/// `POST https://api.gladia.io/v2/upload`, header `x-gladia-key`, multipart field `audio`; the response
/// has `audio_url`. No delete call exists for an upload on its own.
/// EVIDENCE: https://docs.gladia.io/api-reference/v2/pre-recorded/init (checked 2026-10-02):
/// `POST /v2/pre-recorded` with `audio_url`, `model` (`solaria-1` is the default) and `language_config`
/// (`languages`, `code_switching`); the response has `id`. 401 for a missing or invalid key.
/// EVIDENCE: https://docs.gladia.io/chapters/introduction/models and the `model` enum in
/// https://docs.gladia.io/api-reference/v2/pre-recorded/init (checked 2026-10-02): `solaria-1` is the default and
/// covers 100+ languages; `solaria-3` (generally available since 2026-06-10, https://www.gladia.io/changelog)
/// transcribes English, French, German, Spanish and Italian, pre-recorded only, and the reference asks for
/// exactly one language in `language_config.languages`, without code switching. Left out: `solaria-fusion`,
/// which appears only in that enum and is documented nowhere else.
/// EVIDENCE: https://docs.gladia.io/chapters/language/language-detection (checked 2026-10-02): omitting
/// `languages` detects among all languages; a list restricts detection to it, which is stronger than a
/// hint, so the Primary and Secondary languages are not sent.
/// EVIDENCE: https://docs.gladia.io/api-reference/v2/pre-recorded/get (checked 2026-10-02):
/// `GET /v2/pre-recorded/{id}`, `status` is `queued`, `processing`, `done` or `error`; the result has
/// `result.transcription.full_transcript` and `utterances[].words[]` with `word`, `start` and `end` in seconds.
/// EVIDENCE: https://docs.gladia.io/api-reference/v2/pre-recorded/delete (checked 2026-10-02):
/// `DELETE /v2/pre-recorded/{id}` removes the job "and all its data (audio file, transcription)"; a job
/// that is not in a deletable state, as while it is still processing, gets 403, so the delete is retried.
/// EVIDENCE: https://docs.gladia.io/chapters/limits-and-specifications/concurrency (checked 2026-10-02): 429 when
/// the concurrency limit is reached. The current documentation names no status for exhausted credits; a
/// 402 keeps the shared mapping.
nonisolated struct GladiaTranscriptionClient: CloudTranscriptionClient {
    static let id = "gladia"
    static let name = "Gladia"
    static let models: [CloudTranscriptionModel] = [
        .init(id: "solaria-1", name: "Solaria-1", wordTimingSupport: .supported, languageHintProviderTags: []),
        .init(id: singleLanguageModelID, name: "Solaria-3", wordTimingSupport: .supported, languageHintProviderTags: [], note: "English, French, German, Spanish, Italian"),
    ]
    /// Solaria-3 takes exactly one of its five languages per file.
    static let singleLanguageModelID = "solaria-3"
    static let singleLanguageModelCodes: Set<String> = ["en", "fr", "de", "es", "it"]
    static let shared = GladiaTranscriptionClient()

    private static let baseURL = "https://api.gladia.io/v2"
    /// The key check the Gladia live adapter uses: listing one live session needs a valid key.
    private static let keyCheckEndpoint = "https://api.gladia.io/v2/live?limit=1"

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
        _ = try await self.http.send(CloudVendorHTTP.request(url, headers: Self.headers(key)), endpoint: "live")
    }

    func transcribe(samples: [Float], configuration: CloudTranscriptionConfiguration, apiKey: String, wordTimings: Bool) async throws -> CloudTranscriptionResult {
        try Task.checkCancellation()
        guard configuration.providerID == Self.id else { throw CloudTranscriptionError.unsupportedModel }
        try configuration.validate(wordTimings: wordTimings)
        let key = try CloudVendorHTTP.trimmedKey(apiKey)
        // The job body is built before the upload, so a language Solaria-3 cannot take sends nothing.
        _ = try Self.jobBody(audioURL: "", configuration: configuration)
        let audio = try CloudEncodedAudio.best(samples: samples)
        let started = ProcessInfo.processInfo.systemUptime
        let job = try await CloudRemoteCleanup.run(providerID: Self.id, retry: self.cleanupRetry) { cleanup in
            let audioURL = try await self.upload(audio: audio, key: key, audioSamples: samples.count)
            let jobID = try await self.createJob(audioURL: audioURL, configuration: configuration, key: key)
            // A job that is still processing cannot be deleted yet; the cleanup tries again until it can.
            cleanup.register("job", refusedWhileProcessing: CloudRemoteCleanup.refused(withStatus: 403)) {
                try await self.deleteJob(jobID, key: key)
            }
            return try await self.poller.poll(audioSeconds: CloudVendorHTTP.audioSeconds(samples.count)) {
                try await self.jobStatus(jobID, key: key)
            }
        }
        let transcription = job.result?.transcription
        let result = CloudTranscriptionResult(
            text: transcription?.fullTranscript ?? "",
            words: wordTimings ? transcription.map { $0.utterances.flatMap(\.words).map {
                CloudTranscriptionWord(word: $0.word.trimmingCharacters(in: .whitespacesAndNewlines), start: $0.start, end: $0.end)
            } } : nil,
            usage: nil,
            requestID: job.id,
            processingDuration: ProcessInfo.processInfo.systemUptime - started
        )
        if wordTimings { try result.validateTimings(duration: CloudVendorHTTP.audioSeconds(samples.count)) }
        try Task.checkCancellation()
        return result
    }

    /// The chosen model; the chosen language, otherwise automatic detection (no `languages`). Solaria-3
    /// cannot detect: it gets the chosen language, otherwise the Primary or Secondary language, when it is one
    /// of its five, and fails before anything is sent when none is.
    static func jobBody(audioURL: String, configuration: CloudTranscriptionConfiguration) throws -> Data {
        var body: [String: Any] = ["audio_url": audioURL, "model": configuration.modelID]
        if configuration.modelID == self.singleLanguageModelID {
            body["language_config"] = ["languages": [try self.singleLanguage(for: configuration)]]
        } else if let language = configuration.languageCode {
            body["language_config"] = ["languages": [language], "code_switching": false] as [String: Any]
        }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    /// `.unsupportedLanguageForModel` when Solaria-3 has none of its languages to use, otherwise nil.
    static func languageIssue(for configuration: CloudTranscriptionConfiguration) -> CloudTranscriptionError? {
        guard configuration.modelID == self.singleLanguageModelID, (try? self.singleLanguage(for: configuration)) == nil else { return nil }
        return .unsupportedLanguageForModel
    }

    /// The one language Solaria-3 transcribes this recording in. A chosen language is never replaced.
    static func singleLanguage(for configuration: CloudTranscriptionConfiguration) throws -> String {
        let candidates = configuration.languageCode.map { [$0] } ?? [configuration.primaryLanguageCode, configuration.secondaryLanguageCode].compactMap { $0 }
        guard let language = candidates.first(where: self.singleLanguageModelCodes.contains) else {
            throw CloudTranscriptionError.unsupportedLanguageForModel
        }
        return language
    }

    // MARK: - Requests

    private static func headers(_ key: String) -> [String: String] {
        ["x-gladia-key": key]
    }

    private func upload(audio: CloudEncodedAudio, key: String, audioSamples: Int) async throws -> String {
        guard let url = URL(string: "\(Self.baseURL)/upload") else { throw CloudTranscriptionError.network }
        var form = CloudMultipartForm()
        form.append(audio: audio, as: "audio")
        var request = CloudVendorHTTP.request(
            url,
            method: "POST",
            headers: Self.headers(key).merging(["Content-Type": form.contentType]) { $1 },
            timeout: CloudVendorHTTP.singleRequestTimeout(audioSamples: audioSamples)
        )
        request.httpBody = form.data
        let (data, _) = try await self.http.send(request, endpoint: "upload", audioBytes: audio.data.count, audioSamples: audioSamples)
        struct Uploaded: Decodable {
            let audioURL: String
            private enum CodingKeys: String, CodingKey { case audioURL = "audio_url" }
        }
        return try CloudVendorHTTP.decode(Uploaded.self, from: data).audioURL
    }

    private func createJob(audioURL: String, configuration: CloudTranscriptionConfiguration, key: String) async throws -> String {
        guard let url = URL(string: "\(Self.baseURL)/pre-recorded") else { throw CloudTranscriptionError.network }
        var request = CloudVendorHTTP.request(url, method: "POST", headers: Self.headers(key).merging(["Content-Type": "application/json"]) { $1 })
        request.httpBody = try Self.jobBody(audioURL: audioURL, configuration: configuration)
        let (data, _) = try await self.http.send(request, endpoint: "pre-recorded", modelID: configuration.modelID)
        struct Created: Decodable { let id: String }
        return try CloudVendorHTTP.decode(Created.self, from: data).id
    }

    private func jobStatus(_ jobID: String, key: String) async throws -> CloudJobStatus<Job> {
        guard let url = URL(string: "\(Self.baseURL)/pre-recorded/\(jobID)") else { throw CloudTranscriptionError.network }
        let (data, _) = try await self.http.send(CloudVendorHTTP.request(url, headers: Self.headers(key)), endpoint: "pre-recorded/status")
        let job = try CloudVendorHTTP.decode(Job.self, from: data)
        switch job.status {
        case "done": return .completed(job)
        case "queued", "processing": return .pending
        default: return .failed()
        }
    }

    private func deleteJob(_ jobID: String, key: String) async throws {
        guard let url = URL(string: "\(Self.baseURL)/pre-recorded/\(jobID)") else { throw CloudTranscriptionError.network }
        // Gladia answers 403 for a job that is not deletable yet, not for a rejected key, so it keeps its status.
        _ = try await self.http.send(
            CloudVendorHTTP.request(url, method: "DELETE", headers: Self.headers(key), timeout: CloudVendorHTTP.deleteTimeout),
            endpoint: "pre-recorded/delete",
            classify: { status, _ in status == 403 ? .server(403) : nil }
        )
    }

    struct Job: Decodable, Sendable {
        struct Result: Decodable, Sendable { let transcription: Transcription? }
        struct Transcription: Decodable, Sendable {
            let fullTranscript: String
            let utterances: [Utterance]
            private enum CodingKeys: String, CodingKey {
                case utterances
                case fullTranscript = "full_transcript"
            }
        }
        struct Utterance: Decodable, Sendable { let words: [Word] }
        struct Word: Decodable, Sendable {
            let word: String
            let start: TimeInterval
            let end: TimeInterval
        }
        let id: String
        let status: String
        let result: Result?
    }
}

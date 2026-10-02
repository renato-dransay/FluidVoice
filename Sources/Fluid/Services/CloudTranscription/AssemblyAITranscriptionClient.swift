import Foundation

/// AssemblyAI pre-recorded transcription: the audio is uploaded, a transcript is created for it and
/// polled until it completes, and the transcript is deleted, which deletes the upload with it.
///
/// EVIDENCE: https://www.assemblyai.com/docs/api-reference/files/upload (checked 2026-10-02):
/// `POST https://api.assemblyai.com/v2/upload` with the audio as an `application/octet-stream` body and
/// the bare key in `authorization`; the response has `upload_url`. No delete call exists for an upload.
/// EVIDENCE: https://www.assemblyai.com/docs/api-reference/transcripts/submit (checked 2026-10-02):
/// `POST /v2/transcript` with `audio_url` and `speech_models` (`universal-3-5-pro`, `universal-2`,
/// `universal-3-pro`; the singular `speech_model` is deprecated). `language_code` cannot be combined with
/// `language_detection`. `language_detection_options.expected_languages` restricts detection, which is
/// stronger than a hint, so the Primary and Secondary languages are not sent.
/// EVIDENCE: https://www.assemblyai.com/docs/api-reference/transcripts/get (checked 2026-10-02):
/// `GET /v2/transcript/{id}`, `status` is `queued`, `processing`, `completed` or `error`; `words[]` carry
/// `text`, `start` and `end` in milliseconds.
/// EVIDENCE: https://www.assemblyai.com/docs/api-reference/transcripts/delete (checked 2026-10-02):
/// `DELETE /v2/transcript/{id}`; "Files uploaded via the `/upload` endpoint are immediately deleted
/// alongside the transcript". An upload that never got a transcript is removed by AssemblyAI after
/// 24 to 48 hours (https://assemblyai.com/docs/faq/how-long-does-aai-retain-data). The reference lists 400
/// among the delete responses without naming its cause; AssemblyAI's deletion guide
/// (https://docs.assemblyai.com/all-guides/deleting-a-transcription-from-the-api, unreachable on 2026-10-02,
/// quoted by search results) says a transcript can be deleted only after it has completed, so a 400 on a
/// delete is retried as a transcript that is still processing.
/// EVIDENCE: https://www.assemblyai.com/docs/pre-recorded-audio/guides/common_errors_and_solutions (checked
/// 2026-10-02): an invalid key is 401; a negative balance is 400 with "Your current account balance is
/// negative"; rate limiting is 429.
nonisolated struct AssemblyAITranscriptionClient: CloudTranscriptionClient {
    static let id = "assemblyai"
    static let name = "AssemblyAI"
    static let models: [CloudTranscriptionModel] = [
        .init(id: "universal-3-5-pro", name: "Universal-3.5 Pro", wordTimingSupport: .supported, languageHintProviderTags: []),
    ]
    /// Universal-2 takes over the languages Universal-3.5 Pro does not cover.
    static let fallbackSpeechModelID = "universal-2"
    static let shared = AssemblyAITranscriptionClient()

    private static let baseURL = "https://api.assemblyai.com/v2"
    /// The key check the AssemblyAI live adapter uses: a short-lived streaming token needs a valid key.
    private static let keyCheckEndpoint = "https://streaming.assemblyai.com/v3/token?expires_in_seconds=60"

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

    func checkKey(apiKey: String) async throws {
        let key = try CloudVendorHTTP.trimmedKey(apiKey)
        guard let url = URL(string: Self.keyCheckEndpoint) else { throw CloudTranscriptionError.network }
        _ = try await self.http.send(CloudVendorHTTP.request(url, headers: Self.headers(key)), endpoint: "token", classify: Self.classify)
    }

    func transcribe(samples: [Float], configuration: CloudTranscriptionConfiguration, apiKey: String, wordTimings: Bool) async throws -> CloudTranscriptionResult {
        try Task.checkCancellation()
        guard configuration.providerID == Self.id else { throw CloudTranscriptionError.unsupportedModel }
        try configuration.validate(wordTimings: wordTimings)
        let key = try CloudVendorHTTP.trimmedKey(apiKey)
        let audio = try CloudEncodedAudio.best(samples: samples)
        let started = ProcessInfo.processInfo.systemUptime
        let transcript = try await CloudRemoteCleanup.run(providerID: Self.id, retry: self.cleanupRetry) { cleanup in
            let uploadURL = try await self.upload(audio: audio, key: key, audioSamples: samples.count)
            let transcriptID = try await self.createTranscript(uploadURL: uploadURL, configuration: configuration, key: key)
            // A transcript can be deleted only once it is completed or failed (400 before that); the cleanup
            // tries again until it can.
            cleanup.register("transcript", refusedWhileProcessing: CloudRemoteCleanup.refused(withStatus: 400)) {
                try await self.deleteTranscript(transcriptID, key: key)
            }
            return try await self.poller.poll(audioSeconds: CloudVendorHTTP.audioSeconds(samples.count)) {
                try await self.transcriptStatus(transcriptID, key: key)
            }
        }
        let result = CloudTranscriptionResult(
            text: transcript.text ?? "",
            words: wordTimings ? transcript.words?.map {
                CloudTranscriptionWord(word: $0.text, start: Double($0.start) / 1000, end: Double($0.end) / 1000)
            } : nil,
            usage: nil,
            requestID: transcript.id,
            processingDuration: ProcessInfo.processInfo.systemUptime - started
        )
        if wordTimings { try result.validateTimings(duration: CloudVendorHTTP.audioSeconds(samples.count)) }
        try Task.checkCancellation()
        return result
    }

    /// The chosen model with Universal-2 as its fallback; the chosen language, otherwise detection.
    static func transcriptBody(uploadURL: String, configuration: CloudTranscriptionConfiguration) throws -> Data {
        var body: [String: Any] = [
            "audio_url": uploadURL,
            "speech_models": [configuration.modelID, self.fallbackSpeechModelID],
        ]
        if let language = configuration.languageCode {
            body["language_code"] = language
        } else {
            body["language_detection"] = true
        }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    /// A negative balance is a 400 whose message says so; it means no credits, not a bad request. The
    /// body is read for that phrase only and never logged.
    static let classify: @Sendable (Int, Data) -> CloudTranscriptionError? = { status, data in
        guard status == 400,
              let body = try? JSONDecoder().decode(ErrorBody.self, from: data),
              body.error.localizedCaseInsensitiveContains("balance")
        else { return nil }
        return .creditsExhausted
    }

    // MARK: - Requests

    private static func headers(_ key: String) -> [String: String] {
        ["Authorization": key]
    }

    private func upload(audio: CloudEncodedAudio, key: String, audioSamples: Int) async throws -> String {
        guard let url = URL(string: "\(Self.baseURL)/upload") else { throw CloudTranscriptionError.network }
        var request = CloudVendorHTTP.request(
            url,
            method: "POST",
            headers: Self.headers(key).merging(["Content-Type": "application/octet-stream"]) { $1 },
            timeout: CloudVendorHTTP.singleRequestTimeout(audioSamples: audioSamples)
        )
        request.httpBody = audio.data
        let (data, _) = try await self.http.send(
            request, endpoint: "upload", audioBytes: audio.data.count, audioSamples: audioSamples, classify: Self.classify
        )
        struct Uploaded: Decodable {
            let uploadURL: String
            private enum CodingKeys: String, CodingKey { case uploadURL = "upload_url" }
        }
        return try CloudVendorHTTP.decode(Uploaded.self, from: data).uploadURL
    }

    private func createTranscript(uploadURL: String, configuration: CloudTranscriptionConfiguration, key: String) async throws -> String {
        guard let url = URL(string: "\(Self.baseURL)/transcript") else { throw CloudTranscriptionError.network }
        var request = CloudVendorHTTP.request(url, method: "POST", headers: Self.headers(key).merging(["Content-Type": "application/json"]) { $1 })
        request.httpBody = try Self.transcriptBody(uploadURL: uploadURL, configuration: configuration)
        let (data, _) = try await self.http.send(request, endpoint: "transcript", modelID: configuration.modelID, classify: Self.classify)
        struct Created: Decodable { let id: String }
        return try CloudVendorHTTP.decode(Created.self, from: data).id
    }

    private func transcriptStatus(_ transcriptID: String, key: String) async throws -> CloudJobStatus<Transcript> {
        guard let url = URL(string: "\(Self.baseURL)/transcript/\(transcriptID)") else { throw CloudTranscriptionError.network }
        let (data, _) = try await self.http.send(CloudVendorHTTP.request(url, headers: Self.headers(key)), endpoint: "transcript/status", classify: Self.classify)
        let transcript = try CloudVendorHTTP.decode(Transcript.self, from: data)
        switch transcript.status {
        case "completed": return .completed(transcript)
        case "queued", "processing": return .pending
        default: return .failed()
        }
    }

    private func deleteTranscript(_ transcriptID: String, key: String) async throws {
        guard let url = URL(string: "\(Self.baseURL)/transcript/\(transcriptID)") else { throw CloudTranscriptionError.network }
        _ = try await self.http.send(CloudVendorHTTP.request(url, method: "DELETE", headers: Self.headers(key), timeout: CloudVendorHTTP.deleteTimeout), endpoint: "transcript/delete")
    }

    private struct ErrorBody: Decodable { let error: String }

    struct Transcript: Decodable, Sendable {
        struct Word: Decodable, Sendable {
            let text: String
            let start: Int
            let end: Int
        }
        let id: String
        let status: String
        let text: String?
        // Missing timings and a successful empty transcript have different meanings.
        // swiftlint:disable:next discouraged_optional_collection
        let words: [Word]?
    }
}

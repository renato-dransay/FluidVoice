import Foundation

/// Speechmatics batch transcription: a job is created with the audio, polled until it is done, its
/// transcript read, and the job deleted.
///
/// EVIDENCE: https://docs.speechmatics.com/get-started/authentication (checked 2026-10-02): every Jobs API request
/// carries `Authorization: Bearer <key>`; jobs live in the region that took them, so the EU host the live
/// adapter uses (`eu1.asr.api.speechmatics.com`) serves the whole job. A missing or invalid key gets 401.
/// EVIDENCE: https://docs.speechmatics.com/speech-to-text/batch/input (checked 2026-10-02): `POST /v2/jobs/` with the
/// multipart fields `config` (JSON with `type: transcription` and `transcription_config`) and `data_file`;
/// FLAC and WAV are accepted.
/// EVIDENCE: https://docs.speechmatics.com/speech-to-text/models (checked 2026-10-02): `transcription_config.model`
/// takes `standard` (the default when it is left out, so it is always sent), `enhanced` (highest accuracy) and
/// `melia-1`; `operating_point` is the deprecated name. Melia 1 is multilingual and batch only in EU1 and US1:
/// it needs `language: "multi"`, refuses `auto` and language packs, and takes `language_hints`
/// (https://docs.speechmatics.com/speech-to-text/batch/input, checked 2026-10-02). Its json-v2 words carry a
/// `language` field and keep `start_time` and `end_time` (https://docs.speechmatics.com/speech-to-text/batch/output).
/// Left out: `oak-1` (healthcare audio) and `linden-1` (Agent STT only, not the Jobs API).
/// EVIDENCE: https://docs.speechmatics.com/speech-to-text/batch/language-identification (checked 2026-10-02):
/// `language: "auto"` asks for automatic identification. `expected_languages` restricts identification to
/// the listed languages, which is stronger than a hint, so the Primary and Secondary languages are not sent.
/// EVIDENCE: https://docs.speechmatics.com/speech-to-text/batch/output (checked 2026-10-02): `GET /v2/jobs/{id}`
/// returns `{"job": {"status": ...}}` with `running`, `done` or `rejected`; `GET /v2/jobs/{id}/transcript`
/// returns `results[]` with `type` (`word`, `punctuation`), `start_time` and `end_time` in seconds,
/// `alternatives[0].content` and, for punctuation, `attaches_to`.
/// EVIDENCE: https://docs.speechmatics.com/api-ref/batch/delete-a-job (checked 2026-10-02): `DELETE /v2/jobs/{id}`
/// deletes the job "and remove[s] all associated resources"; the troubleshooting guide
/// (https://docs.speechmatics.com/speech-to-text/batch/troubleshooting) adds `force` to stop a running job.
/// EVIDENCE: https://docs.speechmatics.com/speech-to-text/batch/limits (checked 2026-10-02): 429 for rate and
/// concurrency limits. No batch error for exhausted credit is documented; a 402 keeps the shared mapping.
nonisolated struct SpeechmaticsTranscriptionClient: CloudTranscriptionClient {
    static let id = "speechmatics"
    static let name = "Speechmatics"
    static let models: [CloudTranscriptionModel] = [
        .init(id: "enhanced", name: "Enhanced", wordTimingSupport: .supported, languageHintProviderTags: []),
        .init(id: "standard", name: "Standard", wordTimingSupport: .supported, languageHintProviderTags: []),
        .init(id: multilingualModelID, name: "Melia 1", wordTimingSupport: .supported, languageHintProviderTags: [], note: "Multilingual · Switches language mid-recording"),
    ]
    /// Melia 1 transcribes several languages in one file and always takes `language: "multi"`.
    static let multilingualModelID = "melia-1"
    static let shared = SpeechmaticsTranscriptionClient()

    private static let jobsEndpoint = "https://eu1.asr.api.speechmatics.com/v2/jobs"
    /// The key check the Speechmatics live adapter uses: listing one job needs a valid key and no audio.
    private static let keyCheckEndpoint = "https://eu1.asr.api.speechmatics.com/v2/jobs?limit=1"

    private let http: CloudVendorHTTP
    private let poller: CloudJobPoller

    init(session: URLSession? = nil, poller: CloudJobPoller = CloudJobPoller()) {
        self.http = CloudVendorHTTP(providerID: Self.id, session: session ?? CloudVendorHTTP.makeSession())
        self.poller = poller
    }

    var providerID: String { Self.id }
    var providerName: String { Self.name }
    var maximumRequestSeconds: Int { CloudVendorHTTP.maximumRequestSeconds }

    func checkKey(apiKey: String) async throws {
        let key = try CloudVendorHTTP.trimmedKey(apiKey)
        guard let url = URL(string: Self.keyCheckEndpoint) else { throw CloudTranscriptionError.network }
        _ = try await self.http.send(CloudVendorHTTP.request(url, headers: Self.headers(key)), endpoint: "jobs")
    }

    func transcribe(samples: [Float], configuration: CloudTranscriptionConfiguration, apiKey: String, wordTimings: Bool) async throws -> CloudTranscriptionResult {
        try Task.checkCancellation()
        guard configuration.providerID == Self.id else { throw CloudTranscriptionError.unsupportedModel }
        try configuration.validate(wordTimings: wordTimings)
        let key = try CloudVendorHTTP.trimmedKey(apiKey)
        let audio = try CloudEncodedAudio.best(samples: samples)
        let started = ProcessInfo.processInfo.systemUptime
        let transcript = try await CloudRemoteCleanup.run(providerID: Self.id) { cleanup in
            let jobID = try await self.createJob(audio: audio, configuration: configuration, key: key, audioSamples: samples.count)
            cleanup.register("job") { try await self.deleteJob(jobID, key: key) }
            try await self.poller.poll(audioSeconds: CloudVendorHTTP.audioSeconds(samples.count)) {
                try await self.jobStatus(jobID, key: key)
            }
            return try await self.transcript(jobID, key: key)
        }
        let result = CloudTranscriptionResult(
            text: transcript.text,
            words: wordTimings ? transcript.words : nil,
            usage: nil,
            requestID: nil,
            processingDuration: ProcessInfo.processInfo.systemUptime - started
        )
        if wordTimings { try result.validateTimings(duration: CloudVendorHTTP.audioSeconds(samples.count)) }
        try Task.checkCancellation()
        return result
    }

    /// The chosen language, otherwise automatic identification; the chosen model. Melia 1 always takes
    /// `multi`, with the chosen language, otherwise the Primary and Secondary languages, as hints.
    static func jobConfig(configuration: CloudTranscriptionConfiguration) throws -> String {
        var transcription: [String: Any] = ["model": configuration.modelID]
        if configuration.modelID == self.multilingualModelID {
            transcription["language"] = "multi"
            let hints = configuration.languageCode.map { [$0] } ?? [configuration.primaryLanguageCode, configuration.secondaryLanguageCode].compactMap { $0 }
            if !hints.isEmpty { transcription["language_hints"] = hints }
        } else {
            transcription["language"] = configuration.languageCode ?? "auto"
        }
        let config: [String: Any] = ["type": "transcription", "transcription_config": transcription]
        let data = try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
        guard let text = String(bytes: data, encoding: .utf8) else { throw CloudTranscriptionError.malformedResponse }
        return text
    }

    /// Words joined by spaces, with punctuation attached to the side Speechmatics names. Only words carry
    /// timings, so a punctuation mark joins the text of the word it attaches to, as the other vendors return
    /// it: a transcript rebuilt from the words (speaker labels, chunked files) keeps its punctuation.
    static func transcript(from results: [TranscriptResponse.Result]) -> (text: String, words: [CloudTranscriptionWord]) {
        var text = ""
        var words: [CloudTranscriptionWord] = []
        var attachesToNext = false
        // Punctuation that attaches to a word not yet read, such as an opening quotation mark.
        var pendingPrefix = ""
        var joinsPreviousWord = false
        for item in results {
            guard let content = item.alternatives.first?.content, !content.isEmpty else { continue }
            let isPunctuation = item.type == "punctuation"
            let attachesToPrevious = isPunctuation && ["previous", "both"].contains(item.attachesTo ?? "previous")
            if !text.isEmpty, !attachesToPrevious, !attachesToNext { text += " " }
            text += content
            attachesToNext = isPunctuation && ["next", "both"].contains(item.attachesTo ?? "")
            if item.type == "word", let start = item.startTime, let end = item.endTime {
                if joinsPreviousWord, let last = words.last {
                    // A mark attached to both sides, such as the hyphen in "well-known", makes one word.
                    words[words.count - 1] = CloudTranscriptionWord(word: last.word + content, start: last.start, end: max(last.end, end))
                } else {
                    words.append(CloudTranscriptionWord(word: pendingPrefix + content, start: start, end: end))
                }
                pendingPrefix = ""
                joinsPreviousWord = false
            } else if isPunctuation {
                if attachesToPrevious, pendingPrefix.isEmpty, let last = words.last {
                    words[words.count - 1] = CloudTranscriptionWord(word: last.word + content, start: last.start, end: last.end)
                    joinsPreviousWord = attachesToNext
                } else {
                    pendingPrefix += content
                }
            }
        }
        // Punctuation after the last word, with nothing left to attach to, closes that word.
        if !pendingPrefix.isEmpty, let last = words.last {
            words[words.count - 1] = CloudTranscriptionWord(word: last.word + pendingPrefix, start: last.start, end: last.end)
        }
        return (text, words)
    }

    // MARK: - Requests

    private static func headers(_ key: String) -> [String: String] {
        ["Authorization": "Bearer \(key)"]
    }

    private func createJob(audio: CloudEncodedAudio, configuration: CloudTranscriptionConfiguration, key: String, audioSamples: Int) async throws -> String {
        guard let url = URL(string: Self.jobsEndpoint + "/") else { throw CloudTranscriptionError.network }
        var form = CloudMultipartForm()
        form.append(field: "config", value: try Self.jobConfig(configuration: configuration))
        form.append(audio: audio, as: "data_file")
        var request = CloudVendorHTTP.request(
            url,
            method: "POST",
            headers: Self.headers(key).merging(["Content-Type": form.contentType]) { $1 },
            timeout: CloudVendorHTTP.singleRequestTimeout(audioSamples: audioSamples)
        )
        request.httpBody = form.data
        let (data, _) = try await self.http.send(
            request, endpoint: "jobs", modelID: configuration.modelID, audioBytes: audio.data.count, audioSamples: audioSamples
        )
        struct Created: Decodable { let id: String }
        return try CloudVendorHTTP.decode(Created.self, from: data).id
    }

    private func jobStatus(_ jobID: String, key: String) async throws -> CloudJobStatus<Void> {
        guard let url = URL(string: "\(Self.jobsEndpoint)/\(jobID)") else { throw CloudTranscriptionError.network }
        let (data, _) = try await self.http.send(CloudVendorHTTP.request(url, headers: Self.headers(key)), endpoint: "jobs/status")
        struct Status: Decodable {
            struct Job: Decodable { let status: String }
            let job: Job
        }
        switch try CloudVendorHTTP.decode(Status.self, from: data).job.status {
        case "done": return .completed(())
        case "running": return .pending
        // `rejected`, and a job that was deleted or expired in the meantime.
        default: return .failed()
        }
    }

    private func transcript(_ jobID: String, key: String) async throws -> (text: String, words: [CloudTranscriptionWord]) {
        guard let url = URL(string: "\(Self.jobsEndpoint)/\(jobID)/transcript?format=json-v2") else { throw CloudTranscriptionError.network }
        let (data, _) = try await self.http.send(CloudVendorHTTP.request(url, headers: Self.headers(key)), endpoint: "jobs/transcript")
        return Self.transcript(from: try CloudVendorHTTP.decode(TranscriptResponse.self, from: data).results)
    }

    /// `force` also stops a job that is still running, as after a cancelled transcription.
    private func deleteJob(_ jobID: String, key: String) async throws {
        guard let url = URL(string: "\(Self.jobsEndpoint)/\(jobID)?force=true") else { throw CloudTranscriptionError.network }
        _ = try await self.http.send(CloudVendorHTTP.request(url, method: "DELETE", headers: Self.headers(key), timeout: CloudVendorHTTP.deleteTimeout), endpoint: "jobs/delete")
    }

    struct TranscriptResponse: Decodable {
        struct Result: Decodable {
            struct Alternative: Decodable { let content: String }
            let type: String
            let startTime: TimeInterval?
            let endTime: TimeInterval?
            let alternatives: [Alternative]
            let attachesTo: String?
            private enum CodingKeys: String, CodingKey {
                case type, alternatives
                case startTime = "start_time"
                case endTime = "end_time"
                case attachesTo = "attaches_to"
            }
        }
        let results: [Result]
    }
}

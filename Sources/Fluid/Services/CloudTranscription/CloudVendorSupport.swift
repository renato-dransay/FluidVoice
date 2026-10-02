import Foundation

/// HTTP shared by the Cloud transcription vendor clients other than OpenRouter (CLD-2, CLD-3): status
/// mapping, timeouts and the request log line. Nothing here logs audio, transcript text, keys or bodies.
nonisolated struct CloudVendorHTTP: Sendable {
    let providerID: String
    let session: URLSession

    /// The longest audio a single-request vendor receives: 780 s fits FLAC and the WAV fallback,
    /// whose 25 MB cap sits near 781 s (CLD-3).
    static let maximumRequestSeconds = 780
    /// A single request may take 60 s plus the length of its audio.
    static let baseRequestTimeout: TimeInterval = 60

    /// An ephemeral session without caches or cookies, sized for the longest single request.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = self.baseRequestTimeout + TimeInterval(self.maximumRequestSeconds)
        configuration.timeoutIntervalForResource = 2 * (self.baseRequestTimeout + TimeInterval(self.maximumRequestSeconds))
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }

    /// The key without surrounding whitespace; an empty key fails before anything is sent.
    static func trimmedKey(_ apiKey: String) throws -> String {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw CloudTranscriptionError.missingAPIKey }
        return key
    }

    static func audioSeconds(_ sampleCount: Int) -> TimeInterval {
        Double(sampleCount) / Double(CloudAudioChunker.sampleRate)
    }

    /// 60 s plus the audio's duration, for a request that carries the whole recording.
    static func singleRequestTimeout(audioSamples: Int) -> TimeInterval {
        self.baseRequestTimeout + self.audioSeconds(audioSamples)
    }

    static func request(_ url: URL, method: String = "GET", headers: [String: String], timeout: TimeInterval = baseRequestTimeout) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    /// CLD-2: 401 and 403 are a rejected key, 402 missing credits, 429 rate limiting, 408 and 504
    /// timeouts, 413 an upload that is too large; any other failure keeps its status.
    static func error(forStatus status: Int) -> CloudTranscriptionError? {
        switch status {
        case 200 ..< 300: nil
        case 401, 403: .authentication
        case 402: .creditsExhausted
        case 408, 504: .timeout
        case 413: .oversizedAudio
        case 429: .rateLimited
        default: .server(status)
        }
    }

    /// Sends one request. `classify` lets a vendor read its own error codes (never logged) before the
    /// status mapping applies; it returns nil to keep the default.
    func send(
        _ request: URLRequest,
        endpoint: String,
        modelID: String? = nil,
        audioBytes: Int? = nil,
        audioSamples: Int? = nil,
        classify: (@Sendable (Int, Data) -> CloudTranscriptionError?)? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        let started = ProcessInfo.processInfo.systemUptime
        func log(_ status: String) {
            let line = Self.requestLine(
                providerID: self.providerID,
                endpoint: endpoint,
                modelID: modelID,
                audioBytes: audioBytes,
                audioSamples: audioSamples,
                requestDuration: ProcessInfo.processInfo.systemUptime - started,
                status: status
            )
            DebugLogger.shared.info(line, source: "CloudTranscription")
        }
        do {
            try Task.checkCancellation()
            let (data, response) = try await self.session.data(for: request)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else { throw CloudTranscriptionError.malformedResponse }
            log(String(response.statusCode))
            if let error = classify?(response.statusCode, data) ?? Self.error(forStatus: response.statusCode) {
                throw error
            }
            return (data, response)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            log(CloudTranscriptionFailureSummary.kind(of: error))
            switch error.code {
            case .cancelled: throw CancellationError()
            case .timedOut: throw CloudTranscriptionError.timeout
            default: throw CloudTranscriptionError.network
            }
        }
    }

    /// Provider, endpoint, model, sizes, durations and status only.
    static func requestLine(
        providerID: String,
        endpoint: String,
        modelID: String?,
        audioBytes: Int?,
        audioSamples: Int?,
        requestDuration: TimeInterval,
        status: String
    ) -> String {
        var fields = ["provider=\(providerID)", "endpoint=\(endpoint)"]
        if let modelID { fields.append("model=\(modelID)") }
        if let audioSamples { fields.append("audioMs=\(audioSamples * 1000 / CloudAudioChunker.sampleRate)") }
        if let audioBytes { fields.append("uploadBytes=\(audioBytes)") }
        fields.append("requestMs=\(Int((requestDuration * 1000).rounded()))")
        fields.append("status=\(status)")
        return "CLOUD_REQUEST " + fields.joined(separator: " ")
    }

    /// Decodes a vendor response, mapping anything unreadable to `.malformedResponse`.
    static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        guard let value = try? JSONDecoder().decode(type, from: data) else { throw CloudTranscriptionError.malformedResponse }
        return value
    }
}

/// A multipart/form-data body with text fields and one or more files.
nonisolated struct CloudMultipartForm: Sendable {
    let boundary: String
    private var body = Data()

    init(boundary: String = "FluidVoice-\(UUID().uuidString)") {
        self.boundary = boundary
    }

    var contentType: String { "multipart/form-data; boundary=\(self.boundary)" }

    mutating func append(field name: String, value: String) {
        self.body.append(Data("--\(self.boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
    }

    mutating func append(file name: String, fileName: String, mimeType: String, data: Data) {
        self.body.append(Data("--\(self.boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(fileName)\"\r\nContent-Type: \(mimeType)\r\n\r\n".utf8))
        self.body.append(data)
        self.body.append(Data("\r\n".utf8))
    }

    mutating func append(audio: CloudEncodedAudio, as name: String = "file") {
        self.append(file: name, fileName: audio.fileName, mimeType: audio.mimeType, data: audio.data)
    }

    /// The finished body, closing boundary included.
    var data: Data { self.body + Data("--\(self.boundary)--\r\n".utf8) }
}

/// One poll of a vendor job.
nonisolated enum CloudJobStatus<Result: Sendable>: Sendable {
    case pending
    case completed(Result)
    /// The vendor reports that the job failed.
    case failed(CloudTranscriptionError = .jobFailed)
}

/// Polls a vendor job until it completes, fails or runs past its deadline (CLD-3): every 1 s for the
/// first 10 s, then every 2 s, failing with `.timeout` after 120 s plus twice the audio's duration.
/// Clock and sleep are injected so tests run instantly.
nonisolated struct CloudJobPoller: Sendable {
    var now: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var sleep: @Sendable (TimeInterval) async throws -> Void = { seconds in
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }

    static func interval(afterElapsed elapsed: TimeInterval) -> TimeInterval {
        elapsed < 10 ? 1 : 2
    }

    static func deadline(audioSeconds: TimeInterval) -> TimeInterval {
        120 + 2 * audioSeconds
    }

    /// Calls `check` at once and then on the schedule above. A cancelled task stops between polls.
    func poll<Result: Sendable>(audioSeconds: TimeInterval, check: () async throws -> CloudJobStatus<Result>) async throws -> Result {
        let started = self.now()
        let deadline = Self.deadline(audioSeconds: audioSeconds)
        while true {
            try Task.checkCancellation()
            switch try await check() {
            case .completed(let result): return result
            case .failed(let error): throw error
            case .pending: break
            }
            let elapsed = self.now() - started
            guard elapsed < deadline else { throw CloudTranscriptionError.timeout }
            try await self.sleep(min(Self.interval(afterElapsed: elapsed), deadline - elapsed))
        }
    }
}

/// Remote data a job vendor created for one transcription (an upload, a job, a transcript). Everything
/// registered is deleted after the result is read, after a failure and on cancellation, best-effort:
/// a failed delete is logged by kind only and never fails the transcription (CLD-3).
nonisolated final class CloudRemoteCleanup: @unchecked Sendable {
    typealias Deletion = @Sendable () async throws -> Void

    let providerID: String
    private let lock = NSLock()
    private var deletions: [(kind: String, delete: Deletion)] = []

    init(providerID: String) {
        self.providerID = providerID
    }

    /// Registers how to delete one created resource, such as `upload` or `transcript`.
    func register(_ kind: String, delete: @escaping Deletion) {
        self.lock.withLock { self.deletions.append((kind, delete)) }
    }

    /// Runs every registered deletion once, newest first. The deletions run in a detached task, so
    /// they still go out when the transcription itself was cancelled.
    func deleteAll() async {
        let pending = self.lock.withLock {
            defer { self.deletions.removeAll() }
            return Array(self.deletions.reversed())
        }
        guard !pending.isEmpty else { return }
        let providerID = self.providerID
        await Task.detached(priority: .utility) {
            for deletion in pending {
                do {
                    try await deletion.delete()
                } catch {
                    DebugLogger.shared.warning(
                        "Cloud remote cleanup failed: provider=\(providerID) kind=\(deletion.kind) error=\(CloudTranscriptionFailureSummary.kind(of: error))",
                        source: "CloudTranscription"
                    )
                }
            }
        }.value
    }

    /// Runs `body` and deletes what it registered, whether it returned, failed or was cancelled.
    static func run<Value: Sendable>(providerID: String, _ body: (CloudRemoteCleanup) async throws -> Value) async throws -> Value {
        let cleanup = CloudRemoteCleanup(providerID: providerID)
        do {
            let value = try await body(cleanup)
            await cleanup.deleteAll()
            return value
        } catch {
            await cleanup.deleteAll()
            throw error
        }
    }
}

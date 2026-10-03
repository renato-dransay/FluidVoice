import Foundation

/// HTTP shared by the Cloud transcription vendor clients other than OpenRouter (CLD-2, CLD-3): status
/// mapping, timeouts and the request log line. Nothing here logs audio, transcript text, keys or bodies.
nonisolated struct CloudVendorHTTP: Sendable {
    let providerID: String
    let session: URLSession
    /// Remembers which hosts this session reached recently, so a warm-up never repeats an open connection.
    let warmer = ConnectionWarmer()

    /// The longest audio a single-request vendor receives: 780 s fits FLAC and the WAV fallback,
    /// whose 25 MB cap sits near 781 s (CLD-3).
    static let maximumRequestSeconds = 780
    /// A single request may take 60 s plus the length of its audio.
    static let baseRequestTimeout: TimeInterval = 60
    /// A delete of remote data is small and best-effort, so it gives up sooner than a transcription request.
    static let deleteTimeout: TimeInterval = 15

    /// An ephemeral session without caches or cookies, sized for the longest single request.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = self.baseRequestTimeout + TimeInterval(self.maximumRequestSeconds)
        configuration.timeoutIntervalForResource = 2 * (self.baseRequestTimeout + TimeInterval(self.maximumRequestSeconds))
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }

    /// Opens the connection to `endpoint`'s host on this session; see `ConnectionWarmer`.
    func warm(_ endpoint: String) async -> ConnectionWarmer.Outcome {
        guard let url = URL(string: endpoint) else { return .skipped }
        return await self.warmer.warm(origin: url, on: self.session)
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
            self.warmer.markSuccess(request.url)
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

/// When a delete the vendor refused because its job was still processing is tried again (CLD-3): every
/// 5 s for the first minute, then every 15 s, giving up 10 minutes after the first refusal. Clock and
/// sleep are injected so tests run instantly.
nonisolated struct CloudCleanupRetry: Sendable {
    var now: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var sleep: @Sendable (TimeInterval) async throws -> Void = { seconds in
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }

    static let giveUpAfter: TimeInterval = 600

    static func interval(afterElapsed elapsed: TimeInterval) -> TimeInterval {
        elapsed < 60 ? 5 : 15
    }
}

/// Remote data a job vendor created for one transcription (an upload, a job, a transcript). Everything
/// registered is deleted after the result is read, after a failure and on cancellation, best-effort:
/// a failed delete is logged by kind only and never fails the transcription (CLD-3).
///
/// Some vendors refuse to delete a job that is still processing, as after a cancellation or a polling
/// timeout. Such a refusal is retried in the background on the `CloudCleanupRetry` schedule, so the job
/// is deleted once the vendor finishes it; the deletions registered before it wait for it, in order.
nonisolated final class CloudRemoteCleanup: @unchecked Sendable {
    typealias Deletion = @Sendable () async throws -> Void
    /// Whether a failed delete means the vendor will accept it later, once its job has finished.
    typealias Refusal = @Sendable (Error) -> Bool

    private struct Entry: Sendable {
        let kind: String
        let isRefusedWhileProcessing: Refusal
        let delete: Deletion
    }

    let providerID: String
    private let retry: CloudCleanupRetry
    private let lock = NSLock()
    private var deletions: [Entry] = []

    init(providerID: String, retry: CloudCleanupRetry = CloudCleanupRetry()) {
        self.providerID = providerID
        self.retry = retry
    }

    /// Registers how to delete one created resource, such as `upload` or `transcript`.
    /// `refusedWhileProcessing` names the vendor's documented answer to a delete that came too early.
    func register(_ kind: String, refusedWhileProcessing: @escaping Refusal = { _ in false }, delete: @escaping Deletion) {
        self.lock.withLock { self.deletions.append(Entry(kind: kind, isRefusedWhileProcessing: refusedWhileProcessing, delete: delete)) }
    }

    /// A refusal the vendor answers with an HTTP status that the shared mapping keeps as `.server(status)`.
    static func refused(withStatus status: Int) -> Refusal {
        { ($0 as? CloudTranscriptionError) == .server(status) }
    }

    /// Runs every registered deletion once, newest first, in a detached task, so the deletes still go
    /// out when the transcription itself was cancelled. With `waits` false the caller does not wait for
    /// them. A delete refused while the job is processing is retried in the background either way.
    func deleteAll(waits: Bool = true) async {
        let pending = self.lock.withLock {
            defer { self.deletions.removeAll() }
            return Array(self.deletions.reversed())
        }
        guard !pending.isEmpty else { return }
        let providerID = self.providerID
        let retry = self.retry
        let task = Task.detached(priority: .utility) {
            let refused = await Self.attempt(pending, providerID: providerID)
            if !refused.isEmpty {
                Self.retryInBackground(refused, providerID: providerID, retry: retry)
            }
        }
        if waits { await task.value }
    }

    /// Runs `body` and deletes what it registered, whether it returned, failed or was cancelled. A
    /// cancelled caller does not wait for the deletes.
    static func run<Value: Sendable>(
        providerID: String,
        retry: CloudCleanupRetry = CloudCleanupRetry(),
        _ body: (CloudRemoteCleanup) async throws -> Value
    ) async throws -> Value {
        let cleanup = CloudRemoteCleanup(providerID: providerID, retry: retry)
        do {
            let value = try await body(cleanup)
            await cleanup.deleteAll()
            return value
        } catch {
            await cleanup.deleteAll(waits: !(error is CancellationError || Task.isCancelled))
            throw error
        }
    }

    /// Runs every deletion once, in order. A deletion refused because its job is still processing is
    /// returned for a later attempt; the others go out now and never wait behind it, so an upload is
    /// deleted at once even while its job cannot be.
    private static func attempt(_ deletions: [Entry], providerID: String) async -> [Entry] {
        var refused: [Entry] = []
        for deletion in deletions {
            do {
                try await deletion.delete()
            } catch where deletion.isRefusedWhileProcessing(error) {
                refused.append(deletion)
            } catch {
                Self.logFailure(providerID: providerID, kind: deletion.kind, error: error)
            }
        }
        return refused
    }

    private static func retryInBackground(_ refused: [Entry], providerID: String, retry: CloudCleanupRetry) {
        Task.detached(priority: .utility) {
            let started = retry.now()
            var remaining = refused
            var attempts = 0
            while let first = remaining.first {
                let elapsed = retry.now() - started
                guard elapsed < CloudCleanupRetry.giveUpAfter else {
                    DebugLogger.shared.warning(
                        "Cloud remote cleanup gave up: provider=\(providerID) kind=\(first.kind) attempts=\(attempts)",
                        source: "CloudTranscription"
                    )
                    return
                }
                do {
                    try await retry.sleep(min(CloudCleanupRetry.interval(afterElapsed: elapsed), CloudCleanupRetry.giveUpAfter - elapsed))
                } catch {
                    return
                }
                attempts += 1
                remaining = await Self.attempt(remaining, providerID: providerID)
            }
            DebugLogger.shared.info(
                "Cloud remote cleanup finished after retry: provider=\(providerID) kind=\(refused[0].kind) attempts=\(attempts)",
                source: "CloudTranscription"
            )
        }
    }

    private static func logFailure(providerID: String, kind: String, error: Error) {
        DebugLogger.shared.warning(
            "Cloud remote cleanup failed: provider=\(providerID) kind=\(kind) error=\(CloudTranscriptionFailureSummary.kind(of: error))",
            source: "CloudTranscription"
        )
    }
}

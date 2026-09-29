import Foundation

/// Contract verified against https://openrouter.ai/docs/guides/overview/multimodal/stt.
/// Multipart supports verbose_json + timestamp_granularities[]=word, with a 25 MB cap.
final nonisolated class OpenRouterTranscriptionClient: Sendable {
    private let session: URLSession
    private let recordsUsage: Bool
    private static let baseURL = URL(string: "https://openrouter.ai/api/v1/")

    init(session: URLSession? = nil, recordsUsage: Bool = true) {
        self.recordsUsage = recordsUsage
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 75
            configuration.timeoutIntervalForResource = 90
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            self.session = URLSession(configuration: configuration)
        }
    }

    func validate(apiKey: String) async throws -> [CloudTranscriptionModel] {
        // The catalog is public. Authenticate separately so a readable catalog never validates a bad key.
        _ = try await self.send(self.request(path: "key", apiKey: apiKey))
        let (data, _) = try await self.send(self.request(path: "models?output_modalities=transcription", apiKey: apiKey))
        struct Catalog: Decodable { let data: [Entry] }
        struct Entry: Decodable { let id: String }
        guard let catalog = try? JSONDecoder().decode(Catalog.self, from: data) else { throw CloudTranscriptionError.malformedResponse }
        let ids = Set(catalog.data.map(\.id))
        let models = CloudTranscriptionModel.catalog.filter { ids.contains($0.id) }
        guard !models.isEmpty else { throw CloudTranscriptionError.catalogUnavailable }
        return models
    }

    func transcribe(samples: [Float], configuration: CloudTranscriptionConfiguration, apiKey: String, wordTimings: Bool) async throws -> CloudTranscriptionResult {
        try Task.checkCancellation()
        try configuration.validate(wordTimings: wordTimings)
        var request = try self.request(path: "audio/transcriptions", apiKey: apiKey)
        let wav = try CloudWAVEncoder.encode(samples: samples)
        guard wav.count <= 25_000_000 else { throw CloudTranscriptionError.oversizedAudio }
        request.httpMethod = "POST"
        if let prompt = configuration.languageHintPrompt,
           let model = CloudTranscriptionModel.catalog.first(where: { $0.id == configuration.modelID }) {
            // OpenRouter ignores top-level multipart prompts. Its JSON provider options
            // forward hints only to the provider serving the request, without pinning it.
            var body: [String: Any] = [
                "model": configuration.modelID,
                "input_audio": ["data": wav.base64EncodedString(), "format": "wav"],
                "response_format": wordTimings ? "verbose_json" : "json",
                "provider": ["options": Dictionary(uniqueKeysWithValues: model.languageHintProviderTags.map { ($0, ["prompt": prompt]) })],
            ]
            if let language = configuration.languageCode { body["language"] = language }
            if wordTimings { body["timestamp_granularities"] = ["word"] }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } else {
            let boundary = "FluidVoice-\(UUID().uuidString)"
            var fields = [("model", configuration.modelID), ("response_format", wordTimings ? "verbose_json" : "json")]
            if let language = configuration.languageCode { fields.append(("language", language)) }
            if wordTimings { fields.append(("timestamp_granularities[]", "word")) }
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.multipart(boundary: boundary, fields: fields, wav: wav)
        }
        let started = ProcessInfo.processInfo.systemUptime
        let (data, response) = try await self.send(request)
        struct Response: Decodable {
            let text: String
            // Missing timings and a successful empty transcript have different meanings.
            // swiftlint:disable:next discouraged_optional_collection
            let words: [CloudTranscriptionWord]?
            let usage: CloudTranscriptionUsage?
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else { throw CloudTranscriptionError.malformedResponse }
        let usage = decoded.usage.map {
            CloudTranscriptionUsage(seconds: Self.validAmount($0.seconds), cost: Self.validAmount($0.cost))
        }
        let result = CloudTranscriptionResult(
            text: decoded.text,
            words: decoded.words,
            usage: usage,
            requestID: response.value(forHTTPHeaderField: "X-Generation-Id"),
            processingDuration: ProcessInfo.processInfo.systemUptime - started
        )
        if self.recordsUsage {
            let record = CloudTranscriptionUsageRecord(
                modelID: configuration.modelID,
                costUSD: usage?.cost,
                audioSeconds: Double(samples.count) / 16_000,
                processingDuration: result.processingDuration,
                requestID: result.requestID
            )
            await MainActor.run { CloudTranscriptionUsageStore.shared.record(record) }
            NotificationCenter.default.post(name: .cloudTranscriptionCompleted, object: record)
        }
        if wordTimings { try result.validateTimings(duration: Double(samples.count) / 16_000) }
        try Task.checkCancellation()
        return result
    }

    private func request(path: String, apiKey: String) throws -> URLRequest {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw CloudTranscriptionError.missingAPIKey }
        guard let baseURL = Self.baseURL, let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else { throw CloudTranscriptionError.network }
        var request = URLRequest(url: url)
        request.timeoutInterval = 75
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            try Task.checkCancellation()
            let (data, response) = try await self.session.data(for: request)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else { throw CloudTranscriptionError.malformedResponse }
            switch response.statusCode {
            case 200 ..< 300: return (data, response)
            case 401, 403: throw CloudTranscriptionError.authentication
            case 402: throw CloudTranscriptionError.creditsExhausted
            case 404: throw CloudTranscriptionError.modelUnavailable
            case 408, 504: throw CloudTranscriptionError.timeout
            case 429: throw CloudTranscriptionError.rateLimited
            default: throw CloudTranscriptionError.server(response.statusCode)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            switch error.code {
            case .cancelled: throw CancellationError()
            case .timedOut: throw CloudTranscriptionError.timeout
            default: throw CloudTranscriptionError.network
            }
        }
    }

    private static func validAmount(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    private static func multipart(boundary: String, fields: [(String, String)], wav: Data) -> Data {
        var data = Data()
        for (name, value) in fields {
            data.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        data.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"recording.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        data.append(wav)
        data.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return data
    }
}

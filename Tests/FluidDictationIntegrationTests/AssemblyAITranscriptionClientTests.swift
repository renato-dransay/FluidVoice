#if canImport(CloudTranscriptionHarness)
@testable import CloudTranscriptionHarness
#else
@testable import FluidVoice_Debug
#endif
import Foundation
import XCTest

final class AssemblyAITranscriptionClientTests: XCTestCase {
    private let configuration = CloudTranscriptionConfiguration(providerID: "assemblyai", modelID: "universal-3-5-pro")
    private static let upload = "POST /v2/upload"
    private static let create = "POST /v2/transcript"
    private static let status = "GET /v2/transcript/tx-1"
    private static let delete = "DELETE /v2/transcript/tx-1"
    private static let uploaded = (status: 200, body: #"{"upload_url":"https://cdn.assemblyai.com/upload/abc"}"#)
    private static let created = (status: 200, body: #"{"id":"tx-1","status":"queued"}"#)
    private static let processing = (status: 200, body: #"{"id":"tx-1","status":"processing","text":null,"words":null}"#)
    private static let completed = (status: 200, body: #"""
    {"id":"tx-1","status":"completed","text":"Hello world.","words":[
    {"text":"Hello","start":120,"end":400,"confidence":0.98},
    {"text":"world.","start":480,"end":900,"confidence":0.97}]}
    """#)
    private static let deleted = (status: 200, body: #"{"id":"tx-1","status":"completed","text":"Deleted by user."}"#)

    private func routes(status: [CloudVendorStub.Response] = [AssemblyAITranscriptionClientTests.completed]) -> [String: [CloudVendorStub.Response]] {
        [Self.upload: [Self.uploaded], Self.create: [Self.created], Self.status: status, Self.delete: [Self.deleted]]
    }

    func testJobContractWordTimesInSecondsAndCleanupAfterSuccess() async throws {
        let clock = CloudTestClock()
        let stub = CloudVendorStub(self.routes(status: [Self.processing, Self.processing, Self.completed]))
        stub.install()
        let result = try await self.client(clock).transcribe(
            samples: [Float](repeating: 0.1, count: 16_000), configuration: self.configuration, apiKey: " aai-key ", wordTimings: true
        )
        XCTAssertEqual(result.text, "Hello world.")
        XCTAssertEqual(result.words, [
            CloudTranscriptionWord(word: "Hello", start: 0.12, end: 0.4),
            CloudTranscriptionWord(word: "world.", start: 0.48, end: 0.9),
        ])
        XCTAssertEqual(result.requestID, "tx-1")
        XCTAssertEqual(stub.calls, [Self.upload, Self.create, Self.status, Self.status, Self.status, Self.delete])
        XCTAssertEqual(clock.sleeps, [1, 1])

        let upload = try XCTUnwrap(stub.requests(Self.upload).first)
        XCTAssertEqual(upload.url?.absoluteString, "https://api.assemblyai.com/v2/upload")
        XCTAssertEqual(upload.value(forHTTPHeaderField: "Content-Type"), "application/octet-stream")
        XCTAssertEqual(upload.httpBody?.prefix(4), Data("fLaC".utf8), "The raw audio is the whole body")
        let create = try CloudJobVendorAssert.json(stub.requests(Self.create).first)
        XCTAssertEqual(create["audio_url"] as? String, "https://cdn.assemblyai.com/upload/abc")
        XCTAssertEqual(create["speech_models"] as? [String], ["universal-3-5-pro", "universal-2"])
        XCTAssertEqual(create["language_detection"] as? Bool, true)
        XCTAssertNil(create["language_code"], "language_code and language_detection are mutually exclusive")
        for request in stub.recorder.requests {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "aai-key", "The bare key, no Bearer")
        }
    }

    func testAChosenLanguageReplacesDetection() throws {
        let body = try JSONSerialization.jsonObject(with: AssemblyAITranscriptionClient.transcriptBody(
            uploadURL: "u", configuration: .init(providerID: "assemblyai", modelID: "universal-3-5-pro", languageCode: "es", primaryLanguageCode: "de")
        )) as? [String: Any]
        XCTAssertEqual(body?["language_code"] as? String, "es")
        XCTAssertNil(body?["language_detection"])
        XCTAssertNil(body?["language_detection_options"], "Expected languages would restrict detection, so hints are not sent")
    }

    func testUniversal2IsSentAloneAndOtherModelsFallBackToIt() throws {
        func speechModels(_ modelID: String) throws -> [String]? {
            let body = try JSONSerialization.jsonObject(with: AssemblyAITranscriptionClient.transcriptBody(
                uploadURL: "u", configuration: .init(providerID: "assemblyai", modelID: modelID)
            )) as? [String: Any]
            XCTAssertEqual(body?["language_detection"] as? Bool, true)
            return body?["speech_models"] as? [String]
        }
        XCTAssertEqual(try speechModels("universal-3-5-pro"), ["universal-3-5-pro", "universal-2"])
        XCTAssertEqual(try speechModels("universal-2"), ["universal-2"], "Never the same model twice")
    }

    func testErrorsAreMappedAndCarryNoServerText() async throws {
        let cases: [(Int, String, CloudTranscriptionError)] = [
            (401, #"{"error":"Authentication error, API token missing/invalid. PRIVATE aai-key"}"#, .authentication),
            (400, #"{"error":"Your current account balance is negative. Please top up to continue using the API. PRIVATE"}"#, .creditsExhausted),
            (400, #"{"error":"PRIVATE bad request"}"#, .server(400)),
            (429, #"{"error":"PRIVATE"}"#, .rateLimited),
            (500, #"{"error":"PRIVATE"}"#, .server(500)),
        ]
        for (status, body, expected) in cases {
            let stub = CloudVendorStub([Self.upload: [(status, body)]])
            stub.install()
            let error = await CloudJobVendorAssert.failure {
                try await self.client().transcribe(samples: [0.1], configuration: self.configuration, apiKey: "aai-key", wordTimings: false)
            }
            XCTAssertEqual(error as? CloudTranscriptionError, expected, "HTTP \(status) \(body.prefix(30))")
            CloudJobVendorAssert.assertSafeMessage(error, providerName: "AssemblyAI", secrets: ["PRIVATE", "aai-key", "balance"])
            XCTAssertEqual(stub.calls, [Self.upload], "An upload has no delete call; AssemblyAI removes it within 48 hours")
        }
    }

    func testAFailedTranscriptIsReportedAndDeleted() async throws {
        let stub = CloudVendorStub(self.routes(status: [(200, #"{"id":"tx-1","status":"error","error":"PRIVATE could not decode"}"#)]))
        stub.install()
        let error = await CloudJobVendorAssert.failure {
            try await self.client().transcribe(samples: [0.1], configuration: self.configuration, apiKey: "k", wordTimings: false)
        }
        XCTAssertEqual(error as? CloudTranscriptionError, .jobFailed)
        CloudJobVendorAssert.assertSafeMessage(error, providerName: "AssemblyAI", secrets: ["PRIVATE"])
        XCTAssertEqual(stub.calls, [Self.upload, Self.create, Self.status, Self.delete])
    }

    func testATranscriptPastItsDeadlineTimesOutAndIsDeleted() async throws {
        let clock = CloudTestClock()
        let stub = CloudVendorStub(self.routes(status: [Self.processing]))
        stub.install()
        let error = await CloudJobVendorAssert.failure {
            try await self.client(clock).transcribe(samples: [0.1], configuration: self.configuration, apiKey: "k", wordTimings: false)
        }
        XCTAssertEqual(error as? CloudTranscriptionError, .timeout)
        XCTAssertEqual(stub.calls.last, Self.delete)
    }

    func testACancelledTranscriptionStillDeletesTheTranscript() async throws {
        let stub = CloudVendorStub(self.routes(status: [(0, "")]))
        stub.install()
        let client = self.client()
        let configuration = self.configuration
        let task = Task {
            try await client.transcribe(samples: [0.1], configuration: configuration, apiKey: "k", wordTimings: false)
        }
        try await stub.waitForRequest(Self.status)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("A cancelled transcription returns nothing")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        // The cancelled caller does not wait for the delete, which still goes out.
        try await stub.waitForRequests(Self.delete, count: 1)
        XCTAssertEqual(stub.requests(Self.delete).first?.timeoutInterval, CloudVendorHTTP.deleteTimeout)
    }

    /// AssemblyAI deletes a transcript only once it has completed; an earlier delete is retried in the background.
    func testADeleteRefusedWhileTheTranscriptIsProcessingIsRetried() async throws {
        var routes = self.routes(status: [(0, "")])
        routes[Self.delete] = [(400, #"{"error":"PRIVATE"}"#), Self.deleted]
        let stub = CloudVendorStub(routes)
        stub.install()
        let retryClock = CloudTestClock()
        let client = AssemblyAITranscriptionClient(session: CloudURLProtocol.session(), poller: CloudTestClock().poller, cleanupRetry: retryClock.cleanupRetry)
        let configuration = self.configuration
        let task = Task {
            try await client.transcribe(samples: [0.1], configuration: configuration, apiKey: "k", wordTimings: false)
        }
        try await stub.waitForRequest(Self.status)
        task.cancel()
        _ = try? await task.value
        try await stub.waitForRequests(Self.delete, count: 2)
        XCTAssertEqual(retryClock.sleeps, [5])
    }

    func testKeyCheckAsksForAStreamingToken() async throws {
        let stub = CloudVendorStub(["GET /v3/token": [(200, #"{"token":"t"}"#)]])
        stub.install()
        try await self.client().checkKey(apiKey: "aai-key")
        let request = try XCTUnwrap(stub.recorder.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://streaming.assemblyai.com/v3/token?expires_in_seconds=60")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "aai-key")
    }

    // MARK: - Engine

    func testEngineAcceptsTheDefaultModelAndRejectsAnUnknownOne() async throws {
        let stub = CloudVendorStub(self.routes())
        stub.install()
        let defaultModel = try XCTUnwrap(CloudTranscriptionCatalog.defaultModelID(for: "assemblyai"))
        XCTAssertEqual(defaultModel, "universal-3-5-pro")
        let configuration = CloudTranscriptionConfiguration(providerID: "assemblyai", modelID: defaultModel)
        XCTAssertNoThrow(try configuration.validate(wordTimings: true))
        let engine = CloudTranscriptionEngine(client: self.client(), cacheDirectory: nil)
        let result = try await engine.transcribe(samples: [Float](repeating: 0.1, count: 16_000), configuration: configuration, apiKey: "k", wordTimings: true)
        XCTAssertEqual(result.text, "Hello world.")
        XCTAssertTrue(stub.recorder.requests.allSatisfy { $0.url?.host == "api.assemblyai.com" })

        let before = stub.recorder.requests.count
        let error = await CloudJobVendorAssert.failure {
            try await engine.transcribe(samples: [0.1], configuration: .init(providerID: "assemblyai", modelID: "universal-3-pro"), apiKey: "k", wordTimings: false)
        }
        XCTAssertEqual(error as? CloudTranscriptionError, .unsupportedModel, "A retired model is not offered")
        XCTAssertEqual(stub.recorder.requests.count, before)
    }

    private func client(_ clock: CloudTestClock = CloudTestClock()) -> AssemblyAITranscriptionClient {
        AssemblyAITranscriptionClient(session: CloudURLProtocol.session(), poller: clock.poller)
    }
}

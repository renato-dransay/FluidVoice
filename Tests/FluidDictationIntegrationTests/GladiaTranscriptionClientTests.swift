#if canImport(CloudTranscriptionHarness)
@testable import CloudTranscriptionHarness
#else
@testable import FluidVoice_Debug
#endif
import Foundation
import XCTest

final class GladiaTranscriptionClientTests: XCTestCase {
    private let configuration = CloudTranscriptionConfiguration(providerID: "gladia", modelID: "solaria-1")
    private static let upload = "POST /v2/upload"
    private static let create = "POST /v2/pre-recorded"
    private static let status = "GET /v2/pre-recorded/job-1"
    private static let delete = "DELETE /v2/pre-recorded/job-1"
    private static let uploaded = (status: 200, body: #"{"audio_url":"https://api.gladia.io/file/abc","audio_metadata":{"id":"abc"}}"#)
    private static let created = (status: 201, body: #"{"id":"job-1","result_url":"https://api.gladia.io/v2/pre-recorded/job-1"}"#)
    private static let processing = (status: 200, body: #"{"id":"job-1","status":"processing","result":null}"#)
    private static let done = (status: 200, body: #"""
    {"id":"job-1","status":"done","result":{"transcription":{"full_transcript":"Hello world. Again.","utterances":[
    {"start":0.1,"end":0.9,"words":[{"word":" Hello","start":0.1,"end":0.4,"confidence":0.9},{"word":" world.","start":0.5,"end":0.9,"confidence":0.9}]},
    {"start":1.0,"end":1.4,"words":[{"word":" Again.","start":1.0,"end":1.4,"confidence":0.9}]}]}}}
    """#)
    private static let deleted = (status: 202, body: "")

    private func routes(status: [CloudVendorStub.Response] = [GladiaTranscriptionClientTests.done]) -> [String: [CloudVendorStub.Response]] {
        [Self.upload: [Self.uploaded], Self.create: [Self.created], Self.status: status, Self.delete: [Self.deleted]]
    }

    func testJobContractWordTimesAndCleanupAfterSuccess() async throws {
        let clock = CloudTestClock()
        let stub = CloudVendorStub(self.routes(status: [Self.processing, Self.done]))
        stub.install()
        let result = try await self.client(clock).transcribe(
            samples: [Float](repeating: 0.1, count: 16_000 * 2),
            configuration: .init(providerID: "gladia", modelID: "solaria-1", primaryLanguageCode: "de"),
            apiKey: " gl-key ",
            wordTimings: true
        )
        XCTAssertEqual(result.text, "Hello world. Again.")
        XCTAssertEqual(result.words, [
            CloudTranscriptionWord(word: "Hello", start: 0.1, end: 0.4),
            CloudTranscriptionWord(word: "world.", start: 0.5, end: 0.9),
            CloudTranscriptionWord(word: "Again.", start: 1.0, end: 1.4),
        ])
        XCTAssertEqual(result.requestID, "job-1")
        XCTAssertEqual(stub.calls, [Self.upload, Self.create, Self.status, Self.status, Self.delete])
        XCTAssertEqual(clock.sleeps, [1])

        let upload = try XCTUnwrap(stub.requests(Self.upload).first)
        XCTAssertEqual(upload.url?.absoluteString, "https://api.gladia.io/v2/upload")
        XCTAssertNotNil(upload.httpBody?.range(of: Data("name=\"audio\"; filename=\"recording.flac\"".utf8)))
        let create = try CloudJobVendorAssert.json(stub.requests(Self.create).first)
        XCTAssertEqual(create["audio_url"] as? String, "https://api.gladia.io/file/abc")
        XCTAssertEqual(create["model"] as? String, "solaria-1")
        XCTAssertNil(create["language_config"], "No languages means automatic detection; a Primary language would restrict it")
        for request in stub.recorder.requests {
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-gladia-key"), "gl-key")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        }
    }

    func testAChosenLanguageIsTheOnlyLanguage() throws {
        let body = try JSONSerialization.jsonObject(with: GladiaTranscriptionClient.jobBody(
            audioURL: "u", configuration: .init(providerID: "gladia", modelID: "solaria-1", languageCode: "it")
        )) as? [String: Any]
        let languageConfig = body?["language_config"] as? [String: Any]
        XCTAssertEqual(languageConfig?["languages"] as? [String], ["it"])
        XCTAssertEqual(languageConfig?["code_switching"] as? Bool, false)
    }

    func testErrorsAreMappedAndCarryNoServerText() async throws {
        let cases: [(Int, String, CloudTranscriptionError)] = [
            (401, #"{"statusCode":401,"message":"PRIVATE gl-key"}"#, .authentication),
            (402, #"{"statusCode":402,"message":"PRIVATE"}"#, .creditsExhausted),
            (429, #"{"statusCode":429,"message":"PRIVATE"}"#, .rateLimited),
            (500, "PRIVATE", .server(500)),
        ]
        for (status, body, expected) in cases {
            let stub = CloudVendorStub([Self.upload: [(status, body)]])
            stub.install()
            let error = await CloudJobVendorAssert.failure {
                try await self.client().transcribe(samples: [0.1], configuration: self.configuration, apiKey: "gl-key", wordTimings: false)
            }
            XCTAssertEqual(error as? CloudTranscriptionError, expected, "HTTP \(status)")
            CloudJobVendorAssert.assertSafeMessage(error, providerName: "Gladia", secrets: ["PRIVATE", "gl-key"])
            XCTAssertEqual(stub.calls, [Self.upload])
        }
    }

    func testAFailedJobIsReportedAndDeleted() async throws {
        let stub = CloudVendorStub(self.routes(status: [(200, #"{"id":"job-1","status":"error","error_code":500,"result":null}"#)]))
        stub.install()
        let error = await CloudJobVendorAssert.failure {
            try await self.client().transcribe(samples: [0.1], configuration: self.configuration, apiKey: "k", wordTimings: false)
        }
        XCTAssertEqual(error as? CloudTranscriptionError, .jobFailed)
        XCTAssertEqual(stub.calls, [Self.upload, Self.create, Self.status, Self.delete])
    }

    func testAJobPastItsDeadlineTimesOutAndIsDeleted() async throws {
        let clock = CloudTestClock()
        let stub = CloudVendorStub(self.routes(status: [Self.processing]))
        stub.install()
        let error = await CloudJobVendorAssert.failure {
            try await self.client(clock).transcribe(samples: [0.1], configuration: self.configuration, apiKey: "k", wordTimings: false)
        }
        XCTAssertEqual(error as? CloudTranscriptionError, .timeout)
        XCTAssertEqual(stub.calls.last, Self.delete)
    }

    func testACancelledTranscriptionStillDeletesTheJob() async throws {
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
        XCTAssertEqual(stub.requests(Self.delete).count, 1)
    }

    func testKeyCheckListsOneLiveSession() async throws {
        let stub = CloudVendorStub(["GET /v2/live": [(200, #"{"items":[]}"#)]])
        stub.install()
        try await self.client().checkKey(apiKey: "gl-key")
        let request = try XCTUnwrap(stub.recorder.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.gladia.io/v2/live?limit=1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-gladia-key"), "gl-key")
    }

    // MARK: - Engine

    func testEngineAcceptsTheDefaultModelAndRejectsAnUnknownOne() async throws {
        let stub = CloudVendorStub(self.routes())
        stub.install()
        let defaultModel = try XCTUnwrap(CloudTranscriptionCatalog.defaultModelID(for: "gladia"))
        let configuration = CloudTranscriptionConfiguration(providerID: "gladia", modelID: defaultModel)
        XCTAssertNoThrow(try configuration.validate(wordTimings: true))
        let engine = CloudTranscriptionEngine(client: self.client(), cacheDirectory: nil)
        let result = try await engine.transcribe(samples: [Float](repeating: 0.1, count: 16_000 * 2), configuration: configuration, apiKey: "k", wordTimings: true)
        XCTAssertEqual(result.text, "Hello world. Again.")
        XCTAssertTrue(stub.recorder.requests.allSatisfy { $0.url?.host == "api.gladia.io" })

        let before = stub.recorder.requests.count
        let error = await CloudJobVendorAssert.failure {
            try await engine.transcribe(samples: [0.1], configuration: .init(providerID: "gladia", modelID: "solaria-3"), apiKey: "k", wordTimings: false)
        }
        XCTAssertEqual(error as? CloudTranscriptionError, .unsupportedModel)
        XCTAssertEqual(stub.recorder.requests.count, before)
    }

    private func client(_ clock: CloudTestClock = CloudTestClock()) -> GladiaTranscriptionClient {
        GladiaTranscriptionClient(session: CloudURLProtocol.session(), poller: clock.poller)
    }
}

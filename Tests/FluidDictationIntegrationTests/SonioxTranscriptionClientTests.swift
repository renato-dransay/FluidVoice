#if canImport(CloudTranscriptionHarness)
@testable import CloudTranscriptionHarness
#else
@testable import FluidVoice_Debug
#endif
import Foundation
import XCTest

final class SonioxTranscriptionClientTests: XCTestCase {
    private let configuration = CloudTranscriptionConfiguration(providerID: "soniox", modelID: "stt-async-v5")
    private static let upload = "POST /v1/files"
    private static let create = "POST /v1/transcriptions"
    private static let status = "GET /v1/transcriptions/tr-1"
    private static let transcript = "GET /v1/transcriptions/tr-1/transcript"
    private static let deleteTranscription = "DELETE /v1/transcriptions/tr-1"
    private static let deleteFile = "DELETE /v1/files/file-1"
    private static let uploaded = (status: 201, body: #"{"id":"file-1","filename":"recording.flac"}"#)
    private static let created = (status: 201, body: #"{"id":"tr-1","status":"queued"}"#)
    private static let processing = (status: 200, body: #"{"id":"tr-1","status":"processing"}"#)
    private static let completed = (status: 200, body: #"{"id":"tr-1","status":"completed"}"#)
    private static let deleted = (status: 204, body: "")
    private static let tokens = (status: 200, body: #"""
    {"id":"tr-1","text":"Beautiful day.","tokens":[
    {"text":"Beau","start_ms":100,"end_ms":220,"confidence":0.9},
    {"text":"ti","start_ms":220,"end_ms":340,"confidence":0.9},
    {"text":"ful","start_ms":340,"end_ms":480,"confidence":0.9},
    {"text":" day","start_ms":520,"end_ms":800,"confidence":0.9},
    {"text":".","start_ms":800,"end_ms":820,"confidence":0.9}]}
    """#)

    private func routes(status: [CloudVendorStub.Response] = [SonioxTranscriptionClientTests.completed]) -> [String: [CloudVendorStub.Response]] {
        [
            Self.upload: [Self.uploaded], Self.create: [Self.created], Self.status: status, Self.transcript: [Self.tokens],
            Self.deleteTranscription: [Self.deleted], Self.deleteFile: [Self.deleted],
        ]
    }

    func testJobContractMergedWordsAndCleanupAfterSuccess() async throws {
        let clock = CloudTestClock()
        let stub = CloudVendorStub(self.routes(status: [Self.processing, Self.completed]))
        stub.install()
        let result = try await self.client(clock).transcribe(
            samples: [Float](repeating: 0.1, count: 16_000),
            configuration: .init(providerID: "soniox", modelID: "stt-async-v5", primaryLanguageCode: "de", secondaryLanguageCode: "en"),
            apiKey: " sx-key ",
            wordTimings: true
        )
        XCTAssertEqual(result.text, "Beautiful day.")
        XCTAssertEqual(result.words, [
            CloudTranscriptionWord(word: "Beautiful", start: 0.1, end: 0.48),
            CloudTranscriptionWord(word: "day.", start: 0.52, end: 0.82),
        ])
        let expectedCalls = [Self.upload, Self.create, Self.status, Self.status, Self.transcript, Self.deleteTranscription, Self.deleteFile]
        XCTAssertEqual(stub.calls, expectedCalls, "The transcription is deleted before the file it uses")
        XCTAssertEqual(clock.sleeps, [1])

        let upload = try XCTUnwrap(stub.requests(Self.upload).first)
        XCTAssertEqual(upload.url?.absoluteString, "https://api.soniox.com/v1/files")
        XCTAssertNotNil(upload.httpBody?.range(of: Data("name=\"file\"; filename=\"recording.flac\"".utf8)))
        let create = try CloudJobVendorAssert.json(stub.requests(Self.create).first)
        XCTAssertEqual(create["model"] as? String, "stt-async-v5")
        XCTAssertEqual(create["file_id"] as? String, "file-1")
        XCTAssertEqual(create["language_hints"] as? [String], ["de", "en"], "Primary and Secondary are hints")
        XCTAssertNil(create["language_hints_strict"])
        XCTAssertEqual(stub.requests(Self.create).first?.value(forHTTPHeaderField: "Content-Type"), "application/json")
        for request in stub.recorder.requests {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sx-key", CloudVendorStub.route(of: request))
        }
    }

    func testAChosenLanguageIsAStrictHint() throws {
        let body = try JSONSerialization.jsonObject(with: SonioxTranscriptionClient.transcriptionBody(
            fileID: "f", configuration: .init(providerID: "soniox", modelID: "stt-async-v5", languageCode: "fr", primaryLanguageCode: "de")
        )) as? [String: Any]
        XCTAssertEqual(body?["language_hints"] as? [String], ["fr"])
        XCTAssertEqual(body?["language_hints_strict"] as? Bool, true)
        let automatic = try JSONSerialization.jsonObject(with: SonioxTranscriptionClient.transcriptionBody(fileID: "f", configuration: self.configuration)) as? [String: Any]
        XCTAssertNil(automatic?["language_hints"])
    }

    func testABudgetErrorTypeReadsAsCreditsAndOthersAsAJobFailure() {
        XCTAssertEqual(SonioxTranscriptionClient.jobError(forErrorType: "organization_monthly_budget_exhausted"), .creditsExhausted)
        XCTAssertEqual(SonioxTranscriptionClient.jobError(forErrorType: "project_monthly_budget_exhausted"), .creditsExhausted)
        XCTAssertEqual(SonioxTranscriptionClient.jobError(forErrorType: "model_not_available"), .jobFailed)
        XCTAssertEqual(SonioxTranscriptionClient.jobError(forErrorType: nil), .jobFailed)
    }

    func testTokensMergeIntoWords() {
        typealias Token = SonioxTranscriptionClient.Token
        let words = SonioxTranscriptionClient.words(from: [
            Token(text: "Hel", startMs: 0, endMs: 100),
            Token(text: "lo", startMs: 100, endMs: 250),
            Token(text: ",", startMs: 250, endMs: 260),
            Token(text: " ", startMs: 260, endMs: 300),
            Token(text: "wor", startMs: 300, endMs: 400),
            Token(text: "ld ", startMs: 400, endMs: 500),
            Token(text: "again", startMs: 600, endMs: 900),
            Token(text: " FluidVoice", startMs: 1_000, endMs: 1_500),
        ])
        XCTAssertEqual(words, [
            CloudTranscriptionWord(word: "Hello,", start: 0, end: 0.26),
            CloudTranscriptionWord(word: "world", start: 0.3, end: 0.5),
            CloudTranscriptionWord(word: "again", start: 0.6, end: 0.9),
            CloudTranscriptionWord(word: "FluidVoice", start: 1, end: 1.5),
        ])
        XCTAssertEqual(SonioxTranscriptionClient.words(from: []), [])
    }

    func testTokensOfScriptsWithoutSpacesAreWordsOfTheirOwn() {
        typealias Token = SonioxTranscriptionClient.Token
        let chinese = SonioxTranscriptionClient.words(from: [
            Token(text: "我", startMs: 0, endMs: 200),
            Token(text: "用", startMs: 200, endMs: 400),
            Token(text: "Fluid", startMs: 400, endMs: 700),
            Token(text: "Voice", startMs: 700, endMs: 900),
            Token(text: "写", startMs: 900, endMs: 1_100),
            Token(text: "字", startMs: 1_100, endMs: 1_300),
            Token(text: "。", startMs: 1_300, endMs: 1_350),
        ])
        // One word per token, a Latin word inside still merged, punctuation on the previous word.
        XCTAssertEqual(chinese, [
            CloudTranscriptionWord(word: "我", start: 0, end: 0.2),
            CloudTranscriptionWord(word: "用", start: 0.2, end: 0.4),
            CloudTranscriptionWord(word: "FluidVoice", start: 0.4, end: 0.9),
            CloudTranscriptionWord(word: "写", start: 0.9, end: 1.1),
            CloudTranscriptionWord(word: "字。", start: 1.1, end: 1.35),
        ])
        let japanese = SonioxTranscriptionClient.words(from: [
            Token(text: "こんにちは", startMs: 0, endMs: 500),
            Token(text: "、", startMs: 500, endMs: 520),
            Token(text: "世界", startMs: 600, endMs: 900),
        ])
        XCTAssertEqual(japanese.map(\.word), ["こんにちは、", "世界"])
        let thai = SonioxTranscriptionClient.words(from: [
            Token(text: "สวัสดี", startMs: 0, endMs: 400),
            Token(text: "ครับ", startMs: 400, endMs: 700),
        ])
        XCTAssertEqual(thai.map(\.word), ["สวัสดี", "ครับ"])
        let korean = SonioxTranscriptionClient.words(from: [
            Token(text: "안녕", startMs: 0, endMs: 300),
            Token(text: "하세요", startMs: 300, endMs: 600),
            Token(text: " 세계", startMs: 700, endMs: 1_000),
        ])
        XCTAssertEqual(korean.map(\.word), ["안녕하세요", "세계"], "Korean separates words with spaces, so its pieces merge")
    }

    func testErrorsAreMappedAndCarryNoServerText() async throws {
        let cases: [(Int, String, CloudTranscriptionError)] = [
            (401, #"{"status_code":401,"error_type":"unauthenticated","message":"PRIVATE sx-key"}"#, .authentication),
            (402, #"{"status_code":402,"error_type":"organization_balance_exhausted","message":"PRIVATE"}"#, .creditsExhausted),
            (429, #"{"status_code":429,"error_type":"limit_exceeded","message":"PRIVATE"}"#, .rateLimited),
            (503, #"{"status_code":503,"error_type":"service_unavailable","message":"PRIVATE"}"#, .server(503)),
        ]
        for (status, body, expected) in cases {
            let stub = CloudVendorStub([Self.upload: [(status, body)]])
            stub.install()
            let error = await CloudJobVendorAssert.failure {
                try await self.client().transcribe(samples: [0.1], configuration: self.configuration, apiKey: "sx-key", wordTimings: false)
            }
            XCTAssertEqual(error as? CloudTranscriptionError, expected, "HTTP \(status)")
            CloudJobVendorAssert.assertSafeMessage(error, providerName: "Soniox", secrets: ["PRIVATE", "sx-key"])
            XCTAssertEqual(stub.calls, [Self.upload])
        }
        // A transcription that cannot be created still has its uploaded file deleted.
        var routes = self.routes()
        routes[Self.create] = [(402, "PRIVATE")]
        let stub = CloudVendorStub(routes)
        stub.install()
        let error = await CloudJobVendorAssert.failure {
            try await self.client().transcribe(samples: [0.1], configuration: self.configuration, apiKey: "k", wordTimings: false)
        }
        XCTAssertEqual(error as? CloudTranscriptionError, .creditsExhausted)
        XCTAssertEqual(stub.calls, [Self.upload, Self.create, Self.deleteFile])
    }

    func testAFailedTranscriptionIsReportedAndBothResourcesDeleted() async throws {
        let stub = CloudVendorStub(self.routes(status: [(200, #"{"id":"tr-1","status":"error","error_type":"x","error_message":"PRIVATE"}"#)]))
        stub.install()
        let error = await CloudJobVendorAssert.failure {
            try await self.client().transcribe(samples: [0.1], configuration: self.configuration, apiKey: "k", wordTimings: false)
        }
        XCTAssertEqual(error as? CloudTranscriptionError, .jobFailed)
        CloudJobVendorAssert.assertSafeMessage(error, providerName: "Soniox", secrets: ["PRIVATE"])
        XCTAssertEqual(stub.calls, [Self.upload, Self.create, Self.status, Self.deleteTranscription, Self.deleteFile])
    }

    func testATranscriptionPastItsDeadlineTimesOutAndIsDeleted() async throws {
        let clock = CloudTestClock()
        let stub = CloudVendorStub(self.routes(status: [Self.processing]))
        stub.install()
        let error = await CloudJobVendorAssert.failure {
            try await self.client(clock).transcribe(samples: [0.1], configuration: self.configuration, apiKey: "k", wordTimings: false)
        }
        XCTAssertEqual(error as? CloudTranscriptionError, .timeout)
        XCTAssertEqual(Array(stub.calls.suffix(2)), [Self.deleteTranscription, Self.deleteFile])
    }

    func testACancelledTranscriptionStillDeletesWhatItCreated() async throws {
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
        // The cancelled caller does not wait for the deletes, which still go out.
        try await stub.waitForRequests(Self.deleteFile, count: 1)
        XCTAssertEqual(stub.requests(Self.deleteTranscription).count, 1)
        XCTAssertEqual(stub.requests(Self.deleteFile).first?.timeoutInterval, CloudVendorHTTP.deleteTimeout)
    }

    /// Soniox answers 409 to a delete while the transcription is processing. The delete is tried again in
    /// the background; the file, which Soniox deletes in any state, is deleted at once and does not wait.
    func testADeleteRefusedWhileProcessingIsRetriedAndTheFileIsDeletedAtOnce() async throws {
        var routes = self.routes(status: [(0, "")])
        routes[Self.deleteTranscription] = [
            (409, #"{"status_code":409,"error_type":"invalid_state","message":"PRIVATE"}"#),
            (409, #"{"status_code":409,"error_type":"invalid_state","message":"PRIVATE"}"#),
            Self.deleted,
        ]
        let stub = CloudVendorStub(routes)
        stub.install()
        let retryClock = CloudTestClock()
        let client = SonioxTranscriptionClient(session: CloudURLProtocol.session(), poller: CloudTestClock().poller, cleanupRetry: retryClock.cleanupRetry)
        let configuration = self.configuration
        let task = Task {
            try await client.transcribe(samples: [0.1], configuration: configuration, apiKey: "k", wordTimings: false)
        }
        try await stub.waitForRequest(Self.status)
        task.cancel()
        _ = try? await task.value
        try await stub.waitForRequests(Self.deleteTranscription, count: 3)
        XCTAssertEqual(
            stub.calls.filter { $0.hasPrefix("DELETE") },
            [Self.deleteTranscription, Self.deleteFile, Self.deleteTranscription, Self.deleteTranscription]
        )
        XCTAssertEqual(stub.requests(Self.deleteFile).count, 1)
        XCTAssertEqual(retryClock.sleeps, [5, 5])
    }

    func testKeyCheckListsModels() async throws {
        let stub = CloudVendorStub(["GET /v1/models": [(200, #"{"models":[]}"#)]])
        stub.install()
        try await self.client().checkKey(apiKey: "sx-key")
        let request = try XCTUnwrap(stub.recorder.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.soniox.com/v1/models")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sx-key")
    }

    // MARK: - Engine

    func testEngineAcceptsTheDefaultModelAndRejectsAnUnknownOne() async throws {
        let stub = CloudVendorStub(self.routes())
        stub.install()
        let defaultModel = try XCTUnwrap(CloudTranscriptionCatalog.defaultModelID(for: "soniox"))
        let configuration = CloudTranscriptionConfiguration(providerID: "soniox", modelID: defaultModel)
        XCTAssertNoThrow(try configuration.validate(wordTimings: true))
        let engine = CloudTranscriptionEngine(client: self.client(), cacheDirectory: nil)
        let result = try await engine.transcribe(samples: [Float](repeating: 0.1, count: 16_000), configuration: configuration, apiKey: "k", wordTimings: true)
        XCTAssertEqual(result.text, "Beautiful day.")
        XCTAssertTrue(stub.recorder.requests.allSatisfy { $0.url?.host == "api.soniox.com" })

        let before = stub.recorder.requests.count
        let error = await CloudJobVendorAssert.failure {
            try await engine.transcribe(samples: [0.1], configuration: .init(providerID: "soniox", modelID: "stt-rt-v5"), apiKey: "k", wordTimings: false)
        }
        XCTAssertEqual(error as? CloudTranscriptionError, .unsupportedModel)
        XCTAssertEqual(stub.recorder.requests.count, before)
    }

    private func client(_ clock: CloudTestClock = CloudTestClock()) -> SonioxTranscriptionClient {
        SonioxTranscriptionClient(session: CloudURLProtocol.session(), poller: clock.poller)
    }
}

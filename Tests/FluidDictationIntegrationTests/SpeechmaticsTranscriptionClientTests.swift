#if canImport(CloudTranscriptionHarness)
@testable import CloudTranscriptionHarness
#else
@testable import FluidVoice_Debug
#endif
import Foundation
import XCTest

final class SpeechmaticsTranscriptionClientTests: XCTestCase {
    private let configuration = CloudTranscriptionConfiguration(providerID: "speechmatics", modelID: "enhanced")
    private static let create = "POST /v2/jobs/"
    private static let status = "GET /v2/jobs/job-1"
    private static let transcript = "GET /v2/jobs/job-1/transcript"
    private static let delete = "DELETE /v2/jobs/job-1"
    private static let created = (status: 201, body: #"{"id":"job-1"}"#)
    private static let running = (status: 200, body: #"{"job":{"id":"job-1","status":"running"}}"#)
    private static let done = (status: 200, body: #"{"job":{"id":"job-1","status":"done"}}"#)
    private static let deleted = (status: 200, body: #"{"job":{"id":"job-1","status":"deleted"}}"#)
    private static let results = (status: 200, body: #"""
    {"format":"2.9","results":[
    {"type":"word","start_time":0.1,"end_time":0.4,"alternatives":[{"content":"Hello","confidence":1}]},
    {"type":"punctuation","start_time":0.4,"end_time":0.4,"attaches_to":"previous","alternatives":[{"content":","}]},
    {"type":"word","start_time":0.5,"end_time":0.9,"alternatives":[{"content":"world","confidence":1}]},
    {"type":"punctuation","start_time":0.9,"end_time":0.9,"attaches_to":"previous","alternatives":[{"content":"."}]}]}
    """#)

    func testJobContractWordTimesAndCleanupAfterSuccess() async throws {
        let clock = CloudTestClock()
        let stub = CloudVendorStub([
            Self.create: [Self.created], Self.status: [Self.running, Self.running, Self.done],
            Self.transcript: [Self.results], Self.delete: [Self.deleted],
        ])
        stub.install()
        let result = try await self.client(clock).transcribe(
            samples: [Float](repeating: 0.1, count: 16_000), configuration: self.configuration, apiKey: " sm-key ", wordTimings: true
        )
        XCTAssertEqual(result.text, "Hello, world.")
        // Punctuation joins the word it attaches to, so a transcript rebuilt from the words keeps it.
        XCTAssertEqual(result.words, [
            CloudTranscriptionWord(word: "Hello,", start: 0.1, end: 0.4),
            CloudTranscriptionWord(word: "world.", start: 0.5, end: 0.9),
        ])
        XCTAssertNil(result.usage)
        XCTAssertEqual(stub.calls, [Self.create, Self.status, Self.status, Self.status, Self.transcript, Self.delete])
        XCTAssertEqual(clock.sleeps, [1, 1], "Polled every second at first")

        let create = try XCTUnwrap(stub.requests(Self.create).first)
        XCTAssertEqual(create.url?.absoluteString, "https://eu1.asr.api.speechmatics.com/v2/jobs/")
        XCTAssertTrue(create.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
        let body = try XCTUnwrap(create.httpBody)
        XCTAssertTrue(CloudMultipartAssert.contains(
            body, field: "config", value: #"{"transcription_config":{"language":"auto","model":"enhanced"},"type":"transcription"}"#
        ))
        XCTAssertNotNil(body.range(of: Data("name=\"data_file\"; filename=\"recording.flac\"".utf8)))
        XCTAssertEqual(create.timeoutInterval, 61, accuracy: 0.001)
        XCTAssertEqual(stub.requests(Self.transcript).first?.url?.query, "format=json-v2")
        XCTAssertEqual(stub.requests(Self.delete).first?.url?.query, "force=true")
        for request in stub.recorder.requests {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sm-key", Self.route(request))
        }
    }

    func testAChosenLanguageIsSentAndPlainTranscriptsHaveNoWords() async throws {
        XCTAssertEqual(
            try SpeechmaticsTranscriptionClient.jobConfig(configuration: .init(providerID: "speechmatics", modelID: "standard", languageCode: "de", primaryLanguageCode: "en")),
            #"{"transcription_config":{"language":"de","model":"standard"},"type":"transcription"}"#
        )
        let stub = CloudVendorStub([Self.create: [Self.created], Self.status: [Self.done], Self.transcript: [Self.results], Self.delete: [Self.deleted]])
        stub.install()
        let plain = try await self.client().transcribe(samples: [0.1], configuration: self.configuration, apiKey: "k", wordTimings: false)
        XCTAssertEqual(plain.text, "Hello, world.")
        XCTAssertNil(plain.words)
    }

    func testPunctuationAttachesWhereSpeechmaticsSays() {
        typealias Result = SpeechmaticsTranscriptionClient.TranscriptResponse.Result
        let results = try? JSONDecoder().decode([Result].self, from: Data(#"""
        [{"type":"punctuation","attaches_to":"next","alternatives":[{"content":"¿"}]},
         {"type":"word","start_time":0,"end_time":0.2,"alternatives":[{"content":"Qué"}]},
         {"type":"punctuation","attaches_to":"previous","alternatives":[{"content":"?"}]},
         {"type":"word","start_time":0.3,"end_time":0.5,"alternatives":[{"content":"Bien"}]}]
        """#.utf8))
        let transcript = SpeechmaticsTranscriptionClient.transcript(from: results ?? [])
        XCTAssertEqual(transcript.text, "¿Qué? Bien")
        XCTAssertEqual(transcript.words.map(\.word), ["¿Qué?", "Bien"])
    }

    func testWordsCarryPunctuationSoARebuiltTranscriptKeepsIt() throws {
        typealias Result = SpeechmaticsTranscriptionClient.TranscriptResponse.Result
        let results = try JSONDecoder().decode([Result].self, from: Data(#"""
        [{"type":"word","start_time":0,"end_time":0.2,"alternatives":[{"content":"A"}]},
         {"type":"word","start_time":0.2,"end_time":0.5,"alternatives":[{"content":"well"}]},
         {"type":"punctuation","attaches_to":"both","alternatives":[{"content":"-"}]},
         {"type":"word","start_time":0.5,"end_time":0.9,"alternatives":[{"content":"known"}]},
         {"type":"word","start_time":1.0,"end_time":1.3,"alternatives":[{"content":"fact"}]},
         {"type":"punctuation","alternatives":[{"content":"."}]},
         {"type":"punctuation","attaches_to":"next","alternatives":[{"content":"\""}]},
         {"type":"word","start_time":1.5,"end_time":1.8,"alternatives":[{"content":"Yes"}]},
         {"type":"punctuation","attaches_to":"previous","alternatives":[{"content":"!"}]},
         {"type":"punctuation","attaches_to":"previous","alternatives":[{"content":"\""}]}]
        """#.utf8))
        let transcript = SpeechmaticsTranscriptionClient.transcript(from: results)
        XCTAssertEqual(transcript.text, #"A well-known fact. "Yes!""#)
        XCTAssertEqual(transcript.words, [
            CloudTranscriptionWord(word: "A", start: 0, end: 0.2),
            CloudTranscriptionWord(word: "well-known", start: 0.2, end: 0.9),
            CloudTranscriptionWord(word: "fact.", start: 1.0, end: 1.3),
            CloudTranscriptionWord(word: #""Yes!""#, start: 1.5, end: 1.8),
        ])
        XCTAssertEqual(transcript.words.map(\.word).joined(separator: " "), transcript.text, "Joining the words gives back the transcript")
    }

    func testErrorsAreMappedAndCarryNoServerText() async throws {
        let cases: [(Int, String, CloudTranscriptionError)] = [
            (401, #"{"code":401,"error":"PRIVATE sm-key"}"#, .authentication),
            (403, #"{"code":403,"detail":"Entitlement check failed","error":"PRIVATE"}"#, .authentication),
            (402, "PRIVATE", .creditsExhausted),
            (429, #"{"code":429,"error":"PRIVATE"}"#, .rateLimited),
            (500, "PRIVATE", .server(500)),
        ]
        for (status, body, expected) in cases {
            let stub = CloudVendorStub([Self.create: [(status, body)]])
            stub.install()
            let error = await CloudJobVendorAssert.failure {
                try await self.client().transcribe(samples: [0.1], configuration: self.configuration, apiKey: "sm-key", wordTimings: false)
            }
            XCTAssertEqual(error as? CloudTranscriptionError, expected, "HTTP \(status)")
            CloudJobVendorAssert.assertSafeMessage(error, providerName: "Speechmatics", secrets: ["PRIVATE", "sm-key"])
            XCTAssertEqual(stub.calls, [Self.create], "Nothing was created, so nothing is deleted")
        }
    }

    func testARejectedJobFailsAndIsDeleted() async throws {
        let stub = CloudVendorStub([
            Self.create: [Self.created], Self.status: [(200, #"{"job":{"id":"job-1","status":"rejected","errors":[{"message":"PRIVATE"}]}}"#)],
            Self.delete: [Self.deleted],
        ])
        stub.install()
        let error = await CloudJobVendorAssert.failure {
            try await self.client().transcribe(samples: [0.1], configuration: self.configuration, apiKey: "k", wordTimings: false)
        }
        XCTAssertEqual(error as? CloudTranscriptionError, .jobFailed)
        CloudJobVendorAssert.assertSafeMessage(error, providerName: "Speechmatics", secrets: ["PRIVATE"])
        XCTAssertEqual(stub.calls, [Self.create, Self.status, Self.delete])
    }

    func testAJobPastItsDeadlineTimesOutAndIsDeleted() async throws {
        let clock = CloudTestClock()
        let stub = CloudVendorStub([Self.create: [Self.created], Self.status: [Self.running], Self.delete: [Self.deleted]])
        stub.install()
        let error = await CloudJobVendorAssert.failure {
            try await self.client(clock).transcribe(samples: [Float](repeating: 0.1, count: 16_000 * 5), configuration: self.configuration, apiKey: "k", wordTimings: false)
        }
        XCTAssertEqual(error as? CloudTranscriptionError, .timeout)
        XCTAssertEqual(clock.now, 130, accuracy: 0.001, "120 s plus twice the audio's duration")
        XCTAssertEqual(stub.calls.last, Self.delete)
    }

    func testACancelledTranscriptionStillDeletesTheJob() async throws {
        let stub = CloudVendorStub([Self.create: [Self.created], Self.status: [(0, "")], Self.delete: [Self.deleted]])
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

    func testKeyCheckListsOneJobWithoutAudio() async throws {
        let stub = CloudVendorStub(["GET /v2/jobs": [(200, #"{"jobs":[]}"#)]])
        stub.install()
        try await self.client().checkKey(apiKey: "sm-key")
        let request = try XCTUnwrap(stub.recorder.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://eu1.asr.api.speechmatics.com/v2/jobs?limit=1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sm-key")
    }

    // MARK: - Engine

    func testEngineAcceptsTheDefaultModelAndRejectsAnUnknownOne() async throws {
        let stub = CloudVendorStub([Self.create: [Self.created], Self.status: [Self.done], Self.transcript: [Self.results], Self.delete: [Self.deleted]])
        stub.install()
        let defaultModel = try XCTUnwrap(CloudTranscriptionCatalog.defaultModelID(for: "speechmatics"))
        XCTAssertEqual(defaultModel, "enhanced")
        let configuration = CloudTranscriptionConfiguration(providerID: "speechmatics", modelID: defaultModel)
        XCTAssertNoThrow(try configuration.validate(wordTimings: true))
        let engine = CloudTranscriptionEngine(client: self.client(), cacheDirectory: nil)
        let result = try await engine.transcribe(samples: [Float](repeating: 0.1, count: 16_000), configuration: configuration, apiKey: "k", wordTimings: false)
        XCTAssertEqual(result.text, "Hello, world.")
        XCTAssertTrue(stub.recorder.requests.allSatisfy { $0.url?.host == "eu1.asr.api.speechmatics.com" })

        let before = stub.recorder.requests.count
        let error = await CloudJobVendorAssert.failure {
            try await engine.transcribe(samples: [0.1], configuration: .init(providerID: "speechmatics", modelID: "nova-3"), apiKey: "k", wordTimings: false)
        }
        XCTAssertEqual(error as? CloudTranscriptionError, .unsupportedModel)
        XCTAssertEqual(stub.recorder.requests.count, before, "An unknown model sends nothing")
    }

    private static func route(_ request: URLRequest) -> String { CloudVendorStub.route(of: request) }

    private func client(_ clock: CloudTestClock = CloudTestClock()) -> SpeechmaticsTranscriptionClient {
        SpeechmaticsTranscriptionClient(session: CloudURLProtocol.session(), poller: clock.poller)
    }
}

#if canImport(LiveTranscriptionHarness)
@testable import LiveTranscriptionHarness
#else
@testable import FluidVoice_Debug
#endif
import XCTest

final class LiveTranscriptionGladiaTests: XCTestCase {
    private let automatic = LiveTranscriptionConfiguration(provider: .gladia, modelID: "solaria-1", languageCode: nil, languageHints: ["en", "pt"])

    func testSessionRequestPostsTheConfigurationWithTheKeyHeader() throws {
        let request = try GladiaLiveAdapter().sessionRequest(apiKey: "k", configuration: self.automatic)
        XCTAssertEqual(request.url?.absoluteString, "https://api.gladia.io/v2/live")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-gladia-key"), "k")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(request.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        XCTAssertEqual(body["encoding"] as? String, "wav/pcm")
        XCTAssertEqual(body["bit_depth"] as? Int, 16)
        XCTAssertEqual(body["sample_rate"] as? Int, 16_000)
        XCTAssertEqual(body["channels"] as? Int, 1)
        XCTAssertEqual(body["model"] as? String, "solaria-1")
        let language = try XCTUnwrap(body["language_config"] as? [String: Any])
        XCTAssertEqual(language["languages"] as? [String], ["en", "pt"])
        XCTAssertEqual(language["code_switching"] as? Bool, true)
        let messages = try XCTUnwrap(body["messages_config"] as? [String: Any])
        XCTAssertEqual(messages["receive_partial_transcripts"] as? Bool, true)
        XCTAssertEqual(messages["receive_final_transcripts"] as? Bool, true)
        XCTAssertEqual(messages["receive_post_processing_events"] as? Bool, true)
        XCTAssertEqual(messages["receive_lifecycle_events"] as? Bool, true)
        XCTAssertEqual(messages["receive_errors"] as? Bool, true)
        XCTAssertEqual(messages["receive_acknowledgments"] as? Bool, false)
    }

    func testAChosenLanguageIsSentAloneAndNoHintsSendNoLanguageConfig() throws {
        let chosen = try GladiaLiveAdapter().sessionRequest(apiKey: "k", configuration: self.automatic.with(languageCode: "pt"))
        let chosenLanguage = try XCTUnwrap(Self.body(chosen)?["language_config"] as? [String: Any])
        XCTAssertEqual(chosenLanguage["languages"] as? [String], ["pt"])
        XCTAssertEqual(chosenLanguage["code_switching"] as? Bool, false)
        let none = LiveTranscriptionConfiguration(provider: .gladia, modelID: "solaria-1", languageCode: nil, languageHints: [])
        XCTAssertNil(Self.body(try GladiaLiveAdapter().sessionRequest(apiKey: "k", configuration: none))?["language_config"])
    }

    func testPrepareConnectionExchangesTheSessionForItsWebSocketURL() async throws {
        let stub = GladiaInitStub(status: 201, body: #"{"id":"s","created_at":"t","url":"wss://api.gladia.io/v2/live?token=abc"}"#)
        let request = try await GladiaLiveAdapter(session: stub.session).prepareConnection(apiKey: "k", configuration: self.automatic)
        XCTAssertEqual(request.url?.absoluteString, "wss://api.gladia.io/v2/live?token=abc")
        XCTAssertNil(request.value(forHTTPHeaderField: "x-gladia-key"), "The WebSocket URL carries its own token")
        let posted = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(posted.method, "POST")
        XCTAssertEqual(posted.key, "k")
        XCTAssertEqual((try JSONSerialization.jsonObject(with: posted.body) as? [String: Any])?["model"] as? String, "solaria-1")
    }

    func testPrepareConnectionMapsRejectionsAndRefusesANonWebSocketURL() async {
        for (status, body, expected) in [
            (401, #"{"message":"PRIVATE"}"#, LiveTranscriptionError.authentication),
            (429, "{}", .rateLimited),
            (422, #"{"validation_errors":["PRIVATE"]}"#, .sessionClosed("http 422")),
            (503, "{}", .connectionFailed),
            (201, #"{"url":"https://example.test/not-a-socket"}"#, .connectionFailed),
            (201, #"{"id":"s"}"#, .connectionFailed),
        ] {
            let stub = GladiaInitStub(status: status, body: body)
            do {
                _ = try await GladiaLiveAdapter(session: stub.session).prepareConnection(apiKey: "k", configuration: self.automatic)
                XCTFail("Expected \(expected) for HTTP \(status)")
            } catch {
                XCTAssertEqual(error as? LiveTranscriptionError, expected, "HTTP \(status)")
            }
        }
    }

    func testAudioIsBinaryAndFinishStopsTheRecording() {
        var adapter = GladiaLiveAdapter()
        XCTAssertEqual(adapter.audioMessage(Data([1, 2])), .data(Data([1, 2])))
        XCTAssertEqual(adapter.finishMessages(), [.text(#"{"type":"stop_recording"}"#)])
        XCTAssertFalse(adapter.waitsForReady)
    }

    func testTranscriptsPostProcessingAndEndOfSession() {
        var adapter = GladiaLiveAdapter()
        XCTAssertEqual(
            adapter.parse(.text(#"{"session_id":"s","type":"transcript","data":{"id":"00-00000011","is_final":false,"utterance":{"start":0,"end":0.3,"text":"Hello wor"}}}"#)),
            [.pending("Hello wor")]
        )
        XCTAssertEqual(
            adapter.parse(.text(#"{"session_id":"s","type":"transcript","data":{"id":"00-00000011","is_final":true,"utterance":{"start":0,"end":0.48,"text":"Hello world."}}}"#)),
            [.segment(.init(id: "00-00000011", text: "Hello world.", isFinal: true, audioEndMilliseconds: 480)), .pending("")]
        )
        XCTAssertEqual(
            adapter.parse(.text(#"{"type":"post_final_transcript","data":{"metadata":{"audio_duration":1.2},"transcription":{"full_transcript":"Hello world."}}}"#)),
            [.replaceAll("Hello world.")]
        )
        XCTAssertEqual(adapter.parse(.text(#"{"type":"end_session","session_id":"s"}"#)), [.finished])
        XCTAssertEqual(adapter.parse(.text(#"{"type":"start_session","session_id":"s","error":null}"#)), [])
    }

    func testInStreamErrorsMapWithoutTheirMessage() {
        var adapter = GladiaLiveAdapter()
        XCTAssertEqual(
            adapter.parse(.text(#"{"type":"audio_chunk","error":{"status_code":400,"exception":"InvalidArgument","message":"PRIVATE"}}"#)),
            [.failure(.sessionClosed("InvalidArgument"))]
        )
        XCTAssertEqual(
            adapter.parse(.text(#"{"type":"audio_chunk","error":{"status_code":401,"exception":"Unauthorized","message":"PRIVATE"}}"#)),
            [.failure(.authentication)]
        )
    }

    func testAFailedPostProcessingStepKeepsTheRealtimeFinals() {
        var adapter = GladiaLiveAdapter()
        var assembler = LiveTranscriptAssembler()
        for message in [
            #"{"type":"transcript","data":{"id":"00-1","is_final":true,"utterance":{"start":0,"end":0.5,"text":"Hello world."}}}"#,
            #"{"type":"post_transcript","error":{"status_code":500,"exception":"InternalError","message":"PRIVATE"},"data":null}"#,
            #"{"type":"translation","error":{"status_code":500,"exception":"InternalError","message":"PRIVATE"},"data":null}"#,
        ] {
            let updates = adapter.parse(.text(message))
            XCTAssertFalse(updates.contains { if case .failure = $0 { true } else { false } }, "An add-on error does not end the session")
            updates.forEach { assembler.apply($0) }
        }
        XCTAssertEqual(adapter.parse(.text(#"{"type":"end_session","session_id":"s"}"#)), [.finished])
        XCTAssertEqual(assembler.finalText, "Hello world.")
    }

    func testKeyCheck() throws {
        let request = try GladiaLiveAdapter().keyCheckRequest(apiKey: "k")
        XCTAssertEqual(request.url?.absoluteString, "https://api.gladia.io/v2/live?limit=1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-gladia-key"), "k")
    }

    func testSessionOpensTheReturnedURLAndPostsAgainOnReconnect() async throws {
        let stub = GladiaInitStub(status: 201, body: #"{"url":"wss://api.gladia.io/v2/live?token=abc"}"#)
        let first = FakeLiveTransport()
        let second = FakeLiveTransport()
        second.respond = { message in
            message == .text(#"{"type":"stop_recording"}"#)
                ? [
                    .success(.text(#"{"type":"transcript","data":{"id":"a","is_final":true,"utterance":{"end":0.5,"text":"bye"}}}"#)),
                    .success(.text(#"{"type":"end_session"}"#)),
                ]
                : []
        }
        let transports = LockedQueue([first, second])
        let session = LiveTranscriptionSession(adapter: GladiaLiveAdapter(session: stub.session), configuration: self.automatic, apiKey: "k") { transports.next() }
        try await session.start()
        await session.append([Float](repeating: 0.1, count: 16_000))
        first.deliver(.success(.text(#"{"type":"transcript","data":{"id":"b","is_final":true,"utterance":{"end":0.6,"text":"hello"}}}"#)))
        first.deliver(.failure(LiveTransportClosed(closeCode: 1006, reason: nil, upgradeStatus: nil)))
        try await Task.sleep(for: .milliseconds(50))
        let text = try await session.finish()
        XCTAssertEqual(text, "hello bye")
        XCTAssertEqual(first.openedRequests.first?.url?.absoluteString, "wss://api.gladia.io/v2/live?token=abc")
        XCTAssertEqual(second.openedRequests.count, 1)
        XCTAssertEqual(stub.requests.count, 2, "Each connection starts with its own session request")
    }

    func testARejectedSessionRequestOpensNoSocket() async {
        let stub = GladiaInitStub(status: 401, body: "{}")
        let transport = FakeLiveTransport()
        let session = LiveTranscriptionSession(adapter: GladiaLiveAdapter(session: stub.session), configuration: self.automatic, apiKey: "k") { transport }
        do {
            try await session.start()
            XCTFail("Expected authentication")
        } catch {
            XCTAssertEqual(error as? LiveTranscriptionError, .authentication)
        }
        XCTAssertTrue(transport.openedRequests.isEmpty)
    }

    private static func body(_ request: URLRequest) -> [String: Any]? { // swiftlint:disable:this discouraged_optional_collection
        request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
}

/// Answers Gladia's session request with a fixed status and body, and records what was posted.
/// Each stub is found by a unique token its session adds as a header, so stubs never share state.
final class GladiaInitStub: @unchecked Sendable {
    struct Posted {
        let method: String?
        let key: String?
        let body: Data
    }

    private let lock = NSLock()
    private var posted: [Posted] = []
    let status: Int
    let body: String
    let session: URLSession

    init(status: Int, body: String) {
        self.status = status
        self.body = body
        let token = UUID().uuidString
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GladiaInitURLProtocol.self]
        configuration.httpAdditionalHeaders = [GladiaInitURLProtocol.tokenHeader: token]
        self.session = URLSession(configuration: configuration)
        GladiaInitURLProtocol.register(self, token: token)
    }

    var requests: [Posted] { self.lock.withLock { self.posted } }

    func record(_ posted: Posted) { self.lock.withLock { self.posted.append(posted) } }
}

final class GladiaInitURLProtocol: URLProtocol, @unchecked Sendable {
    static let tokenHeader = "X-Test-Stub"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var stubs: [String: GladiaInitStub] = [:]

    static func register(_ stub: GladiaInitStub, token: String) {
        self.lock.withLock { self.stubs[token] = stub }
    }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let token = self.request.value(forHTTPHeaderField: Self.tokenHeader) ?? ""
        guard let stub = Self.lock.withLock({ Self.stubs[token] }), let url = self.request.url,
              let response = HTTPURLResponse(url: url, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: nil)
        else {
            self.client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        stub.record(.init(method: self.request.httpMethod, key: self.request.value(forHTTPHeaderField: "x-gladia-key"), body: Self.body(of: self.request)))
        self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        self.client?.urlProtocol(self, didLoad: Data(stub.body.utf8))
        self.client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession hands a protocol the body as a stream.
    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

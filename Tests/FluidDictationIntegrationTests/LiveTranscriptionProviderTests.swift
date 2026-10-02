#if canImport(LiveTranscriptionHarness)
@testable import LiveTranscriptionHarness
#else
@testable import FluidVoice_Debug
#endif
import XCTest

@MainActor
final class LiveTranscriptionProviderTests: XCTestCase {
    private let configuration = LiveTranscriptionConfiguration(provider: .deepgram, modelID: "nova-3", languageCode: nil, languageHints: [])

    func testFinalPassSendsOnlyTheTailNotYetStreamed() async throws {
        let transport = FakeLiveTransport()
        transport.respond = { message in
            message == .text(#"{"type":"CloseStream"}"#)
                ? [
                    .success(.text(#"{"type":"Results","start":0,"duration":2,"is_final":true,"channel":{"alternatives":[{"transcript":"done"}]}}"#)),
                    .success(.text(#"{"type":"Metadata"}"#)),
                ]
                : []
        }
        let provider = LiveCloudTranscriptionProvider(configuration: self.configuration, apiKey: "k", localProvider: nil, makeTransport: { transport })
        await provider.begin()
        let recording = [Float](repeating: 0.1, count: 32_000)
        await provider.append(Array(recording[0 ..< 16_000]))
        let result = try await provider.transcribeFinal(recording)
        XCTAssertEqual(result.text, "done")
        XCTAssertEqual(transport.sentAudioBytes, 32_000 * 2)
    }

    func testAStreamThatNeverOpenedReportsItsErrorAtTheFinalPass() async {
        let transport = FakeLiveTransport()
        transport.openError = LiveTransportClosed(closeCode: 0, reason: nil, upgradeStatus: 401)
        let provider = LiveCloudTranscriptionProvider(configuration: self.configuration, apiKey: "k", localProvider: nil, makeTransport: { transport })
        await provider.begin()
        do {
            _ = try await provider.transcribeFinal([0.1])
            XCTFail("Expected authentication")
        } catch {
            XCTAssertEqual(error as? LiveTranscriptionError, .authentication)
        }
    }

    func testAFinalPassAfterCancelReturnsNoTextAndOpensNoConnection() async {
        let transport = FakeLiveTransport()
        let provider = LiveCloudTranscriptionProvider(configuration: self.configuration, apiKey: "k", localProvider: nil, makeTransport: { transport })
        await provider.begin()
        await provider.append([Float](repeating: 0.1, count: 16_000))
        await provider.cancel()
        do {
            _ = try await provider.transcribeFinal([Float](repeating: 0.1, count: 16_000))
            XCTFail("Expected a cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(transport.openedRequests.count, 1, "A discarded dictation is never replayed on a new connection")
    }

    func testTheFinishDeadlineCoversTheTailOnAStalledSocket() async throws {
        let transport = StallingTransport()
        let provider = LiveCloudTranscriptionProvider(
            configuration: self.configuration,
            apiKey: "k",
            localProvider: nil,
            makeTransport: { transport },
            finishTimeout: .milliseconds(200)
        )
        await provider.begin()
        let recording = [Float](repeating: 0.1, count: 16_000)
        let outcome = try await LiveTranscriptionSessionTests.outcome(
            within: .seconds(2),
            of: { try await provider.transcribeFinal(recording).text },
            else: { transport.close() }
        )
        XCTAssertEqual(outcome, .failure(.finalTimeout), "Sending the tail counts against the finish deadline")
    }

    func testAnEmptyKeyFailsWithoutContactingTheProvider() async {
        let transports = LockedBox(0)
        let provider = LiveCloudTranscriptionProvider(configuration: self.configuration, apiKey: " ", localProvider: nil, makeTransport: {
            transports.value += 1
            return FakeLiveTransport()
        })
        await provider.begin()
        await provider.append([Float](repeating: 0.1, count: 16_000))
        for attempt in ["final pass", "retry"] {
            do {
                _ = attempt == "retry"
                    ? try await provider.transcribe([Float](repeating: 0.1, count: 16_000))
                    : try await provider.transcribeFinal([Float](repeating: 0.1, count: 16_000))
                XCTFail("Expected a missing key for the \(attempt)")
            } catch {
                XCTAssertEqual(error as? LiveTranscriptionError, .missingAPIKey, attempt)
            }
        }
        XCTAssertEqual(transports.value, 0, "No socket is made without a key")
    }

    func testReadinessIsLocal() {
        XCTAssertTrue(LiveCloudTranscriptionProvider(configuration: self.configuration, apiKey: "k", localProvider: nil).isReady)
        XCTAssertFalse(LiveCloudTranscriptionProvider(configuration: self.configuration, apiKey: "  ", localProvider: nil).isReady)
    }

    func testStreamingPreviewCallIsNotUsed() async {
        let provider = LiveCloudTranscriptionProvider(configuration: self.configuration, apiKey: "k", localProvider: nil)
        do {
            _ = try await provider.transcribeStreaming([0.1])
            XCTFail("Live providers publish partials through the session")
        } catch {}
    }

    // MARK: - Key check

    func testKeyCheckAcceptsASuccessfulResponse() async throws {
        let session = LiveKeyCheckURLProtocol.session(status: 200)
        try await LiveTranscriptionKeyChecker.check(provider: .deepgram, apiKey: "k", session: session)
        XCTAssertEqual(LiveKeyCheckURLProtocol.requestCount, 1)
    }

    func testKeyCheckMapsRejectedKeysAndExhaustedQuota() async {
        for (status, expected) in [(401, LiveTranscriptionError.authentication), (402, .quotaExhausted)] {
            let session = LiveKeyCheckURLProtocol.session(status: status)
            do {
                try await LiveTranscriptionKeyChecker.check(provider: .soniox, apiKey: "k", session: session)
                XCTFail("Expected \(expected) for HTTP \(status)")
            } catch {
                XCTAssertEqual(error as? LiveTranscriptionError, expected)
            }
        }
    }

    /// The Live check agrees with the ElevenLabs Cloud check: a key restricted to other endpoints than the
    /// model list authenticated; a plain 401, another 403 or a 403 without a permission code is rejected.
    func testElevenLabsKeyCheckAcceptsAPermissionRestrictedKeyLikeTheCloudCheck() async throws {
        for code in ["insufficient_permissions", "missing_permissions"] {
            let session = LiveKeyCheckURLProtocol.session(status: 403, body: #"{"detail":{"status":"\#(code)","message":"PRIVATE"}}"#)
            try await LiveTranscriptionKeyChecker.check(provider: .elevenLabs, apiKey: "k", session: session)
        }
        let cases: [(Int, String, LiveTranscriptionError)] = [
            (401, #"{"detail":{"status":"invalid_api_key"}}"#, .authentication),
            (403, #"{"detail":{"status":"forbidden"}}"#, .authentication),
            (403, "{}", .authentication),
            (401, #"{"detail":{"status":"quota_exceeded"}}"#, .quotaExhausted),
        ]
        for (status, body, expected) in cases {
            let session = LiveKeyCheckURLProtocol.session(status: status, body: body)
            do {
                try await LiveTranscriptionKeyChecker.check(provider: .elevenLabs, apiKey: "k", session: session)
                XCTFail("Expected \(expected) for HTTP \(status) \(body)")
            } catch {
                XCTAssertEqual(error as? LiveTranscriptionError, expected, "HTTP \(status) \(body)")
            }
        }
    }

    func testOtherProvidersStillRejectAPermissionRestricted403() async {
        let session = LiveKeyCheckURLProtocol.session(status: 403, body: #"{"detail":{"status":"insufficient_permissions"}}"#)
        do {
            try await LiveTranscriptionKeyChecker.check(provider: .deepgram, apiKey: "k", session: session)
            XCTFail("Expected a rejected key")
        } catch {
            XCTAssertEqual(error as? LiveTranscriptionError, .authentication)
        }
    }

    func testKeyCheckWithAnEmptyKeySendsNoRequest() async {
        let session = LiveKeyCheckURLProtocol.session(status: 200)
        do {
            try await LiveTranscriptionKeyChecker.check(provider: .assemblyAI, apiKey: " \n", session: session)
            XCTFail("Expected a missing key")
        } catch {
            XCTAssertEqual(error as? LiveTranscriptionError, .missingAPIKey)
        }
        XCTAssertEqual(LiveKeyCheckURLProtocol.requestCount, 0)
    }

    // MARK: - Usage

    func testUsagePersistsAcrossReloadsAndIgnoresUnknownProviders() throws {
        let suite = "LiveTranscriptionUsageTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LiveTranscriptionUsageStore(defaults: defaults)
        store.record(provider: .soniox, milliseconds: 1500)
        store.record(provider: .soniox, milliseconds: 2500)
        store.record(provider: .deepgram, milliseconds: 0)
        let reloaded = LiveTranscriptionUsageStore(defaults: defaults)
        XCTAssertEqual(reloaded.totals(for: .soniox), .init(milliseconds: 4000, recordings: 2))
        XCTAssertEqual(reloaded.totals(for: .soniox).seconds, 4)
        XCTAssertEqual(reloaded.totals(for: .deepgram), .init())

        let stored = #"{"soniox":{"milliseconds":1000,"recordings":1},"retired-vendor":{"milliseconds":9000,"recordings":3}}"#
        defaults.set(Data(stored.utf8), forKey: "LiveTranscriptionUsage")
        let withUnknown = LiveTranscriptionUsageStore(defaults: defaults)
        XCTAssertEqual(withUnknown.totals.count, 1)
        XCTAssertEqual(withUnknown.totals(for: .soniox), .init(milliseconds: 1000, recordings: 1))
    }
}

/// Answers every request with a fixed HTTP status and counts the requests it saw.
final class LiveKeyCheckURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var status = 200
    nonisolated(unsafe) private static var body = "{}"
    nonisolated(unsafe) private static var requests = 0

    static var requestCount: Int { self.lock.withLock { self.requests } }

    static func session(status: Int, body: String = "{}") -> URLSession {
        self.lock.withLock {
            self.status = status
            self.body = body
            self.requests = 0
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LiveKeyCheckURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (status, body) = Self.lock.withLock { () -> (Int, String) in
            Self.requests += 1
            return (Self.status, Self.body)
        }
        guard let url = self.request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)
        else {
            self.client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        self.client?.urlProtocol(self, didLoad: Data(body.utf8))
        self.client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

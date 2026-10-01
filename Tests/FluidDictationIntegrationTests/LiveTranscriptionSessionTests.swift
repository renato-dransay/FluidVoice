#if canImport(LiveTranscriptionHarness)
@testable import LiveTranscriptionHarness
#else
@testable import FluidVoice_Debug
#endif
import XCTest

/// Scripted socket: records what the session sends and answers with queued messages.
final class FakeLiveTransport: LiveTranscriptionTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var inbox: [Result<LiveTransportMessage, Error>] = []
    private var waiters: [CheckedContinuation<LiveTransportMessage, Error>] = []
    private(set) var sent: [LiveTransportMessage] = []
    private(set) var openedRequests: [URLRequest] = []
    var openError: Error?
    /// Called for every sent message; returns messages to deliver in answer.
    var respond: (LiveTransportMessage) -> [Result<LiveTransportMessage, Error>] = { _ in [] }

    func open(_ request: URLRequest) async throws {
        self.lock.withLock { self.openedRequests.append(request) }
        if let openError { throw openError }
    }

    func send(_ message: LiveTransportMessage) async throws {
        let replies = self.lock.withLock { () -> [Result<LiveTransportMessage, Error>] in
            self.sent.append(message)
            return self.respond(message)
        }
        replies.forEach(self.deliver)
    }

    func receive() async throws -> LiveTransportMessage {
        try await withCheckedThrowingContinuation { continuation in
            let next = self.lock.withLock { () -> Result<LiveTransportMessage, Error>? in
                if self.inbox.isEmpty { self.waiters.append(continuation); return nil }
                return self.inbox.removeFirst()
            }
            if let next { continuation.resume(with: next) }
        }
    }

    func close() {}

    func deliver(_ result: Result<LiveTransportMessage, Error>) {
        let waiter = self.lock.withLock { () -> CheckedContinuation<LiveTransportMessage, Error>? in
            if self.waiters.isEmpty { self.inbox.append(result); return nil }
            return self.waiters.removeFirst()
        }
        waiter?.resume(with: result)
    }

    var sentAudioBytes: Int {
        self.lock.withLock { self.sent.reduce(0) { total, message in if case .data(let data) = message { total + data.count } else { total } } }
    }
}

/// Minimal adapter: text "final:<text>:<endMs>" and "pending:<text>" and "finished".
struct ScriptAdapter: LiveTranscriptionAdapter {
    var provider: LiveTranscriptionProviderID { .deepgram }
    func connectionRequest(apiKey: String, configuration: LiveTranscriptionConfiguration) throws -> URLRequest {
        try LiveHTTPStatus.request("wss://example.test/\(configuration.languageCode ?? "auto")", headers: [:])
    }
    func finishMessages() -> [LiveTransportMessage] { [.text("finish")] }
    func keyCheckRequest(apiKey: String) throws -> URLRequest { try LiveHTTPStatus.request("https://example.test", headers: [:]) }
    mutating func parse(_ message: LiveTransportMessage) -> [LiveTranscriptUpdate] {
        guard case .text(let text) = message else { return [] }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        switch parts.first {
        case "final": return [.segment(.init(id: UUID().uuidString, text: parts[1], isFinal: true, audioEndMilliseconds: Int(parts[2]))), .pending("")]
        case "pending": return [.pending(parts[1])]
        case "finished": return [.finished]
        case "error": return [.failure(.authentication)]
        default: return []
        }
    }
}

/// `ScriptAdapter` for a provider that sends no audio before its greeting, the text "ready".
struct GreetingScriptAdapter: LiveTranscriptionAdapter {
    private var script = ScriptAdapter()
    var provider: LiveTranscriptionProviderID { .assemblyAI }
    var waitsForReady: Bool { true }
    func connectionRequest(apiKey: String, configuration: LiveTranscriptionConfiguration) throws -> URLRequest {
        try self.script.connectionRequest(apiKey: apiKey, configuration: configuration)
    }
    func finishMessages() -> [LiveTransportMessage] { self.script.finishMessages() }
    func keyCheckRequest(apiKey: String) throws -> URLRequest { try self.script.keyCheckRequest(apiKey: apiKey) }
    mutating func parse(_ message: LiveTransportMessage) -> [LiveTranscriptUpdate] {
        message == .text("ready") ? [.ready] : self.script.parse(message)
    }
}

final class LiveTranscriptionSessionTests: XCTestCase {
    private let configuration = LiveTranscriptionConfiguration(provider: .deepgram, modelID: "nova-3", languageCode: nil, languageHints: [])

    func testStreamsAudioInValidChunksAndReturnsTheFinalText() async throws {
        let transport = FakeLiveTransport()
        transport.respond = { message in
            message == .text("finish") ? [.success(.text("final:hello world:1000")), .success(.text("finished"))] : []
        }
        let session = self.session { transport }
        try await session.start()
        await session.append([Float](repeating: 0.1, count: 800))   // 50 ms
        await session.append([Float](repeating: 0.1, count: 16_000))  // 1 s
        let text = try await session.finish()
        XCTAssertEqual(text, "hello world")
        let chunks = transport.sent.compactMap { message -> Int? in if case .data(let data) = message { data.count } else { nil } }
        XCTAssertTrue(chunks.allSatisfy { $0 >= 50 * 32 && $0 <= 1000 * 32 }, "\(chunks)")
        XCTAssertEqual(chunks.reduce(0, +), (800 + 16_000) * 2)
        XCTAssertEqual(transport.sent.last, .text("finish"))
    }

    func testAudioHeldUntilTheGreetingStillGoesOutInValidChunks() async throws {
        let transport = FakeLiveTransport()
        transport.respond = { message in message == .text("finish") ? [.success(.text("finished"))] : [] }
        let session = LiveTranscriptionSession(adapter: GreetingScriptAdapter(), configuration: self.configuration, apiKey: "test-key") { transport }
        try await session.start()
        await session.append([Float](repeating: 0.1, count: 16_320)) // 1020 ms, all held until "ready"
        async let text = session.finish()
        try await Task.sleep(for: .milliseconds(20))
        transport.deliver(.success(.text("ready")))
        _ = try await text
        let chunks = transport.sent.compactMap { message -> Int? in if case .data(let data) = message { data.count } else { nil } }
        XCTAssertTrue(chunks.allSatisfy { $0 >= 50 * 32 && $0 <= 1000 * 32 }, "\(chunks)")
        XCTAssertEqual(chunks.reduce(0, +), 16_320 * 2)
    }

    func testPublishesDisplayTextAsUpdatesArrive() async throws {
        let transport = FakeLiveTransport()
        let session = self.session { transport }
        var iterator = session.partials.makeAsyncIterator()
        try await session.start()
        transport.deliver(.success(.text("pending:hel")))
        transport.deliver(.success(.text("final:hello:500")))
        let first = await iterator.next()
        let second = await iterator.next()
        XCTAssertEqual(first, "hel")
        XCTAssertEqual(second, "hello")
    }

    func testTimesOutWhenTheProviderNeverFinishes() async throws {
        let transport = FakeLiveTransport()
        let session = self.session(timeout: .milliseconds(200)) { transport }
        try await session.start()
        await session.append([Float](repeating: 0.1, count: 16_000))
        do {
            _ = try await session.finish()
            XCTFail("Expected a timeout")
        } catch {
            XCTAssertEqual(error as? LiveTranscriptionError, .finalTimeout)
        }
    }

    func testReconnectsOnceAndReplaysOnlyAudioAfterTheLastFinal() async throws {
        let first = FakeLiveTransport()
        let second = FakeLiveTransport()
        second.respond = { message in
            message == .text("finish") ? [.success(.text("final:part two:500")), .success(.text("finished"))] : []
        }
        let transports = LockedQueue([first, second])
        let session = self.session { transports.next() }
        try await session.start()
        await session.append([Float](repeating: 0.1, count: 32_000)) // 2 s
        first.deliver(.success(.text("final:part one:1500")))
        first.deliver(.failure(LiveTransportClosed(closeCode: 1006, reason: nil, upgradeStatus: nil)))
        let text = try await session.finish()
        XCTAssertEqual(text, "part one part two")
        XCTAssertEqual(second.sentAudioBytes, 500 * 32, "Only the 500 ms after the last final are replayed")
    }

    func testSecondDropFailsWithConnectionLost() async throws {
        let transports = LockedQueue([FakeLiveTransport(), FakeLiveTransport()])
        let all = transports.snapshot
        let session = self.session { transports.next() }
        try await session.start()
        await session.append([Float](repeating: 0.1, count: 16_000))
        all[0].deliver(.failure(LiveTransportClosed(closeCode: 1006, reason: nil, upgradeStatus: nil)))
        try await Task.sleep(for: .milliseconds(50))
        all[1].deliver(.failure(LiveTransportClosed(closeCode: 1006, reason: nil, upgradeStatus: nil)))
        do {
            _ = try await session.finish()
            XCTFail("Expected a failure")
        } catch {
            XCTAssertEqual(error as? LiveTranscriptionError, .connectionLost)
        }
    }

    func testUpgradeRejectionMapsToAuthenticationWithoutReconnecting() async {
        let transport = FakeLiveTransport()
        transport.openError = LiveTransportClosed(closeCode: 0, reason: nil, upgradeStatus: 401)
        let session = self.session { transport }
        do {
            try await session.start()
            XCTFail("Expected authentication")
        } catch {
            XCTAssertEqual(error as? LiveTranscriptionError, .authentication)
        }
        XCTAssertEqual(transport.openedRequests.count, 1)
    }

    func testProviderErrorFrameEndsTheSessionWithItsError() async throws {
        let transport = FakeLiveTransport()
        let session = self.session { transport }
        try await session.start()
        transport.deliver(.success(.text("error")))
        do {
            _ = try await session.finish()
            XCTFail("Expected authentication")
        } catch {
            XCTAssertEqual(error as? LiveTranscriptionError, .authentication)
        }
    }

    func testLanguageChangeReconnectsWithTheNewLanguageAndKeepsFinals() async throws {
        let first = FakeLiveTransport()
        let second = FakeLiveTransport()
        second.respond = { message in
            message == .text("finish") ? [.success(.text("final:olá:300")), .success(.text("finished"))] : []
        }
        let transports = LockedQueue([first, second])
        let session = self.session { transports.next() }
        try await session.start()
        await session.append([Float](repeating: 0.1, count: 16_000))
        first.deliver(.success(.text("final:hello:1000")))
        try await Task.sleep(for: .milliseconds(20))
        await session.reconfigure(languageCode: "pt")
        let text = try await session.finish()
        XCTAssertEqual(text, "hello olá")
        XCTAssertEqual(second.openedRequests.first?.url?.lastPathComponent, "pt")
    }

    private func session(timeout: Duration = .seconds(2), _ makeTransport: @escaping @Sendable () -> any LiveTranscriptionTransport) -> LiveTranscriptionSession {
        LiveTranscriptionSession(adapter: ScriptAdapter(), configuration: self.configuration, apiKey: "test-key", makeTransport: makeTransport, finishTimeout: timeout)
    }
}

final class LockedQueue<Element: AnyObject>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Element]
    let snapshot: [Element]
    init(_ items: [Element]) { self.items = items; self.snapshot = items }
    func next() -> Element { self.lock.withLock { self.items.removeFirst() } }
}

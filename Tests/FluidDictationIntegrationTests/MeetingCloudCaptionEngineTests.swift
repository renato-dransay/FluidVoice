import AVFoundation
import CoreMedia
@testable import FluidVoice_Debug
import XCTest

/// Scripted socket: records what the session sends and answers with delivered messages. The live
/// session tests have their own copy; they build only in the SwiftPM harness, not in this target.
private final class CaptionFakeTransport: LiveTranscriptionTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var inbox: [Result<LiveTransportMessage, Error>] = []
    private var waiters: [CheckedContinuation<LiveTransportMessage, Error>] = []
    private var sent: [LiveTransportMessage] = []
    private var closes = 0

    func open(_ request: URLRequest) async throws {}

    func send(_ message: LiveTransportMessage) async throws {
        self.lock.withLock { self.sent.append(message) }
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

    func close() { self.lock.withLock { self.closes += 1 } }

    var closeCount: Int { self.lock.withLock { self.closes } }

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

/// Text "final:<text>:<endMs>", "pending:<text>" and "error" (a rejected key).
private struct CaptionScriptAdapter: LiveTranscriptionAdapter {
    private var finals = 0
    var provider: LiveTranscriptionProviderID { .deepgram }
    func connectionRequest(apiKey: String, configuration: LiveTranscriptionConfiguration) throws -> URLRequest {
        try LiveHTTPStatus.request("wss://example.test/captions", headers: [:])
    }
    func finishMessages() -> [LiveTransportMessage] { [.text("finish")] }
    func keyCheckRequest(apiKey: String) throws -> URLRequest { try LiveHTTPStatus.request("https://example.test", headers: [:]) }
    mutating func parse(_ message: LiveTransportMessage) -> [LiveTranscriptUpdate] {
        guard case .text(let text) = message else { return [] }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        switch parts.first {
        case "final":
            self.finals += 1
            return [.segment(.init(id: "f\(self.finals)", text: parts[1], isFinal: true, audioEndMilliseconds: Int(parts[2]))), .pending("")]
        case "pending": return [.pending(parts[1])]
        case "error": return [.failure(.authentication)]
        default: return []
        }
    }
}

/// Records what an engine reports, from any thread.
private final class CaptionRecorder: @unchecked Sendable {
    struct Event: Equatable {
        enum Kind: Equatable { case partial, utterance }
        let kind: Kind
        let id: UUID
        let text: String
    }

    private let lock = NSLock()
    private var storedEvents: [Event] = []
    private var storedDegraded: [String] = []
    private var storedReady = 0
    private var storedUsage: [(LiveTranscriptionProviderID, Int)] = []

    var events: [Event] { self.lock.withLock { self.storedEvents } }
    var utterances: [String] { self.events.filter { $0.kind == .utterance }.map(\.text) }
    var degraded: [String] { self.lock.withLock { self.storedDegraded } }
    var readyCount: Int { self.lock.withLock { self.storedReady } }
    var usage: [(LiveTranscriptionProviderID, Int)] { self.lock.withLock { self.storedUsage } }

    func configure(_ engine: MeetingCloudCaptionEngine) async {
        await engine.configure(
            onPartial: { [self] _, id, text, _, _ in self.lock.withLock { self.storedEvents.append(.init(kind: .partial, id: id, text: text)) } },
            onUtterance: { [self] _, id, text, _, _ in self.lock.withLock { self.storedEvents.append(.init(kind: .utterance, id: id, text: text)) } },
            onDegraded: { [self] _, reason in self.lock.withLock { self.storedDegraded.append(reason) } },
            onReady: { [self] _ in self.lock.withLock { self.storedReady += 1 } }
        )
    }

    func recordUsage(_ provider: LiveTranscriptionProviderID, _ milliseconds: Int) {
        self.lock.withLock { self.storedUsage.append((provider, milliseconds)) }
    }
}

/// Hands out scripted transports and counts the sessions the engine opens.
private final class SessionScript: @unchecked Sendable {
    private let lock = NSLock()
    private var storedTransports: [CaptionFakeTransport] = []
    private var storedSessions = 0

    var transports: [CaptionFakeTransport] { self.lock.withLock { self.storedTransports } }
    var sessions: Int { self.lock.withLock { self.storedSessions } }

    func makeSession(configuration: LiveTranscriptionConfiguration, apiKey: String) -> LiveTranscriptionSession {
        self.lock.withLock { self.storedSessions += 1 }
        return LiveTranscriptionSession(
            adapter: CaptionScriptAdapter(),
            configuration: configuration,
            apiKey: apiKey,
            makeTransport: { [self] in
                let transport = CaptionFakeTransport()
                self.lock.withLock { self.storedTransports.append(transport) }
                return transport
            },
            finishTimeout: .seconds(1),
            partialsBuffering: .bufferingNewest(1)
        )
    }
}

final class MeetingCloudCaptionEngineTests: XCTestCase {
    private let configuration = LiveTranscriptionConfiguration(provider: .deepgram, modelID: "nova-3", languageCode: nil, languageHints: [])
    private var testTiming: MeetingCloudCaptionTiming {
        var timing = MeetingCloudCaptionTiming()
        timing.quietSeconds = 0.1
        timing.stallSeconds = 0.3
        timing.idleSilenceSeconds = 100
        timing.retryDelaysSeconds = [0]
        timing.pollSeconds = 0.005
        return timing
    }

    func testFinalTextClosesATurnAfterAPauseKeepingThePartialsIdentity() async throws {
        let (engine, recorder, script) = await self.startedEngine()
        await self.speak(to: engine, script: script)
        let transport = try XCTUnwrap(script.transports.first)

        transport.deliver(.success(.text("pending:hello")))
        try await self.waitUntil { recorder.events.contains { $0.kind == .partial && $0.text == "hello" } }
        transport.deliver(.success(.text("final:hello there:900")))
        try await self.waitUntil { recorder.utterances == ["hello there"] }

        transport.deliver(.success(.text("final:next words:1500")))
        try await self.waitUntil { recorder.utterances == ["hello there", "next words"] }
        let events = recorder.events
        let firstID = try XCTUnwrap(events.first { $0.text == "hello" }?.id)
        XCTAssertEqual(events.first { $0.kind == .utterance && $0.text == "hello there" }?.id, firstID)
        XCTAssertNotEqual(events.first { $0.kind == .utterance && $0.text == "next words" }?.id, firstID)
        await engine.stop()
    }

    func testProvisionalTextThatStopsChangingClosesAfterTheStallDelay() async throws {
        let (engine, recorder, script) = await self.startedEngine()
        await self.speak(to: engine, script: script)
        try XCTUnwrap(script.transports.first).deliver(.success(.text("pending:never finalized")))
        try await self.waitUntil { recorder.utterances == ["never finalized"] }
        await engine.stop()
    }

    func testARejectedKeyStopsCaptionsWithoutReconnecting() async throws {
        let (engine, recorder, script) = await self.startedEngine()
        await self.speak(to: engine, script: script)
        try XCTUnwrap(script.transports.first).deliver(.success(.text("error")))
        try await self.waitUntil { !recorder.degraded.isEmpty }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(recorder.degraded, ["Deepgram rejected the API key, so live captions stopped. Recording continues."])
        XCTAssertEqual(script.sessions, 1)
        await engine.stop()
    }

    func testALostConnectionOpensANewSessionAndReportsReadyAgain() async throws {
        let (engine, recorder, script) = await self.startedEngine()
        await self.speak(to: engine, script: script)
        let dropped = LiveTransportClosed(closeCode: 1006, reason: nil, upgradeStatus: nil)
        // The session reconnects once on its own; the second drop ends it.
        try XCTUnwrap(script.transports.first).deliver(.failure(dropped))
        try await self.waitUntil { script.transports.count == 2 }
        script.transports[1].deliver(.failure(dropped))
        try await self.waitUntil { script.sessions == 2 && recorder.readyCount == 2 }
        XCTAssertEqual(recorder.degraded, ["Live captions lost the connection to Deepgram and are reconnecting."])
        await engine.stop()
    }

    func testALongSessionIsReplacedAtAPause() async throws {
        var timing = self.testTiming
        timing.rotationSeconds = 0.5
        let (engine, recorder, script) = await self.startedEngine(timing: timing)
        await self.speak(to: engine, script: script)
        try XCTUnwrap(script.transports.first).deliver(.success(.text("final:before:500")))
        try await self.waitUntil { recorder.utterances == ["before"] && script.sessions == 2 }
        XCTAssertGreaterThan(script.transports[0].closeCount, 0)
        await self.speak(to: engine, script: script)
        try await self.waitUntil { script.transports.count == 2 }
        script.transports[1].deliver(.success(.text("final:after:500")))
        try await self.waitUntil { recorder.utterances == ["before", "after"] }
        await engine.stop()
    }

    func testAnIdleTrackStreamsSilenceSoTheConnectionStaysOpen() async throws {
        var timing = self.testTiming
        timing.idleSilenceSeconds = 0.05
        let (engine, _, script) = await self.startedEngine(timing: timing)
        await self.speak(to: engine, script: script)
        let transport = try XCTUnwrap(script.transports.first)
        let afterSpeech = transport.sentAudioBytes
        try await self.waitUntil { transport.sentAudioBytes > afterSpeech + 16_000 }
        await engine.stop()
    }

    func testStopClosesTheConnectionAndRecordsUsageOnce() async throws {
        let (engine, recorder, script) = await self.startedEngine()
        await self.speak(to: engine, script: script)
        await engine.stop()
        XCTAssertGreaterThan(try XCTUnwrap(script.transports.first).closeCount, 0)
        XCTAssertEqual(recorder.usage.count, 1)
        XCTAssertEqual(recorder.usage.first?.0, .deepgram)
        XCTAssertGreaterThanOrEqual(recorder.usage.first?.1 ?? 0, 100)
    }

    func testRemainderSkipsShownTextEvenWhenTheProviderRevisedIt() {
        XCTAssertEqual(MeetingCloudCaptionText.remainder(of: "hello there general", after: "hello there"), "general")
        XCTAssertEqual(MeetingCloudCaptionText.remainder(of: "Hello, there. General", after: "hello there"), "General")
        XCTAssertEqual(MeetingCloudCaptionText.remainder(of: "short", after: "a much longer shown text"), "")
        XCTAssertEqual(MeetingCloudCaptionText.remainder(of: "今天天气很好", after: "今天"), "天气很好")
    }

    // MARK: - Helpers

    private func startedEngine(
        timing: MeetingCloudCaptionTiming? = nil
    ) async -> (MeetingCloudCaptionEngine, CaptionRecorder, SessionScript) {
        let recorder = CaptionRecorder()
        let script = SessionScript()
        let engine = MeetingCloudCaptionEngine(
            kind: .microphone,
            configuration: self.configuration,
            apiKey: "test-key",
            makeSession: { script.makeSession(configuration: $0, apiKey: $1) },
            recordUsage: { recorder.recordUsage($0, $1) },
            timing: timing ?? self.testTiming
        )
        await recorder.configure(engine)
        await engine.start()
        return (engine, recorder, script)
    }

    /// Offers 100 ms of 16 kHz audio and waits until the current connection received it.
    private func speak(to engine: MeetingCloudCaptionEngine, script: SessionScript) async {
        let before = script.transports.last?.sentAudioBytes ?? 0
        engine.offer(Self.sample(seconds: 0.1))
        try? await self.waitUntil { (script.transports.last?.sentAudioBytes ?? 0) >= before + 3_200 }
    }

    private static func sample(seconds: Double) -> MeetingLiveSampleCopy.Sample {
        // swiftlint:disable:next force_unwrapping
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let frames = AVAudioFrameCount(seconds * 16_000)
        // swiftlint:disable:next force_unwrapping
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        buffer.floatChannelData?[0].update(repeating: 0.1, count: Int(frames))
        return MeetingLiveSampleCopy.Sample(
            buffer: buffer,
            pts: CMTime(seconds: 1, preferredTimescale: 16_000),
            duration: CMTime(value: CMTimeValue(frames), timescale: 16_000)
        )
    }

    private func waitUntil(timeout: Duration = .seconds(3), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { throw ConditionTimeout(timeout: timeout) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private struct ConditionTimeout: Error, CustomStringConvertible {
    let timeout: Duration
    var description: String { "The condition did not hold within \(self.timeout)." }
}

final class MeetingLiveCaptionSourceTests: XCTestCase {
    func testNoProviderKeepsCaptionsOnThisMac() {
        XCTAssertEqual(self.source(provider: nil, key: "key", language: "auto"), .onDevice)
    }

    func testAProviderWithoutAKeyNamesTheMissingKey() {
        XCTAssertEqual(
            self.source(provider: .soniox, key: "", language: "auto"),
            .unavailable(reason: "Live captions need a Soniox API key. Add it in Voice Engine > Live cloud.")
        )
    }

    func testAutomaticLanguageSendsNoLanguageButKeepsTheHints() {
        let source = self.source(provider: .soniox, key: "key", language: "auto")
        XCTAssertEqual(source, .cloud(.init(provider: .soniox, modelID: "model-soniox", languageCode: nil, languageHints: ["pt", "en"]), apiKey: "key"))
        XCTAssertEqual(source.cloudProvider, .soniox)
    }

    func testALanguageTheProviderDoesNotListIsDetectedAutomatically() {
        XCTAssertEqual(
            self.source(provider: .deepgram, key: "key", language: "ko"),
            .cloud(.init(provider: .deepgram, modelID: "model-deepgram", languageCode: nil, languageHints: ["pt", "en"]), apiKey: "key")
        )
        XCTAssertEqual(
            self.source(provider: .deepgram, key: "key", language: "pt"),
            .cloud(.init(provider: .deepgram, modelID: "model-deepgram", languageCode: "pt", languageHints: ["pt", "en"]), apiKey: "key")
        )
    }

    private func source(provider: LiveTranscriptionProviderID?, key: String, language: String) -> MeetingLiveCaptionSource {
        SettingsStore.meetingLiveCaptionSource(
            provider: provider,
            apiKey: { _ in key },
            modelID: { "model-\($0.rawValue)" },
            languageCode: language,
            languageHints: ["pt", "en"]
        )
    }
}

/// Stands in for a caption engine so a test can drive the coordinator's handlers.
private actor FakeCaptionEngine: MeetingLiveCaptionEngine {
    private(set) var onReady: MeetingLiveCaptionHandlers.Ready?
    private(set) var onDegraded: MeetingLiveCaptionHandlers.Degraded?
    private(set) var started = false
    private(set) var stopped = false

    func configure(
        onPartial: @escaping MeetingLiveCaptionHandlers.Partial,
        onUtterance: @escaping MeetingLiveCaptionHandlers.Utterance,
        onDegraded: @escaping MeetingLiveCaptionHandlers.Degraded,
        onReady: @escaping MeetingLiveCaptionHandlers.Ready
    ) {
        self.onReady = onReady
        self.onDegraded = onDegraded
    }

    func start() { self.started = true }
    func stop() { self.stopped = true }
    nonisolated func offer(_ sample: MeetingLiveSampleCopy.Sample) {}
}

final class MeetingLiveCaptionCoordinatorTests: XCTestCase {
    private final class Engines: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [MeetingAudioTrackKind: FakeCaptionEngine] = [:]
        private var storedSnapshot = MeetingLiveTranscriptSnapshot.empty
        func add(_ engine: FakeCaptionEngine, for kind: MeetingAudioTrackKind) { self.lock.withLock { self.stored[kind] = engine } }
        func engine(_ kind: MeetingAudioTrackKind) -> FakeCaptionEngine? { self.lock.withLock { self.stored[kind] } }
        func update(_ snapshot: MeetingLiveTranscriptSnapshot) { self.lock.withLock { self.storedSnapshot = snapshot } }
        var availability: MeetingLiveAvailability { self.lock.withLock { self.storedSnapshot.availability } }
    }

    func testCloudSourceStartsAnEnginePerTrackAndFollowsTheirAvailability() async throws {
        let engines = Engines()
        let coordinator = MeetingLiveTranscriptionCoordinator(
            onUpdate: { engines.update($0) },
            makeCloudEngine: { kind, _, _ in
                let engine = FakeCaptionEngine()
                engines.add(engine, for: kind)
                return engine
            }
        )
        let configuration = LiveTranscriptionConfiguration(provider: .soniox, modelID: "stt-rt-v5", languageCode: nil, languageHints: [])
        coordinator.start(mode: .onlineCall, languageCode: "pt", source: .cloud(configuration, apiKey: "key"))
        XCTAssertEqual(engines.availability, .unavailable(reason: "Connecting live captions to Soniox…"))

        var microphone: FakeCaptionEngine?
        var application: FakeCaptionEngine?
        for _ in 0 ..< 300 where microphone == nil || application == nil {
            if let engine = engines.engine(.microphone), await engine.started { microphone = engine }
            if let engine = engines.engine(.applicationAudio), await engine.started { application = engine }
            try await Task.sleep(for: .milliseconds(10))
        }
        let mic = try XCTUnwrap(microphone)
        let app = try XCTUnwrap(application)

        await mic.onReady?(.microphone)
        XCTAssertEqual(engines.availability, .available)
        await app.onDegraded?(.applicationAudio, "lost")
        XCTAssertEqual(engines.availability, .degraded(reason: "lost"))
        await app.onReady?(.applicationAudio)
        XCTAssertEqual(engines.availability, .available)

        await coordinator.stop()
        let micStopped = await mic.stopped
        let appStopped = await app.stopped
        XCTAssertTrue(micStopped && appStopped)
    }

    func testAnUnavailableSourceShowsItsReasonAndStartsNoEngine() {
        let engines = Engines()
        let coordinator = MeetingLiveTranscriptionCoordinator(
            onUpdate: { engines.update($0) },
            makeCloudEngine: { _, _, _ in
                XCTFail("No engine expected")
                return FakeCaptionEngine()
            }
        )
        coordinator.start(mode: .inRoom, source: .unavailable(reason: "key missing"))
        XCTAssertEqual(engines.availability, .unavailable(reason: "key missing"))
    }

    func testADegradedTrackOutranksAReadyOne() {
        XCTAssertNil(MeetingLiveTranscriptionCoordinator.combinedAvailability([:]))
        XCTAssertEqual(MeetingLiveTranscriptionCoordinator.combinedAvailability([.microphone: .available]), .available)
        XCTAssertEqual(
            MeetingLiveTranscriptionCoordinator.combinedAvailability([.microphone: .available, .applicationAudio: .degraded(reason: "x")]),
            .degraded(reason: "x")
        )
    }
}

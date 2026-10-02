import AVFoundation
import CoreMedia
import Foundation

/// Turn boundaries and connection upkeep for streamed captions. Providers finalize text at very
/// different sizes (a word, a phrase, 30 s of audio), so turns are cut on this side, at pauses in
/// the text, the same way the on-device engine closes a turn whose decoder has gone quiet.
nonisolated struct MeetingCloudCaptionTiming: Sendable {
    /// A turn whose text is all final closes after this long without a change.
    var quietSeconds: Double = 1.2
    /// A turn that still holds provisional text closes after this long without a change.
    var stallSeconds: Double = 2.5
    /// A turn open this long closes at the provider's last final text; the provisional rest stays open.
    var longTurnSeconds: Double = 20
    /// A turn open this long closes whole, final or not.
    var maximumTurnSeconds: Double = 30
    /// How far before the arrival of its first text a turn starts: provider latency plus the first word.
    var turnLookbackSeconds: Double = 1.0
    /// A track that delivers no audio for this long streams silence, so providers that close idle
    /// connections keep this one.
    var idleSilenceSeconds: Double = 1.0
    /// The connection is replaced at the first pause after this long, which bounds the audio the
    /// session keeps for replaying after a drop.
    var rotationSeconds: Double = 600
    /// The connection is replaced after this long even without a pause.
    var forcedRotationSeconds: Double = 1800
    /// Waits before a new connection after one failed; the last value repeats.
    var retryDelaysSeconds: [Double] = [1, 2, 5, 10, 30]
    var pollSeconds: Double = 0.02

    static let standard = MeetingCloudCaptionTiming()
}

nonisolated enum MeetingCloudCaptionText {
    /// The part of a session transcript after the text already shown as finished turns.
    static func remainder(of text: String, after emitted: String) -> String {
        if text.hasPrefix(emitted) { return Self.trimmed(text.dropFirst(emitted.count)) }
        // JUDGMENT: the provider revised text that is already shown in a finished turn, which cannot change.
        // Skipping as many words as were shown survives punctuation and case revisions; text written without
        // spaces between words falls back to characters.
        let emittedWords = emitted.split(whereSeparator: \.isWhitespace)
        if emittedWords.count > 1 {
            return text.split(whereSeparator: \.isWhitespace).dropFirst(emittedWords.count).joined(separator: " ")
        }
        return Self.trimmed(text.dropFirst(min(emitted.count, text.count)))
    }

    private static func trimmed(_ text: Substring) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What the captions card says when a provider session ends early.
    static func failureMessage(_ error: LiveTranscriptionError, providerName: String) -> String {
        switch error {
        case .missingAPIKey:
            "Live captions need \(ProviderKeyMessage.indefiniteArticle(for: providerName)) \(providerName) API key. Add it in AI Providers. Recording continues."
        case .authentication:
            "\(providerName) rejected the API key, so live captions stopped. Recording continues."
        case .quotaExhausted:
            "\(providerName) has no remaining credits, so live captions stopped. Recording continues."
        case .unsupportedLanguage:
            "\(providerName) can't caption this language with the selected model, so live captions stopped. Recording continues."
        case .languageRequired:
            "\(providerName) needs a set language for live captions. Choose a transcript language in meeting settings. Recording continues."
        case .rateLimited:
            "\(providerName) is limiting requests. Live captions will reconnect."
        default:
            "Live captions lost the connection to \(providerName) and are reconnecting."
        }
    }

    /// Failures a new connection would hit again, so captions stop instead of retrying.
    static func stopsCaptions(_ error: LiveTranscriptionError) -> Bool {
        error.isPermanent || error == .missingAPIKey
    }
}

/// Streams one capture track to a Live cloud provider and turns its transcript into caption turns.
///
/// Audio arrives through the nonisolated `offer(_:)` and a polling loop on this actor converts it and
/// sends it on, so the capture path never waits on the network. A session that fails is replaced
/// after a backoff, except for failures a new connection would repeat (a rejected key, no credits, an
/// unsupported language). Nothing here logs or keeps transcript text beyond the open turn.
actor MeetingCloudCaptionEngine: MeetingLiveCaptionEngine {
    typealias SessionFactory = @Sendable (LiveTranscriptionConfiguration, String) -> LiveTranscriptionSession
    typealias UsageRecorder = @Sendable (LiveTranscriptionProviderID, Int) -> Void

    nonisolated private struct Turn {
        let id: UUID
        let startPTS: CMTime
        let startUptime: Double
        var text: String
        var changedUptime: Double
        var endPTS: CMTime
    }

    nonisolated let queue = MeetingLiveBoundedQueue<MeetingLiveSampleCopy.Sample>(capacity: 512)
    private let kind: MeetingAudioTrackKind
    private let configuration: LiveTranscriptionConfiguration
    private let apiKey: String
    private let makeSession: SessionFactory
    private let recordUsage: UsageRecorder
    private let timing: MeetingCloudCaptionTiming
    private let uptime: @Sendable () -> Double
    private let converter = MeetingLiveAudioConverter()

    private var onPartial: MeetingLiveCaptionHandlers.Partial?
    private var onUtterance: MeetingLiveCaptionHandlers.Utterance?
    private var onDegraded: MeetingLiveCaptionHandlers.Degraded?
    private var onReady: MeetingLiveCaptionHandlers.Ready?
    private var hasStarted = false
    /// Set while `stop()` lets the provider finish; turns still close, nothing reconnects.
    private var isStopping = false
    /// Set while a long connection finishes before its replacement opens.
    private var isRotating = false
    private var isStopped = false
    private var loopTask: Task<Void, Never>?

    private var session: LiveTranscriptionSession?
    private var sessionGeneration = 0
    private var sessionStartUptime: Double = 0
    private var progressTask: Task<Void, Never>?
    private var retryAtUptime: Double?
    private var failuresInARow = 0
    /// Set by a failure a new connection would repeat; no session opens afterwards.
    private var hasGivenUp = false
    private var streamedMilliseconds = 0

    private var lastAudioUptime: Double?
    private var lastFedPTS: CMTime?

    private var latest = LiveTranscriptProgress.empty
    /// The session transcript already shown as finished turns.
    private var emitted = ""
    private var turn: Turn?
    private var lastUtteranceEndPTS: CMTime?

    init(
        kind: MeetingAudioTrackKind,
        configuration: LiveTranscriptionConfiguration,
        apiKey: String,
        makeSession: @escaping SessionFactory = MeetingCloudCaptionEngine.makeProviderSession,
        recordUsage: @escaping UsageRecorder = MeetingCloudCaptionEngine.recordProviderUsage,
        timing: MeetingCloudCaptionTiming = .standard,
        uptime: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.kind = kind
        self.configuration = configuration
        self.apiKey = apiKey
        self.makeSession = makeSession
        self.recordUsage = recordUsage
        self.timing = timing
        self.uptime = uptime
    }

    @Sendable nonisolated static func makeProviderSession(configuration: LiveTranscriptionConfiguration, apiKey: String) -> LiveTranscriptionSession {
        LiveTranscriptionSession(
            adapter: LiveTranscriptionAdapters.make(configuration.provider),
            configuration: configuration,
            apiKey: apiKey,
            makeTransport: { URLSessionWebSocketTransport() },
            // Captions read `progress`; unread partials would otherwise pile up for the whole meeting.
            partialsBuffering: .bufferingNewest(1)
        )
    }

    /// Every caption stream counts as one recording in the provider's usage, like a dictation.
    @Sendable nonisolated static func recordProviderUsage(provider: LiveTranscriptionProviderID, milliseconds: Int) {
        Task { @MainActor in LiveTranscriptionUsageStore.shared.record(provider: provider, milliseconds: milliseconds) }
    }

    private var providerName: String { LiveTranscriptionCatalog.info(for: self.configuration.provider).name }

    func configure(
        onPartial: @escaping MeetingLiveCaptionHandlers.Partial,
        onUtterance: @escaping MeetingLiveCaptionHandlers.Utterance,
        onDegraded: @escaping MeetingLiveCaptionHandlers.Degraded,
        onReady: @escaping MeetingLiveCaptionHandlers.Ready
    ) {
        guard !self.isStopped else { return }
        self.onPartial = onPartial
        self.onUtterance = onUtterance
        self.onDegraded = onDegraded
        self.onReady = onReady
    }

    func start() {
        guard !self.hasStarted, !self.isStopped else { return }
        self.hasStarted = true
        self.openSession()
        self.loopTask = Task { [weak self] in await self?.runLoop() }
    }

    /// Terminal. The capture has stopped by now, so the audio still queued is sent and the provider
    /// gets its finish messages; its last words close the open turn before the connection closes.
    /// `LiveTranscriptionSession.finish` gives up after its own deadline.
    func stop() async {
        guard !self.isStopping, !self.isStopped else { return }
        self.isStopping = true
        self.loopTask?.cancel()
        await self.loopTask?.value
        self.loopTask = nil
        if let session = self.session {
            for sample in self.queue.drainAll() {
                await self.feed(sample)
            }
            _ = try? await session.finish()
            // The progress stream ends with the session; its last values are handled before the turn closes.
            await self.progressTask?.value
            self.session = nil
            self.streamedMilliseconds += await session.streamedMilliseconds
        }
        self.progressTask?.cancel()
        self.progressTask = nil
        if let turn = self.turn { self.closeTurn(turn, text: turn.text, shownThrough: self.latest.displayText) }
        self.isStopped = true
        self.onPartial = nil
        self.onUtterance = nil
        self.onDegraded = nil
        self.onReady = nil
        if self.streamedMilliseconds > 0 {
            self.recordUsage(self.configuration.provider, self.streamedMilliseconds)
            self.streamedMilliseconds = 0
        }
    }

    /// Fast, synchronous hand-off from the capture tee. A saturated queue drops the oldest audio,
    /// which a provider hears as a short gap.
    nonisolated func offer(_ sample: MeetingLiveSampleCopy.Sample) {
        _ = self.queue.enqueue(sample)
    }

    // MARK: - Sessions

    private func openSession() {
        guard !self.isStopping, !self.isStopped, !self.hasGivenUp else { return }
        self.sessionGeneration += 1
        let generation = self.sessionGeneration
        let session = self.makeSession(self.configuration, self.apiKey)
        self.session = session
        self.sessionStartUptime = self.uptime()
        self.lastAudioUptime = self.lastAudioUptime ?? self.sessionStartUptime
        self.retryAtUptime = nil
        self.latest = .empty
        self.emitted = ""
        DebugLogger.shared.info(
            "Meeting live captions: opening \(self.configuration.provider.rawValue) model=\(self.configuration.modelID) track=\(self.kind.rawValue)",
            source: "MeetingLive"
        )
        self.progressTask = Task { [weak self] in
            // Audio appended while the connection opens is held and sent once it is ready.
            let connected = (try? await session.start()) != nil
            if connected { await self?.sessionConnected(generation: generation) }
            for await progress in session.progress {
                await self?.handle(progress, generation: generation)
            }
            await self?.sessionEnded(generation: generation)
        }
    }

    private func sessionConnected(generation: Int) {
        guard generation == self.sessionGeneration, !self.isStopping, !self.isStopped else { return }
        self.onReady?(self.kind)
    }

    private func sessionEnded(generation: Int) async {
        // While stopping, `stop()` itself closes the session and the last turn.
        guard generation == self.sessionGeneration, !self.isStopping, !self.isRotating, !self.isStopped,
              let session = self.session
        else { return }
        let failure = await session.failureReason
        self.streamedMilliseconds += await session.streamedMilliseconds
        guard generation == self.sessionGeneration, !self.isStopping, !self.isStopped else { return }
        self.session = nil
        self.progressTask = nil
        if let turn = self.turn { self.closeTurn(turn, text: turn.text, shownThrough: self.latest.displayText) }
        guard let failure else {
            // A provider that ended the stream on its own (a session length limit) is reconnected at once.
            self.retryAtUptime = self.uptime()
            return
        }
        DebugLogger.shared.warning(
            "Meeting live captions: \(self.configuration.provider.rawValue) track=\(self.kind.rawValue) ended kind=\(failure.kind)",
            source: "MeetingLive"
        )
        self.onDegraded?(self.kind, MeetingCloudCaptionText.failureMessage(failure, providerName: self.providerName))
        if MeetingCloudCaptionText.stopsCaptions(failure) {
            self.hasGivenUp = true
            return
        }
        let delays = self.timing.retryDelaysSeconds
        let delay = delays.isEmpty ? 0 : delays[min(self.failuresInARow, delays.count - 1)]
        self.failuresInARow += 1
        self.retryAtUptime = self.uptime() + delay
    }

    /// Replaces a long-running connection with a new one. The old one finishes first, so speech that
    /// began just before the switch still reaches the transcript; audio captured meanwhile waits in
    /// the queue for the new connection.
    private func rotateSession() async {
        guard let session = self.session else { return }
        DebugLogger.shared.info(
            "Meeting live captions: replacing \(self.configuration.provider.rawValue) connection track=\(self.kind.rawValue)",
            source: "MeetingLive"
        )
        self.isRotating = true
        _ = try? await session.finish()
        await self.progressTask?.value
        self.isRotating = false
        if let turn = self.turn { self.closeTurn(turn, text: turn.text, shownThrough: self.latest.displayText) }
        self.session = nil
        self.progressTask = nil
        self.streamedMilliseconds += await session.streamedMilliseconds
        guard !self.isStopping, !self.isStopped else { return }
        self.openSession()
    }

    // MARK: - Audio

    private func runLoop() async {
        while !Task.isCancelled, !self.isStopping, !self.isStopped {
            let samples = self.queue.drainAll()
            let now = self.uptime()
            if samples.isEmpty {
                if let last = self.lastAudioUptime, now - last >= self.timing.idleSilenceSeconds {
                    // Real time passed without audio; stream the same length of silence, at most two seconds.
                    let seconds = min(now - last, 2)
                    self.lastAudioUptime = now
                    await self.session?.append([Float](repeating: 0, count: Int(seconds * 16_000)))
                }
            } else {
                self.lastAudioUptime = now
                for sample in samples where !Task.isCancelled {
                    await self.feed(sample)
                }
            }
            self.evaluateTurn()
            await self.maintainSession()
            if samples.isEmpty {
                try? await Task.sleep(for: .seconds(self.timing.pollSeconds))
            }
        }
    }

    private func feed(_ sample: MeetingLiveSampleCopy.Sample) async {
        // Audio that arrives between a failed connection and the next one is not captioned.
        guard let session = self.session else { return }
        let samples = self.converter.samples(sample.buffer)
        guard !samples.isEmpty else { return }
        self.lastFedPTS = sample.pts + sample.duration
        await session.append(samples)
    }

    private func maintainSession() async {
        guard !self.isStopping, !self.isStopped else { return }
        if self.session == nil {
            if let retryAt = self.retryAtUptime, self.uptime() >= retryAt { self.openSession() }
            return
        }
        let age = self.uptime() - self.sessionStartUptime
        let isPaused = self.turn == nil && MeetingCloudCaptionText.remainder(of: self.latest.displayText, after: self.emitted).isEmpty
        if (age >= self.timing.rotationSeconds && isPaused) || age >= self.timing.forcedRotationSeconds {
            await self.rotateSession()
        }
    }

    // MARK: - Turns

    private func handle(_ progress: LiveTranscriptProgress, generation: Int) {
        guard generation == self.sessionGeneration, !self.isStopped else { return }
        self.latest = progress
        if !progress.displayText.isEmpty { self.failuresInARow = 0 }
        self.updateTurn(MeetingCloudCaptionText.remainder(of: progress.displayText, after: self.emitted))
    }

    private func updateTurn(_ text: String) {
        let now = self.uptime()
        guard !text.isEmpty else {
            // The provider withdrew provisional text, for example after a reconnect.
            if let turn = self.turn {
                self.turn = nil
                self.onPartial?(self.kind, turn.id, "", turn.startPTS, turn.endPTS)
            }
            return
        }
        guard let feed = self.lastFedPTS else { return }
        let turn: Turn
        if var open = self.turn {
            guard open.text != text else { return }
            open.text = text
            open.changedUptime = now
            open.endPTS = feed
            turn = open
        } else {
            var start = feed - CMTime(seconds: self.timing.turnLookbackSeconds, preferredTimescale: 1000)
            // The lookback must not reach behind the turn that just closed, or turns would overlap.
            if let previous = self.lastUtteranceEndPTS, start < previous { start = previous }
            turn = Turn(id: UUID(), startPTS: start, startUptime: now, text: text, changedUptime: now, endPTS: feed)
        }
        self.turn = turn
        self.onPartial?(self.kind, turn.id, turn.text, turn.startPTS, turn.endPTS)
    }

    private func evaluateTurn() {
        guard let turn = self.turn, !self.isStopped else { return }
        let now = self.uptime()
        let quiet = now - turn.changedUptime
        let open = now - turn.startUptime
        let isSettled = self.latest.displayText == self.latest.stableText
        if (isSettled && quiet >= self.timing.quietSeconds) || quiet >= self.timing.stallSeconds || open >= self.timing.maximumTurnSeconds {
            self.closeTurn(turn, text: turn.text, shownThrough: self.latest.displayText)
        } else if open >= self.timing.longTurnSeconds {
            let finished = MeetingCloudCaptionText.remainder(of: self.latest.stableText, after: self.emitted)
            guard !finished.isEmpty else { return }
            self.closeTurn(turn, text: finished, shownThrough: self.latest.stableText)
            // The provisional rest opens the next turn at once.
            self.updateTurn(MeetingCloudCaptionText.remainder(of: self.latest.displayText, after: self.emitted))
        }
    }

    private func closeTurn(_ turn: Turn, text: String, shownThrough transcript: String) {
        self.turn = nil
        self.emitted = transcript
        let end = max(turn.endPTS, turn.startPTS)
        self.lastUtteranceEndPTS = end
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            self.onPartial?(self.kind, turn.id, "", turn.startPTS, end)
            return
        }
        self.onUtterance?(self.kind, turn.id, trimmed, turn.startPTS, end)
    }
}

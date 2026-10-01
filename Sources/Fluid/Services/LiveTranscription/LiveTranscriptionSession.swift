import Foundation

/// One streaming dictation: owns the socket, the audio sent so far (for replay) and the
/// transcript. Runs off the main actor; ASRService talks to it through `LiveCloudTranscriptionProvider`.
actor LiveTranscriptionSession {
    typealias TransportFactory = @Sendable () -> any LiveTranscriptionTransport

    private static let minimumChunkBytes = 50 * LivePCM16.bytesPerMillisecond
    private static let maximumChunkBytes = 1000 * LivePCM16.bytesPerMillisecond

    private var adapter: any LiveTranscriptionAdapter
    /// The adapter as given, restored at every connection: adapter state describes one connection.
    private let initialAdapter: any LiveTranscriptionAdapter
    private var configuration: LiveTranscriptionConfiguration
    private let apiKey: String
    private let makeTransport: TransportFactory
    private let finishTimeout: Duration

    private var transport: (any LiveTranscriptionTransport)?
    private var connection = 0
    /// The connection that already received the finish messages, so they are sent once per connection.
    private var finishedConnection = 0
    private var assembler = LiveTranscriptAssembler()
    private var audio = Data()
    private var sentOffset = 0
    private var isReady = false
    private var isFinishing = false
    private var didFinish = false
    private var failure: LiveTranscriptionError?
    private var reconnectsLeft = 1
    private var finishWaiter: CheckedContinuation<Void, Never>?
    private var lastPublished = ""
    private let partialsContinuation: AsyncStream<String>.Continuation
    nonisolated let partials: AsyncStream<String>

    init(
        adapter: any LiveTranscriptionAdapter,
        configuration: LiveTranscriptionConfiguration,
        apiKey: String,
        makeTransport: @escaping TransportFactory,
        finishTimeout: Duration = .seconds(5)
    ) {
        self.adapter = adapter
        self.initialAdapter = adapter
        self.configuration = configuration
        self.apiKey = apiKey
        self.makeTransport = makeTransport
        self.finishTimeout = finishTimeout
        // Unbounded so no intermediate text is lost; ASRService consumes each update at once.
        let stream = AsyncStream.makeStream(of: String.self, bufferingPolicy: .unbounded)
        self.partials = stream.stream
        self.partialsContinuation = stream.continuation
    }

    var streamedMilliseconds: Int { self.audio.count / LivePCM16.bytesPerMillisecond }

    func start() async throws {
        try await self.connect(replayingFrom: 0)
    }

    func append(_ samples: [Float]) async {
        guard !samples.isEmpty, !self.isFinishing else { return }
        self.audio.append(LivePCM16.encode(samples))
        await self.flush(final: false)
    }

    func reconfigure(languageCode: String?) async {
        guard !self.isFinishing, self.failure == nil, self.configuration.languageCode != languageCode else { return }
        self.configuration = self.configuration.with(languageCode: languageCode)
        self.transport?.close()
        let resume = self.assembler.beginGeneration()
        self.publish()
        do { try await self.connect(replayingFrom: resume) } catch { self.fail(Self.mapped(error, adapter: self.adapter)) }
    }

    func finish() async throws -> String {
        self.isFinishing = true
        let silence = self.adapter.trailingSilenceMilliseconds * LivePCM16.bytesPerMillisecond
        if silence > 0 { self.audio.append(Data(count: silence)) }
        let tail = self.audio.count - self.sentOffset
        if tail > 0, tail < Self.minimumChunkBytes { self.audio.append(Data(count: Self.minimumChunkBytes - tail)) }
        if self.failure == nil, self.isReady {
            await self.flush(final: true)
            await self.sendFinishMessages()
        }
        if self.failure == nil, !self.didFinish {
            let timeout = self.finishTimeout
            let timer = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.timeOut()
            }
            await withCheckedContinuation { self.finishWaiter = $0 }
            timer.cancel()
        }
        self.transport?.close()
        self.partialsContinuation.finish()
        if let failure { throw failure }
        return self.assembler.finalText
    }

    /// Retry path: streams a saved recording through a fresh connection at the provider's
    /// maximum accepted speed.
    func replay(_ samples: [Float]) async throws -> String {
        try await self.start()
        let chunk = 16_000 / 10
        let speed = self.adapter.maximumReplaySpeed
        var index = 0
        while index < samples.count {
            let end = min(index + chunk, samples.count)
            await self.append(Array(samples[index ..< end]))
            index = end
            if let speed { try await Task.sleep(for: .milliseconds(Int(100 / speed))) }
        }
        return try await self.finish()
    }

    func cancel() async {
        self.isFinishing = true
        self.transport?.close()
        self.partialsContinuation.finish()
        self.resumeWaiter()
    }

    // MARK: - Connection

    private func connect(replayingFrom milliseconds: Int) async throws {
        self.connection += 1
        let connection = self.connection
        // JUDGMENT: adapters number segments and track the last one per connection; carried into a new
        // connection, a Soniox continuation would extend a segment of the previous generation.
        self.adapter = self.initialAdapter
        self.isReady = false
        self.sentOffset = min(self.audio.count, max(0, milliseconds) * LivePCM16.bytesPerMillisecond)
        let transport = self.makeTransport()
        self.transport = transport
        do {
            try await transport.open(self.adapter.connectionRequest(apiKey: self.apiKey, configuration: self.configuration))
            for message in try self.adapter.openingMessages(apiKey: self.apiKey, configuration: self.configuration) {
                try await transport.send(message)
            }
        } catch {
            throw Self.mapped(error, adapter: self.adapter)
        }
        Task { [weak self] in await self?.receiveLoop(transport, connection: connection) }
        if !self.adapter.waitsForReady {
            self.isReady = true
            await self.flush(final: self.isFinishing)
        }
    }

    private func receiveLoop(_ transport: any LiveTranscriptionTransport, connection: Int) async {
        while true {
            do {
                let message = try await transport.receive()
                guard connection == self.connection else { return }
                await self.handle(message)
            } catch {
                guard connection == self.connection else { return }
                await self.connectionEnded(error)
                return
            }
        }
    }

    private func handle(_ message: LiveTransportMessage) async {
        for update in self.adapter.parse(message) {
            switch update {
            case .reply(let messages):
                for reply in messages {
                    try? await self.transport?.send(reply)
                }
            case .ready:
                self.isReady = true
                await self.flush(final: self.isFinishing)
                if self.isFinishing { await self.sendFinishMessages() }
            case .finished:
                self.didFinish = true
                self.resumeWaiter()
            case .failure(let error):
                self.fail(error)
            case .segment, .pending, .replaceAll:
                self.assembler.apply(update)
            }
        }
        // JUDGMENT: publish once per server message, not per update. A message that finalizes text
        // usually carries the segment and the cleared pending tail together; publishing in between
        // would flash the old tail after the new segment ("hello hel").
        self.publish()
    }

    private func connectionEnded(_ error: Error) async {
        if self.didFinish { return }
        if self.isFinishing, let closed = error as? LiveTransportClosed, closed.closeCode == 1000 {
            // Providers that close cleanly after the finish messages have delivered everything.
            self.didFinish = true
            self.resumeWaiter()
            return
        }
        guard self.failure == nil, self.reconnectsLeft > 0 else {
            self.fail(self.failure ?? Self.mapped(error, adapter: self.adapter))
            return
        }
        self.reconnectsLeft -= 1
        let resume = self.assembler.beginGeneration()
        self.publish()
        do {
            try await self.connect(replayingFrom: resume)
            // `finish()` may have run while the new connection was opening; it then left the tail
            // and the finish messages to this branch.
            if self.isFinishing, self.isReady {
                await self.flush(final: true)
                await self.sendFinishMessages()
            }
        } catch {
            self.fail(.connectionLost)
        }
    }

    private func flush(final: Bool) async {
        guard self.isReady, let transport = self.transport else { return }
        while self.audio.count - self.sentOffset >= (final ? 1 : Self.minimumChunkBytes) {
            let remaining = self.audio.count - self.sentOffset
            var length = min(remaining, Self.maximumChunkBytes)
            // JUDGMENT: audio held back before the provider's greeting, or replayed while finishing, can
            // leave a final remainder shorter than 50 ms after a full chunk; AssemblyAI closes the session
            // on that (error 3007). Shorten this chunk so the last one is at least the minimum.
            if final, remaining > length, remaining - length < Self.minimumChunkBytes { length = remaining - Self.minimumChunkBytes }
            let chunk = self.audio.subdata(in: self.sentOffset ..< self.sentOffset + length)
            do {
                try await transport.send(self.adapter.audioMessage(chunk))
                self.sentOffset += length
            } catch {
                return
            }
        }
    }

    // JUDGMENT: `finish()` and a reconnect that completes during it can both reach the finish step for
    // the same connection. Sending the finish messages twice makes some providers transcribe the tail
    // twice, so they go out once per connection.
    private func sendFinishMessages() async {
        guard let transport = self.transport, self.finishedConnection != self.connection else { return }
        self.finishedConnection = self.connection
        for message in self.adapter.finishMessages() {
            try? await transport.send(message)
        }
    }

    private func publish() {
        let text = self.assembler.displayText
        guard text != self.lastPublished else { return }
        self.lastPublished = text
        self.partialsContinuation.yield(text)
    }

    private func fail(_ error: LiveTranscriptionError) {
        if self.failure == nil { self.failure = error }
        self.transport?.close()
        self.resumeWaiter()
    }

    private func timeOut() {
        guard !self.didFinish, self.failure == nil else { return }
        self.fail(.finalTimeout)
    }

    private func resumeWaiter() {
        self.finishWaiter?.resume()
        self.finishWaiter = nil
    }

    private static func mapped(_ error: Error, adapter: any LiveTranscriptionAdapter) -> LiveTranscriptionError {
        if let error = error as? LiveTranscriptionError { return error }
        if let closed = error as? LiveTransportClosed {
            if let status = closed.upgradeStatus, status >= 400 { return LiveHTTPStatus.failure(for: status) }
            return adapter.failure(closeCode: closed.closeCode, reason: closed.reason)
        }
        return .connectionFailed
    }
}

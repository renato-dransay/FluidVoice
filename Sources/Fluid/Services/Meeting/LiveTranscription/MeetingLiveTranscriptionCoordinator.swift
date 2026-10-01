import AVFoundation
import CoreMedia
import Foundation

/// Owns the two live-transcription engines for one meeting recording and publishes a snapshot for
/// the UI. The engines run the on-device model or stream to a Live cloud provider, per the
/// recording's `MeetingLiveCaptionSource`. Entirely additive to the recording path:
/// `offer(kind:sampleBuffer:)` is the only entry point invoked from the capture tee, and it never
/// blocks or throws into the capture callback.
///
/// Not `@MainActor` on purpose — `offer` must be callable synchronously from the SCStream callback
/// thread. `onUpdate` is responsible for hopping to the main actor if the caller needs that.
final nonisolated class MeetingLiveTranscriptionCoordinator: @unchecked Sendable {
    typealias CloudEngineFactory = @Sendable (MeetingAudioTrackKind, LiveTranscriptionConfiguration, String) -> any MeetingLiveCaptionEngine

    /// Two `StreamingEouAsrManager` instances measured at ~470MB RSS each. Below this, skip live
    /// entirely rather than risk contending with the recording or the later batch model.
    static let minimumPhysicalMemoryBytes: UInt64 = 8 * 1024 * 1024 * 1024
    static let echoWindowSeconds: TimeInterval = 20

    static func isMemorySufficient(physicalMemory: UInt64) -> Bool {
        physicalMemory >= self.minimumPhysicalMemoryBytes
    }

    private let stateLock = NSLock()
    private let diagnosticsEnabled: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.environment["FLUIDVOICE_MEETING_LIVE_DIAGNOSTICS"] == "1"
        #else
        false
        #endif
    }()

    private func diag(_ message: @autoclosure () -> String) {
        guard self.diagnosticsEnabled else { return }
        DebugLogger.shared.info(message(), source: "MeetingLive")
    }

    private var snapshot: MeetingLiveTranscriptSnapshot = .empty
    private var recentThemUtterances: [MeetingLiveUtterance] = []
    private var offerCounts: [MeetingAudioTrackKind: Int] = [:]
    /// nil (fail-safe) keeps the echo filter ON; guarded by `stateLock` on both sides.
    private var microphoneCaptureMethod: MeetingAudioTrackCaptureMethod?
    private let originBox = MeetingLiveOriginBox()
    private let onUpdate: @Sendable (MeetingLiveTranscriptSnapshot) -> Void
    private let makeCloudEngine: CloudEngineFactory

    private var microphoneEngine: (any MeetingLiveCaptionEngine)?
    private var applicationEngine: (any MeetingLiveCaptionEngine)?
    /// Each track's own state; the snapshot shows their combination. Guarded by `stateLock`.
    private var trackAvailability: [MeetingAudioTrackKind: MeetingLiveAvailability] = [:]
    /// Set while a Live cloud provider transcribes this recording. Guarded by `stateLock`.
    private var cloudConfiguration: LiveTranscriptionConfiguration?
    /// Every finished provider turn, before echo suppression, for the completed transcript.
    /// Guarded by `stateLock`.
    private var cloudTurns: [MeetingLiveCloudTranscript.Turn] = []

    init(
        onUpdate: @escaping @Sendable (MeetingLiveTranscriptSnapshot) -> Void,
        makeCloudEngine: @escaping CloudEngineFactory = { kind, configuration, apiKey in
            MeetingCloudCaptionEngine(kind: kind, configuration: configuration, apiKey: apiKey)
        }
    ) {
        self.onUpdate = onUpdate
        self.makeCloudEngine = makeCloudEngine
    }

    /// Clears any in-progress microphone partial at a capture-side splice, so it can't straddle eras.
    func resetMicrophoneUtterance() {
        self.publish { $0.settingPartial(nil, for: .you) }
    }

    func setMicrophoneCaptureMethod(_ method: MeetingAudioTrackCaptureMethod?) {
        self.stateLock.withLock { self.microphoneCaptureMethod = method }
        self.diag(
            "[live/ECHO] setter-armed captureMethod=\(method.map(String.init(describing:)) ?? "nil")"
        )
    }

    func start(mode: MeetingCaptureMode, languageCode: String = "en", source: MeetingLiveCaptionSource = .onDevice) {
        switch source {
        case .unavailable(let reason):
            self.publish { $0.settingAvailability(.unavailable(reason: reason)) }
        case let .cloud(configuration, apiKey):
            let name = LiveTranscriptionCatalog.info(for: configuration.provider).name
            self.stateLock.withLock { self.cloudConfiguration = configuration }
            self.diag("[live] streaming captions to \(configuration.provider.rawValue) mode=\(mode)")
            self.launchEngines(mode: mode) { kind in self.makeCloudEngine(kind, configuration, apiKey) }
            self.publish { $0.settingAvailability(.unavailable(reason: "Connecting live captions to \(name)…")) }
        case .onDevice:
            self.startOnDevice(mode: mode, languageCode: languageCode)
        }
    }

    private func startOnDevice(mode: MeetingCaptureMode, languageCode: String) {
        guard languageCode == "en" || languageCode == MeetingCloudLanguage.automatic else {
            self.publish {
                $0.settingAvailability(.unavailable(
                    reason: "Local live captions support English only. Your completed transcript uses the selected cloud language. To caption other languages, choose a live provider under Live captions in meeting settings."
                ))
            }
            return
        }
        #if arch(arm64)
        guard Self.isMemorySufficient(physicalMemory: ProcessInfo.processInfo.physicalMemory) else {
            self.diag(
                "Live meeting transcription skipped: below memory threshold."
            )
            self.publish { $0.settingAvailability(.unavailable(reason: "Not enough memory available for live captions.")) }
            return
        }

        self.diag(
            "[live] starting engines mode=\(mode) physicalMemory=\(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)GB"
        )
        self.launchEngines(mode: mode) { kind in MeetingLiveTrackEngine(kind: kind) }
        self.publish { $0.settingAvailability(.unavailable(reason: "Live captions are loading…")) }
        #else
        self.publish { $0.settingAvailability(.unavailable(reason: "Live captions require Apple Silicon.")) }
        #endif
    }

    /// The microphone always has an engine; application audio only in an online call.
    private func launchEngines(mode: MeetingCaptureMode, make: (MeetingAudioTrackKind) -> any MeetingLiveCaptionEngine) {
        let microphone = make(.microphone)
        self.stateLock.withLock { self.microphoneEngine = microphone }
        self.launch(microphone)

        if mode == .onlineCall {
            let application = make(.applicationAudio)
            self.stateLock.withLock { self.applicationEngine = application }
            self.launch(application)
        }
    }

    /// The capture-tee entry point. Copies the sample immediately, then hands it to the matching
    /// track's bounded queue — never retains the `CMSampleBuffer` beyond this call.
    func offer(kind: MeetingAudioTrackKind, sampleBuffer: CMSampleBuffer) {
        guard let sample = MeetingLiveSampleCopy.copy(sampleBuffer) else {
            self.diag("[live/tee] sample copy FAILED kind=\(kind)")
            return
        }
        self.originBox.establish(sample.pts)
        let engine = self.stateLock.withLock { () -> (any MeetingLiveCaptionEngine)? in
            let count = (self.offerCounts[kind] ?? 0) + 1
            self.offerCounts[kind] = count
            if count == 1 {
                self.diag(
                    "[live/tee] first sample kind=\(kind) pts=\(String(format: "%.3f", sample.pts.seconds)) sr=\(sample.buffer.format.sampleRate) ch=\(sample.buffer.format.channelCount)"
                )
            }
            let engine = kind == .microphone ? self.microphoneEngine : self.applicationEngine
            if engine == nil, count == 1 {
                self.diag("[live/tee] no engine for kind=\(kind) — samples discarded")
            }
            return engine
        }
        engine?.offer(sample)
    }

    /// Must complete before the batch pipeline calls `ensureAsrReady()`, so both engines' CoreML
    /// models are released before the offline model loads. Cloud engines close their connections.
    func stop() async {
        let (microphone, application) = self.stateLock.withLock { () -> ((any MeetingLiveCaptionEngine)?, (any MeetingLiveCaptionEngine)?) in
            defer {
                self.microphoneEngine = nil
                self.applicationEngine = nil
            }
            return (self.microphoneEngine, self.applicationEngine)
        }
        self.diag(
            "[live] stopping engines offers=\(self.stateLock.withLock { self.offerCounts.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ") })"
        )
        // Concurrently: a cloud engine can wait a few seconds for its provider's last words.
        await withTaskGroup(of: Void.self) { group in
            for engine in [microphone, application].compactMap(\.self) {
                group.addTask { await engine.stop() }
            }
        }
        self.diag("[live] engines stopped, models released")
    }

    /// What the Live cloud provider transcribed, or nil when captions ran on this Mac. Read after
    /// `stop()`, which lets each provider finish its last words first.
    func cloudTranscript() -> MeetingLiveCloudTranscript? {
        self.stateLock.withLock {
            self.cloudConfiguration.map { configuration in
                MeetingLiveCloudTranscript(
                    provider: configuration.provider,
                    modelID: configuration.modelID,
                    turns: self.cloudTurns.sorted { $0.presentationStart < $1.presentationStart }
                )
            }
        }
    }

    private func launch(_ engine: any MeetingLiveCaptionEngine) {
        Task { [weak self] in
            guard let self else { return }
            await engine.configure(
                onPartial: { [weak self] kind, id, text, start, end in
                    self?.handlePartial(kind: kind, id: id, text: text, start: start, end: end)
                },
                onUtterance: { [weak self] kind, id, text, start, end in
                    self?.handleUtterance(kind: kind, id: id, text: text, start: start, end: end)
                },
                onDegraded: { [weak self] kind, reason in
                    self?.handleDegraded(kind: kind, reason: reason)
                },
                onReady: { [weak self] kind in
                    self?.handleReady(kind: kind)
                }
            )
            await engine.start()
        }
    }

    private func handlePartial(kind: MeetingAudioTrackKind, id: UUID, text: String, start: CMTime, end: CMTime) {
        guard let origin = self.originBox.current else { return }
        let startSeconds = MeetingLiveTimeConversion.sessionSeconds(pts: start, origin: origin)
        let speaker = Self.speaker(for: kind)
        let partial = MeetingLivePartial(id: id, text: text, start: startSeconds)
        self.publish { $0.settingPartial(partial, for: speaker) }
    }

    /// Not `private`: Phase 4 tests drive it directly, predating the solidify UUID — hence the default.
    func handleUtterance(kind: MeetingAudioTrackKind, id: UUID = UUID(), text: String, start: CMTime, end: CMTime) {
        guard let origin = self.originBox.current else { return }
        let startSeconds = MeetingLiveTimeConversion.sessionSeconds(pts: start, origin: origin)
        let endSeconds = MeetingLiveTimeConversion.sessionSeconds(pts: end, origin: origin)
        let speaker = Self.speaker(for: kind)

        let updated: MeetingLiveTranscriptSnapshot = self.stateLock.withLock {
            if self.cloudConfiguration != nil {
                // Processing applies its own echo verdicts, so the transcript keeps every turn.
                self.cloudTurns.append(MeetingLiveCloudTranscript.Turn(
                    trackKind: kind,
                    text: text,
                    presentationStart: start.seconds,
                    presentationEnd: end.seconds
                ))
            }
            self.snapshot.revision &+= 1
            if speaker == .you {
                if self.microphoneCaptureMethod != .voiceProcessing {
                    let recentThem = MeetingLiveEchoFilter.recentThemText(
                        from: self.recentThemUtterances,
                        before: startSeconds,
                        windowSeconds: Self.echoWindowSeconds
                    )
                    if MeetingLiveEchoFilter.shouldSuppress(micText: text, recentThemText: recentThem) {
                        self.snapshot = self.snapshot.settingPartial(nil, for: .you).markingFinalized(id)
                        return self.snapshot
                    }
                }
            } else {
                let record = MeetingLiveUtterance(id: id, speaker: .them, text: text, start: startSeconds, end: endSeconds)
                self.recentThemUtterances.append(record)
                self.recentThemUtterances.removeAll { $0.end < startSeconds - Self.echoWindowSeconds }
            }
            let utterance = MeetingLiveUtterance(id: id, speaker: speaker, text: text, start: startSeconds, end: endSeconds)
            self.snapshot = self.snapshot.inserting(utterance).settingPartial(nil, for: speaker)
            return self.snapshot
        }
        self.onUpdate(updated)
    }

    private func handleDegraded(kind: MeetingAudioTrackKind, reason: String) {
        DebugLogger.shared.warning("Live captions degraded: \(reason)", source: "MeetingLive")
        self.setAvailability(.degraded(reason: reason), for: kind)
    }

    /// A cloud engine reports ready again after it reconnects, which clears its own degraded state.
    private func handleReady(kind: MeetingAudioTrackKind) {
        self.setAvailability(.available, for: kind)
    }

    private func setAvailability(_ availability: MeetingLiveAvailability, for kind: MeetingAudioTrackKind) {
        let combined = self.stateLock.withLock { () -> MeetingLiveAvailability? in
            self.trackAvailability[kind] = availability
            return Self.combinedAvailability(self.trackAvailability)
        }
        guard let combined else { return }
        self.publish { $0.settingAvailability(combined) }
    }

    /// A degraded track wins, so its reason stays visible; otherwise one ready track makes captions
    /// available. Nil while no track has reported, which keeps the starting message.
    static func combinedAvailability(_ tracks: [MeetingAudioTrackKind: MeetingLiveAvailability]) -> MeetingLiveAvailability? {
        for kind in [MeetingAudioTrackKind.microphone, .applicationAudio] {
            if case .degraded = tracks[kind] { return tracks[kind] }
        }
        return tracks.values.contains(.available) ? .available : nil
    }

    private static func speaker(for kind: MeetingAudioTrackKind) -> MeetingLiveSpeaker {
        kind == .microphone ? .you : .them
    }

    private func publish(_ transform: (MeetingLiveTranscriptSnapshot) -> MeetingLiveTranscriptSnapshot) {
        let updated: MeetingLiveTranscriptSnapshot = self.stateLock.withLock {
            self.snapshot = transform(self.snapshot)
            self.snapshot.revision &+= 1
            return self.snapshot
        }
        self.onUpdate(updated)
    }
}

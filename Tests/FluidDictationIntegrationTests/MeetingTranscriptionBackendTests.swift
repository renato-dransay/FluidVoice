@testable import FluidVoice_Debug
import Foundation
import XCTest

/// Milestone A of `MEETING_TRANSCRIPTION_IMPLEMENTATION_PLAN.md`: the backend contract, the
/// injectable registry, evidence validation, and proof that `MeetingProcessingPipeline.process`
/// really dispatches through a selected backend.
///
/// The dispatch tests deliberately fail the `asrServiceProvider` closure: a fixture backend must be
/// reached without any ASR model readiness work, which is what makes "selection happens before
/// expensive model loading" a checked property rather than a claim.
@MainActor
final class MeetingTranscriptionBackendTests: XCTestCase {
    // MARK: - Fixture backend

    private final class FixtureMeetingBackend: MeetingTranscriptionBackend {
        let descriptor: MeetingBackendDescriptor
        private let makeOutcome: @MainActor (MeetingBackendPlan) -> MeetingBackendOutcome
        /// Lets a test hand back a plan that contradicts the request it was given.
        private let planOverride: (@MainActor (MeetingBackendRequest) -> MeetingBackendPlan)?
        private(set) var planCallCount = 0
        private(set) var executeCallCount = 0
        private(set) var lastPlan: MeetingBackendPlan?
        private(set) var receivedManifest: MeetingAnalysisManifest??
        private(set) var observedStages: [MeetingProcessingStage] = []

        init(
            descriptor: MeetingBackendDescriptor,
            planOverride: (@MainActor (MeetingBackendRequest) -> MeetingBackendPlan)? = nil,
            makeOutcome: @escaping @MainActor (MeetingBackendPlan) -> MeetingBackendOutcome
        ) {
            self.descriptor = descriptor
            self.planOverride = planOverride
            self.makeOutcome = makeOutcome
        }

        func plan(_ request: MeetingBackendRequest) throws -> MeetingBackendPlan {
            self.planCallCount += 1
            let plan = self.planOverride?(request)
                ?? MeetingBackendPlan(request: request, descriptor: self.descriptor)
            self.lastPlan = plan
            return plan
        }

        func execute(
            plan: MeetingBackendPlan,
            manifest: MeetingAnalysisManifest?,
            progress: @escaping @MainActor (MeetingProcessingStage) -> Void
        ) async throws -> MeetingBackendOutcome {
            self.executeCallCount += 1
            self.receivedManifest = manifest
            progress(.transcribing)
            self.observedStages.append(.transcribing)
            return self.makeOutcome(plan)
        }
    }

    /// Calls the host's legacy executor with whatever request a test wants, to prove the host
    /// refuses anything but the exact request it froze.
    private final class LegacyCallbackBackend: MeetingTranscriptionBackend {
        let descriptor: MeetingBackendDescriptor
        private let executor: MeetingLegacyBackendExecutor
        private let rewriteRequest: @MainActor (MeetingBackendRequest) -> MeetingBackendRequest

        init(
            descriptor: MeetingBackendDescriptor,
            executor: @escaping MeetingLegacyBackendExecutor,
            rewriteRequest: @escaping @MainActor (MeetingBackendRequest) -> MeetingBackendRequest
        ) {
            self.descriptor = descriptor
            self.executor = executor
            self.rewriteRequest = rewriteRequest
        }

        func plan(_ request: MeetingBackendRequest) throws -> MeetingBackendPlan {
            MeetingBackendPlan(request: request, descriptor: self.descriptor)
        }

        func execute(
            plan: MeetingBackendPlan,
            manifest: MeetingAnalysisManifest?,
            progress: @escaping @MainActor (MeetingProcessingStage) -> Void
        ) async throws -> MeetingBackendOutcome {
            try .legacyCompatibility(await self.executor(self.rewriteRequest(plan.request), progress))
        }
    }

    /// Parks inside `execute` on a latch that ignores cancellation, then returns successfully —
    /// a backend that does not cooperate with `Task` cancellation.
    private final class BlockingFixtureBackend: MeetingTranscriptionBackend {
        let descriptor: MeetingBackendDescriptor
        private let latch: Latch
        private let onEnter: @MainActor () -> Void
        private let makeOutcome: @MainActor (MeetingBackendPlan) -> MeetingBackendOutcome
        private(set) var executeCallCount = 0
        private(set) var didProduceOutcome = false

        init(
            descriptor: MeetingBackendDescriptor,
            latch: Latch,
            onEnter: @escaping @MainActor () -> Void,
            makeOutcome: @escaping @MainActor (MeetingBackendPlan) -> MeetingBackendOutcome
        ) {
            self.descriptor = descriptor
            self.latch = latch
            self.onEnter = onEnter
            self.makeOutcome = makeOutcome
        }

        func plan(_ request: MeetingBackendRequest) throws -> MeetingBackendPlan {
            MeetingBackendPlan(request: request, descriptor: self.descriptor)
        }

        func execute(
            plan: MeetingBackendPlan,
            manifest: MeetingAnalysisManifest?,
            progress: @escaping @MainActor (MeetingProcessingStage) -> Void
        ) async throws -> MeetingBackendOutcome {
            self.executeCallCount += 1
            self.onEnter()
            await self.latch.wait()
            self.didProduceOutcome = true
            return self.makeOutcome(plan)
        }
    }

    /// Deliberately cancellation-deaf: a parked waiter is only resumed by `open()`.
    private actor Latch {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var isOpen = false

        func wait() async {
            if self.isOpen { return }
            await withCheckedContinuation { self.park($0) }
        }

        func open() {
            self.isOpen = true
            let parked = self.waiters
            self.waiters.removeAll()
            for continuation in parked {
                continuation.resume()
            }
        }

        private func park(_ continuation: CheckedContinuation<Void, Never>) {
            self.waiters.append(continuation)
        }
    }

    private nonisolated static let fixtureBackendID = MeetingBackendID(rawValue: "fixture-test-backend")

    private func makeFixtureDescriptor(
        id: MeetingBackendID = MeetingTranscriptionBackendTests.fixtureBackendID,
        version: String = "test",
        trackKinds: Set<MeetingAudioTrackKind> = Set(MeetingAudioTrackKind.allCases),
        precisions: Set<MeetingTextUnitPrecision> = [.word, .utterance],
        resultContract: MeetingBackendResultContract = .legacyResult
    ) -> MeetingBackendDescriptor {
        MeetingBackendDescriptor(
            id: id,
            version: version,
            execution: .local,
            supportedLanguageCodes: ["en"],
            supportedTrackKinds: trackKinds,
            supportedFinalPrecisions: precisions,
            resultContract: resultContract,
            knownLimits: ["Fixture only; performs no inference."]
        )
    }

    // MARK: - Session fixtures

    private func makeChunk(sequence: Int, path: String) -> MeetingAudioChunk {
        MeetingAudioChunk(
            id: UUID(),
            sequence: sequence,
            relativeFilePath: path,
            presentationStart: MeetingMediaTime(value: Int64(sequence) * 1000, timescale: 1000),
            presentationEnd: MeetingMediaTime(value: Int64(sequence + 1) * 1000, timescale: 1000),
            discontinuities: [],
            sha256: "fixture-\(sequence)",
            byteCount: 1024,
            finalizationState: .finalized
        )
    }

    private func makeTrack(kind: MeetingAudioTrackKind, chunks: [MeetingAudioChunk]) -> MeetingAudioTrack {
        MeetingAudioTrack(
            id: UUID(),
            kind: kind,
            sourceIdentifier: kind.rawValue,
            sourceDisplayName: kind.rawValue,
            format: nil,
            timebase: MeetingTimebaseMetadata(
                startedHostTime: 0,
                machTimebaseNumerator: 1,
                machTimebaseDenominator: 1,
                firstPresentationTime: nil
            ),
            health: .waiting,
            chunks: chunks
        )
    }

    private func makeSession(
        languageCode: String = "en",
        // nil requests the fixture default; an empty collection tests explicitly missing data.
        // swiftlint:disable:next discouraged_optional_collection
        tracks: [MeetingAudioTrack]? = nil,
        processingAttempts: [MeetingProcessingAttempt] = []
    ) -> MeetingSession {
        var session = MeetingSession(
            configuration: MeetingCaptureConfiguration(
                mode: .onlineCall,
                title: "Backend fixture",
                languageCode: languageCode,
                microphone: MeetingMicrophoneIdentity(captureDeviceID: "mic-1", displayName: "Mic")
            ),
            timebase: MeetingTimebaseMetadata(
                startedHostTime: 0,
                machTimebaseNumerator: 1,
                machTimebaseDenominator: 1,
                firstPresentationTime: nil
            )
        )
        session.audioTracks = tracks ?? [
            self.makeTrack(kind: .microphone, chunks: [self.makeChunk(sequence: 0, path: "tracks/microphone/chunk_0.caf")]),
        ]
        session.processingAttempts = processingAttempts
        return session
    }

    private func makeResult(attemptID: UUID, text: String) -> MeetingProcessingResult {
        MeetingProcessingResult(
            speakers: [],
            segments: [
                MeetingTranscriptSegment(
                    id: UUID(),
                    start: MeetingMediaTime(value: 0, timescale: 1000),
                    end: MeetingMediaTime(value: 1000, timescale: 1000),
                    sourceTrackID: UUID(),
                    speakerID: nil,
                    text: text,
                    revision: 1,
                    status: .final,
                    overlap: .none,
                    completeness: .complete
                ),
            ],
            attempt: MeetingProcessingAttempt(
                id: attemptID,
                startedAt: Date(),
                completedAt: Date(),
                stage: .completed,
                pipelineVersion: MeetingProcessingPipeline.pipelineVersion,
                asrProvider: "fixture",
                asrModel: "fixture",
                diarizationModel: nil,
                lastCompletedTrackID: nil,
                errorCode: nil
            )
        )
    }

    private func makePipeline(
        registry: MeetingTranscriptionBackendRegistry,
        backendID: MeetingBackendID?,
        gate: MeetingProcessingSerializationGate = MeetingProcessingSerializationGate()
    ) -> MeetingProcessingPipeline {
        MeetingProcessingPipeline(
            asrServiceProvider: {
                XCTFail("Backend dispatch must not reach ASR readiness for a fixture backend")
                return ASRService()
            },
            managesModelResidency: false,
            serializationGate: gate,
            backendRegistry: registry,
            backendID: backendID
        )
    }

    func testRegistryRejectsFactoryIdentityMismatch() throws {
        let registry = MeetingTranscriptionBackendRegistry()
        registry.register(Self.fixtureBackendID) { [self] _ in
            FixtureMeetingBackend(descriptor: self.makeFixtureDescriptor(id: .legacyCompatibility)) { _ in
                fatalError("Mismatched factory must not execute")
            }
        }
        XCTAssertThrowsError(try registry.makeBackend(
            id: Self.fixtureBackendID,
            context: MeetingBackendHostContext(legacyExecutor: { _, _ in
                throw MeetingProcessingError.noRecoverableAudio
            })
        )) { error in
            XCTAssertEqual(error as? MeetingBackendError, .backendIdentityMismatch(
                requested: Self.fixtureBackendID, produced: .legacyCompatibility
            ))
        }
    }

    func testPipelineRejectsPlanForDifferentDirectory() async throws {
        let descriptor = self.makeFixtureDescriptor()
        let registry = MeetingTranscriptionBackendRegistry(defaultBackendID: Self.fixtureBackendID)
        registry.register(Self.fixtureBackendID) { _ in
            FixtureMeetingBackend(descriptor: descriptor, planOverride: { request in
                MeetingBackendPlan(request: MeetingBackendRequest(
                    attemptID: request.attemptID,
                    session: request.session,
                    sessionDirectory: request.sessionDirectory.appendingPathComponent("another-session"),
                    configuration: request.configuration
                ), descriptor: descriptor)
            }) { _ in fatalError("Substituted plan must not execute") }
        }
        do {
            _ = try await self.makePipeline(registry: registry, backendID: nil).process(
                session: self.makeSession(),
                sessionDirectory: FileManager.default.temporaryDirectory,
                progress: { _ in }
            )
            XCTFail("Substituted request must fail before model work")
        } catch {
            XCTAssertEqual(
                error as? MeetingBackendError,
                .planDisagreesWithRequest(backend: Self.fixtureBackendID, defect: .request)
            )
        }
    }

    func testLegacyExecutorRejectsSubstitutedRequest() async throws {
        let descriptor = self.makeFixtureDescriptor()
        let registry = MeetingTranscriptionBackendRegistry(defaultBackendID: Self.fixtureBackendID)
        registry.register(Self.fixtureBackendID) { context in
            LegacyCallbackBackend(descriptor: descriptor, executor: context.legacyExecutor) { request in
                MeetingBackendRequest(
                    attemptID: UUID(),
                    session: request.session,
                    sessionDirectory: request.sessionDirectory,
                    configuration: request.configuration
                )
            }
        }
        do {
            _ = try await self.makePipeline(registry: registry, backendID: nil).process(
                session: self.makeSession(),
                sessionDirectory: FileManager.default.temporaryDirectory,
                progress: { _ in }
            )
            XCTFail("Substituted executor request must fail")
        } catch {
            XCTAssertEqual(
                error as? MeetingBackendError,
                .legacyExecutorRequestMismatch(backend: Self.fixtureBackendID)
            )
        }
    }

    func testCancelledNonCooperativeBackendDoesNotPublishAndReleasesLease() async throws {
        let gate = MeetingProcessingSerializationGate()
        let entered = Latch()
        let latch = Latch()
        let registry = MeetingTranscriptionBackendRegistry(defaultBackendID: Self.fixtureBackendID)
        registry.register(Self.fixtureBackendID) { [self] _ in
            BlockingFixtureBackend(
                descriptor: self.makeFixtureDescriptor(),
                latch: latch,
                onEnter: { Task { await entered.open() } }
            ) { plan in
                .legacyCompatibility(self.makeResult(attemptID: plan.attemptID, text: "cancelled"))
            }
        }
        let pipeline = self.makePipeline(registry: registry, backendID: nil, gate: gate)
        let task = Task {
            try await pipeline.process(
                session: self.makeSession(),
                sessionDirectory: FileManager.default.temporaryDirectory,
                progress: { _ in }
            )
        }
        await entered.wait()
        task.cancel()
        await latch.open()
        do {
            _ = try await task.value
            XCTFail("Cancelled backend result must not be returned")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }

        registry.register(Self.fixtureBackendID) { [self] _ in
            FixtureMeetingBackend(descriptor: self.makeFixtureDescriptor()) { plan in
                .legacyCompatibility(self.makeResult(attemptID: plan.attemptID, text: "next"))
            }
        }
        let result = try await pipeline.process(
            session: self.makeSession(),
            sessionDirectory: FileManager.default.temporaryDirectory,
            progress: { _ in }
        )
        XCTAssertEqual(result.segments.map(\.text), ["next"])
    }

    func testMeetingPreferencePreservesUnknownIDsAndDoesNotChangeDictation() {
        let defaults = UserDefaults.standard
        let key = "MeetingTranscriptionBackendID"
        let oldValue = defaults.object(forKey: key)
        defer {
            if let oldValue { defaults.set(oldValue, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        let settings = SettingsStore.shared
        let dictationModel = settings.selectedSpeechModel
        defaults.removeObject(forKey: key)
        XCTAssertEqual(settings.meetingTranscriptionBackendID, .productionDefault)
        let future = MeetingBackendID(rawValue: "future.unavailable-engine")
        settings.meetingTranscriptionBackendID = future
        XCTAssertEqual(settings.meetingTranscriptionBackendID, future)
        XCTAssertEqual(defaults.string(forKey: key), future.rawValue)
        XCTAssertEqual(settings.selectedSpeechModel, dictationModel)
    }

    func testMeetingPreferenceBackupPreservesUnknownIDAndMigratesMissingToDefault() async throws {
        let defaults = UserDefaults.standard
        let key = "MeetingTranscriptionBackendID"
        let oldValue = defaults.object(forKey: key)
        defer {
            if let oldValue { defaults.set(oldValue, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        let settingsStore = SettingsStore.shared
        let future = MeetingBackendID(rawValue: "future.hosted-provider")
        settingsStore.meetingTranscriptionBackendID = future

        let document = try await BackupService.shared.makeBackupDocument()
        XCTAssertEqual(document.settings.meetingTranscriptionBackendID, future.rawValue)

        let encoded = try BackupService.shared.encode(document)
        let decoded = try BackupService.shared.decode(encoded)
        settingsStore.meetingTranscriptionBackendID = .legacyCompatibility
        settingsStore.restore(from: decoded.settings)
        XCTAssertEqual(settingsStore.meetingTranscriptionBackendID, future)

        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var payload = try XCTUnwrap(root["settings"] as? [String: Any])
        payload.removeValue(forKey: "meetingTranscriptionBackendID")
        root["settings"] = payload
        let legacy = try BackupService.shared.decode(JSONSerialization.data(withJSONObject: root))
        XCTAssertNil(legacy.settings.meetingTranscriptionBackendID)

        settingsStore.meetingTranscriptionBackendID = future
        settingsStore.restore(from: legacy.settings)
        XCTAssertEqual(settingsStore.meetingTranscriptionBackendID, .productionDefault)
    }

    func testMeetingDetectionTogglesRoundTripThroughBackupAndLegacyBackupsKeepCurrentValues() async throws {
        let defaults = UserDefaults.standard
        let keys = ["MeetingAutoDetectEnabled", "MeetingAutoDetectBrowserEnabled"]
        let oldValues = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, oldValue) in zip(keys, oldValues) {
                if let oldValue { defaults.set(oldValue, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        let settingsStore = SettingsStore.shared
        settingsStore.meetingAutoDetectEnabled = false
        settingsStore.meetingAutoDetectBrowserEnabled = true

        let document = try await BackupService.shared.makeBackupDocument()
        XCTAssertEqual(document.settings.meetingAutoDetectEnabled, false)
        XCTAssertEqual(document.settings.meetingAutoDetectBrowserEnabled, true)

        let encoded = try BackupService.shared.encode(document)
        let decoded = try BackupService.shared.decode(encoded)
        settingsStore.meetingAutoDetectEnabled = true
        settingsStore.meetingAutoDetectBrowserEnabled = false
        settingsStore.restore(from: decoded.settings)
        XCTAssertFalse(settingsStore.meetingAutoDetectEnabled)
        XCTAssertTrue(settingsStore.meetingAutoDetectBrowserEnabled)

        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var payload = try XCTUnwrap(root["settings"] as? [String: Any])
        for key in ["meetingAutoDetectEnabled", "meetingAutoDetectBrowserEnabled"] {
            payload.removeValue(forKey: key)
        }
        root["settings"] = payload
        let legacy = try BackupService.shared.decode(JSONSerialization.data(withJSONObject: root))
        XCTAssertNil(legacy.settings.meetingAutoDetectEnabled)
        settingsStore.meetingAutoDetectEnabled = true
        settingsStore.meetingAutoDetectBrowserEnabled = false
        settingsStore.restore(from: legacy.settings)
        XCTAssertTrue(settingsStore.meetingAutoDetectEnabled, "older backups leave the current value alone")
        XCTAssertFalse(settingsStore.meetingAutoDetectBrowserEnabled)
    }

    // MARK: - Calendar context

    private func makeCalendarCandidate(
        id: String,
        title: String,
        startOffset: TimeInterval,
        endOffset: TimeInterval,
        isAllDay: Bool = false,
        searchableText: String = "",
        attendees: [MeetingCalendarAttendee] = []
    ) -> MeetingCalendarEventCandidate {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        return MeetingCalendarEventCandidate(
            eventIdentifier: id,
            title: title,
            start: now.addingTimeInterval(startOffset),
            end: now.addingTimeInterval(endOffset),
            isAllDay: isAllDay,
            searchableText: searchableText,
            attendees: attendees
        )
    }

    func testCalendarConferenceLinkMatchBeatsOverlappingTimeMatch() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let overlapping = self.makeCalendarCandidate(id: "overlap", title: "Overlapping event", startOffset: -600, endOffset: 1800)
        let linked = self.makeCalendarCandidate(
            id: "linked",
            title: "Weekly sync",
            startOffset: 300,
            endOffset: 2100,
            searchableText: "join: https://meet.google.com/abc-defg-hij\nagenda"
        )

        let match = MeetingCalendarRanking.bestMatch(
            among: [overlapping, linked],
            at: now,
            conferenceFragment: "meet.google.com/abc-defg-hij"
        )
        XCTAssertEqual(match?.eventIdentifier, "linked")
        XCTAssertEqual(match?.title, "Weekly sync")
        XCTAssertEqual(match?.matchedByConferenceLink, true)

        let timeOnly = MeetingCalendarRanking.bestMatch(among: [overlapping, linked], at: now, conferenceFragment: nil)
        XCTAssertEqual(timeOnly?.eventIdentifier, "overlap")
        XCTAssertEqual(timeOnly?.matchedByConferenceLink, false)
    }

    func testCalendarAmbiguousOverlapWithoutLinkMatchYieldsNil() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = self.makeCalendarCandidate(id: "a", title: "A", startOffset: -300, endOffset: 1500)
        let second = self.makeCalendarCandidate(id: "b", title: "B", startOffset: -60, endOffset: 900)

        XCTAssertNil(MeetingCalendarRanking.bestMatch(among: [first, second], at: now, conferenceFragment: nil))
        XCTAssertNil(MeetingCalendarRanking.bestMatch(among: [first, second], at: now, conferenceFragment: "zoom.us/j/123"))
        XCTAssertNil(MeetingCalendarRanking.bestMatch(among: [], at: now, conferenceFragment: nil))
    }

    func testCalendarAllDayEventsAreIgnored() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let allDay = self.makeCalendarCandidate(
            id: "all-day",
            title: "Company offsite",
            startOffset: -36000,
            endOffset: 36000,
            isAllDay: true,
            searchableText: "https://zoom.us/j/123456789"
        )
        let timed = self.makeCalendarCandidate(id: "timed", title: "Standup", startOffset: -120, endOffset: 780)

        XCTAssertEqual(
            MeetingCalendarRanking.bestMatch(among: [allDay, timed], at: now, conferenceFragment: nil)?.eventIdentifier,
            "timed"
        )
        XCTAssertNil(MeetingCalendarRanking.bestMatch(among: [allDay], at: now, conferenceFragment: "zoom.us/j/123456789"))
    }

    func testCalendarAttendeesExcludeCurrentUserAndRooms() {
        let attendees = MeetingCalendarRanking.attendees(
            from: [
                .init(name: "Me", urlString: "mailto:me@example.com", isCurrentUser: true, kind: .person),
                .init(name: "Jane Doe", urlString: "mailto:jane@example.com", isCurrentUser: false, kind: .person),
                .init(name: "Room 4B", urlString: "mailto:room4b@resource.example.com", isCurrentUser: false, kind: .room),
                .init(name: "Projector", urlString: "mailto:projector@resource.example.com", isCurrentUser: false, kind: .resource),
                .init(name: nil, urlString: "mailto:bob.smith@example.com", isCurrentUser: false, kind: .unknown),
                .init(name: " ", urlString: nil, isCurrentUser: false, kind: .person),
            ],
            organizerURLString: "mailto:Jane@example.com"
        )

        XCTAssertEqual(attendees.map(\.name), ["Jane Doe", "bob.smith"])
        XCTAssertEqual(attendees.map(\.email), ["jane@example.com", "bob.smith@example.com"])
        XCTAssertEqual(attendees.map(\.isOrganizer), [true, false])
    }

    func testCalendarNamesToggleRoundTripsThroughBackupAndLegacyBackupsKeepCurrentValue() async throws {
        let defaults = UserDefaults.standard
        let key = "MeetingCalendarNamesEnabled"
        let oldValue = defaults.object(forKey: key)
        defer {
            if let oldValue { defaults.set(oldValue, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        let settingsStore = SettingsStore.shared
        settingsStore.meetingCalendarNamesEnabled = true

        let document = try await BackupService.shared.makeBackupDocument()
        XCTAssertEqual(document.settings.meetingCalendarNamesEnabled, true)

        let encoded = try BackupService.shared.encode(document)
        let decoded = try BackupService.shared.decode(encoded)
        settingsStore.meetingCalendarNamesEnabled = false
        settingsStore.restore(from: decoded.settings)
        XCTAssertTrue(settingsStore.meetingCalendarNamesEnabled)

        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var payload = try XCTUnwrap(root["settings"] as? [String: Any])
        payload.removeValue(forKey: "meetingCalendarNamesEnabled")
        root["settings"] = payload
        let legacy = try BackupService.shared.decode(JSONSerialization.data(withJSONObject: root))
        XCTAssertNil(legacy.settings.meetingCalendarNamesEnabled)
        settingsStore.meetingCalendarNamesEnabled = false
        settingsStore.restore(from: legacy.settings)
        XCTAssertFalse(settingsStore.meetingCalendarNamesEnabled, "older backups leave the current value alone")
    }

    func testSessionCalendarContextRoundTripsAndLegacySessionsDecodeWithoutIt() throws {
        let match = MeetingCalendarMatch(
            eventIdentifier: "event-1",
            title: "Design review",
            attendees: [MeetingCalendarAttendee(name: "Jane Doe", email: "jane@example.com", isOrganizer: true)],
            matchedByConferenceLink: true
        )
        var session = self.makeSession()
        session.calendarContext = match

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(MeetingSession.self, from: encoder.encode(session))
        XCTAssertEqual(decoded.calendarContext, match)

        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(session)) as? [String: Any])
        root.removeValue(forKey: "calendarContext")
        let legacy = try decoder.decode(MeetingSession.self, from: JSONSerialization.data(withJSONObject: root))
        XCTAssertNil(legacy.calendarContext)
        XCTAssertEqual(legacy.id, session.id)

        let configuration = MeetingCaptureConfiguration(
            mode: .onlineCall,
            title: "Meeting",
            microphone: MeetingMicrophoneIdentity(captureDeviceID: "mic-1", displayName: "Mic"),
            calendar: match
        )
        XCTAssertEqual(configuration.calendar, match)
        XCTAssertNil(MeetingCaptureConfiguration(
            mode: .onlineCall,
            title: "Meeting",
            microphone: MeetingMicrophoneIdentity(captureDeviceID: "mic-1", displayName: "Mic")
        ).calendar)
    }

    func testCalendarAttendeesSeedRemoteSpeakerCandidatesOnly() {
        let remote = MeetingSessionSpeaker(
            id: UUID(),
            displayName: "Speaker 1",
            diarizationClusterID: nil,
            trackKind: .applicationAudio,
            isLocalUser: false,
            identityCandidates: []
        )
        let local = MeetingSessionSpeaker(
            id: UUID(),
            displayName: "You",
            diarizationClusterID: nil,
            trackKind: .microphone,
            isLocalUser: true,
            identityCandidates: []
        )
        let attendees = [
            MeetingCalendarAttendee(name: "Jane Doe", email: "jane@example.com", isOrganizer: true),
            MeetingCalendarAttendee(name: "Bob", email: nil, isOrganizer: false),
        ]

        let seeded = MeetingProcessingPipeline.seedingCalendarIdentityCandidates(into: [remote, local], attendees: attendees)
        XCTAssertEqual(seeded[0].displayName, "Speaker 1", "labels stay automatic; names are offered, never assigned")
        XCTAssertEqual(seeded[0].identityCandidates.map(\.displayName), ["Jane Doe", "Bob"])
        XCTAssertEqual(seeded[0].identityCandidates.map(\.source), ["calendar", "calendar"])
        XCTAssertTrue(seeded[1].identityCandidates.isEmpty)
        XCTAssertEqual(MeetingProcessingPipeline.seedingCalendarIdentityCandidates(into: [remote], attendees: []), [remote])
    }

    func testSelectionIsFrozenDuringExecutionAndRefreshedForNextAttempt() async throws {
        let firstID = Self.fixtureBackendID
        let secondID = MeetingBackendID(rawValue: "fixture-second")
        let registry = MeetingTranscriptionBackendRegistry(defaultBackendID: firstID)
        let entered = Latch()
        let latch = Latch()
        registry.register(firstID) { [self] _ in
            BlockingFixtureBackend(
                descriptor: self.makeFixtureDescriptor(),
                latch: latch,
                onEnter: { Task { await entered.open() } }
            ) { plan in
                .legacyCompatibility(self.makeResult(attemptID: plan.attemptID, text: "first"))
            }
        }
        registry.register(secondID) { [self] _ in
            FixtureMeetingBackend(descriptor: self.makeFixtureDescriptor(id: secondID)) { plan in
                .legacyCompatibility(self.makeResult(attemptID: plan.attemptID, text: "second"))
            }
        }
        var selected = firstID
        var selectionReads = 0
        let pipeline = MeetingProcessingPipeline(
            asrServiceProvider: { fatalError("Fixture must not load ASR") },
            managesModelResidency: false,
            serializationGate: MeetingProcessingSerializationGate(),
            backendRegistry: registry,
            backendIDProvider: { selectionReads += 1; return selected }
        )
        let session = self.makeSession()
        let task = Task {
            try await pipeline.process(
                session: session,
                sessionDirectory: FileManager.default.temporaryDirectory,
                progress: { _ in }
            )
        }
        await entered.wait()
        selected = secondID
        await latch.open()
        let first = try await task.value
        XCTAssertEqual(first.segments.map(\.text), ["first"])
        XCTAssertEqual(selectionReads, 1)
        let second = try await pipeline.process(
            session: session,
            sessionDirectory: FileManager.default.temporaryDirectory,
            progress: { _ in }
        )
        XCTAssertEqual(second.segments.map(\.text), ["second"])
        XCTAssertEqual(selectionReads, 2)
    }

    // MARK: - Registry

    func testDefaultRegistryUsesProductionDefaultAndKeepsLegacyRollback() throws {
        let registry = MeetingTranscriptionBackendRegistry.makeDefault()
        XCTAssertEqual(registry.defaultBackendID, .productionDefault)
        XCTAssertEqual(registry.registeredBackendIDs, [.legacyCompatibility, .parakeetNemotron, .openRouterNemotron])

        let backend = try registry.makeBackend(
            id: registry.defaultBackendID,
            context: MeetingBackendHostContext(legacyExecutor: { _, _ in
                XCTFail("Legacy executor must not run while only resolving the backend")
                throw MeetingProcessingError.noRecoverableAudio
            })
        )
        XCTAssertEqual(backend.descriptor.id, .parakeetNemotron)
        XCTAssertEqual(backend.descriptor.execution, .local)
        XCTAssertEqual(
            backend.descriptor.supportedFinalPrecisions, [.word, .utterance]
        )
    }

    func testRegistryRejectsAnUnknownBackendIdentifier() {
        let registry = MeetingTranscriptionBackendRegistry.makeDefault()
        let unknown = MeetingBackendID(rawValue: "not-registered")
        XCTAssertFalse(registry.contains(unknown))
        XCTAssertThrowsError(
            try registry.makeBackend(
                id: unknown,
                context: MeetingBackendHostContext(legacyExecutor: { _, _ in
                    throw MeetingProcessingError.noRecoverableAudio
                })
            )
        ) { error in
            XCTAssertEqual(error as? MeetingBackendError, .unknownBackend(unknown))
        }
    }

    // MARK: - Pipeline dispatch

    func testPipelineDispatchesToTheInjectedBackendBeforeAnyModelWork() async throws {
        let session = self.makeSession()
        var captured: MeetingProcessingResult?
        let registry = MeetingTranscriptionBackendRegistry(defaultBackendID: Self.fixtureBackendID)
        var fixture: FixtureMeetingBackend?
        registry.register(Self.fixtureBackendID) { [self] _ in
            let backend = FixtureMeetingBackend(descriptor: self.makeFixtureDescriptor()) { plan in
                let result = self.makeResult(attemptID: plan.attemptID, text: "dispatched")
                captured = result
                return .legacyCompatibility(result)
            }
            fixture = backend
            return backend
        }

        let pipeline = self.makePipeline(registry: registry, backendID: nil)
        var stages: [MeetingProcessingStage] = []
        let result = try await pipeline.process(
            session: session,
            sessionDirectory: FileManager.default.temporaryDirectory,
            progress: { stages.append($0) }
        )

        let backend = try XCTUnwrap(fixture)
        XCTAssertEqual(backend.planCallCount, 1)
        XCTAssertEqual(backend.executeCallCount, 1)
        XCTAssertEqual(stages, [.transcribing], "the backend's progress reaches the caller unchanged")
        XCTAssertEqual(result.segments.map(\.text), ["dispatched"])
        XCTAssertEqual(result.attempt.id, captured?.attempt.id)

        let plan = try XCTUnwrap(backend.lastPlan)
        XCTAssertEqual(plan.backendID, Self.fixtureBackendID)
        XCTAssertEqual(plan.trackKindsByID.count, 1)
        XCTAssertEqual(plan.chunkIDsByTrackID.values.first?.count, 1)
    }

    func testPipelineReusesTheOpenAttemptIdentifierForTheRequest() async throws {
        let openAttempt = MeetingProcessingAttempt(
            id: UUID(),
            startedAt: Date(timeIntervalSinceNow: -60),
            completedAt: nil,
            stage: .transcribing,
            pipelineVersion: MeetingProcessingPipeline.pipelineVersion,
            asrProvider: nil,
            asrModel: nil,
            diarizationModel: nil,
            lastCompletedTrackID: nil,
            errorCode: nil
        )
        let session = self.makeSession(processingAttempts: [openAttempt])
        let registry = MeetingTranscriptionBackendRegistry(defaultBackendID: Self.fixtureBackendID)
        var fixture: FixtureMeetingBackend?
        registry.register(Self.fixtureBackendID) { [self] _ in
            let backend = FixtureMeetingBackend(descriptor: self.makeFixtureDescriptor()) { plan in
                .legacyCompatibility(self.makeResult(attemptID: plan.attemptID, text: "retry"))
            }
            fixture = backend
            return backend
        }

        let pipeline = self.makePipeline(registry: registry, backendID: nil)
        let result = try await pipeline.process(
            session: session,
            sessionDirectory: FileManager.default.temporaryDirectory,
            progress: { _ in }
        )
        XCTAssertEqual(fixture?.lastPlan?.attemptID, openAttempt.id)
        XCTAssertEqual(result.attempt.id, openAttempt.id)
    }

    func testPipelineRejectsAnUnknownBackendIdentifierExplicitly() async {
        let registry = MeetingTranscriptionBackendRegistry.makeDefault()
        let unknown = MeetingBackendID(rawValue: "muse-cloud-v0")
        let pipeline = self.makePipeline(registry: registry, backendID: unknown)
        do {
            _ = try await pipeline.process(
                session: self.makeSession(),
                sessionDirectory: FileManager.default.temporaryDirectory,
                progress: { _ in }
            )
            XCTFail("An unregistered backend must not silently fall back to legacy")
        } catch {
            XCTAssertEqual(error as? MeetingBackendError, .unknownBackend(unknown))
        }
    }

    func testLanguageUsesBackendDescriptorAndAudioPreflightStillPrecedesSelection() async {
        var factoryCallCount = 0
        func registry() -> MeetingTranscriptionBackendRegistry {
            let registry = MeetingTranscriptionBackendRegistry(defaultBackendID: Self.fixtureBackendID)
            registry.register(Self.fixtureBackendID) { [self] _ in
                factoryCallCount += 1
                return FixtureMeetingBackend(descriptor: self.makeFixtureDescriptor()) { plan in
                    .legacyCompatibility(self.makeResult(attemptID: plan.attemptID, text: "unused"))
                }
            }
            return registry
        }

        do {
            _ = try await self.makePipeline(registry: registry(), backendID: nil).process(
                session: self.makeSession(languageCode: "fr"),
                sessionDirectory: FileManager.default.temporaryDirectory,
                progress: { _ in }
            )
            XCTFail("Non-English sessions must still be rejected")
        } catch {
            XCTAssertEqual(
                error as? MeetingBackendError,
                .unsupportedLanguage(backend: Self.fixtureBackendID, languageCode: "fr")
            )
        }

        do {
            _ = try await self.makePipeline(registry: registry(), backendID: nil).process(
                session: self.makeSession(tracks: [self.makeTrack(kind: .microphone, chunks: [])]),
                sessionDirectory: FileManager.default.temporaryDirectory,
                progress: { _ in }
            )
            XCTFail("A session with no chunks must still be rejected")
        } catch {
            guard case MeetingProcessingError.noRecoverableAudio = error else {
                return XCTFail("Expected noRecoverableAudio, got \(error)")
            }
        }

        XCTAssertEqual(factoryCallCount, 1, "Language validation uses the selected backend; empty audio fails before selection")
    }

    /// Every chunk reports unreadable, so a manifest builds to explicit gaps without fixture audio.
    private struct UnreadableFixtureObserver: MeetingChunkAudioObserving {
        func observe(
            chunk: MeetingAudioChunk,
            trackID: MeetingAudioTrackID
        ) -> MeetingChunkObservationResult {
            .failed(.unreadable, detail: "fixture")
        }
    }

    func testPipelineSurfacesMalformedCanonicalEvidenceAsAValidationFailure() async throws {
        let session = self.makeSession()
        let trackID = try XCTUnwrap(session.audioTracks.first?.id)
        let epoch = MeetingAnalysisEpochID(trackID: trackID, ordinal: 0)

        // A scope defect — text the backend never really produced — still fails validation,
        // now on the canonical path after a real (all-gap) manifest was built and handed over.
        let scopeRegistry = MeetingTranscriptionBackendRegistry(defaultBackendID: Self.fixtureBackendID)
        scopeRegistry.register(Self.fixtureBackendID) { [self] _ in
            FixtureMeetingBackend(
                descriptor: self.makeFixtureDescriptor(resultContract: .canonicalEvidence)
            ) { plan in
                .canonicalEvidence(MeetingCanonicalResultBundle(
                    evidence: MeetingFinalTranscriptEvidence(
                        backendID: plan.backendID,
                        attemptID: plan.attemptID,
                        units: [
                            MeetingFinalTextUnit(
                                id: "u-0",
                                trackID: trackID,
                                analysisEpochID: epoch,
                                precision: .utterance,
                                text: "   ",
                                analysisStart: 2,
                                analysisEnd: 4,
                                speaker: .unassigned,
                                analysisSpanIDs: ["span-0"]
                            ),
                        ]
                    ),
                    coverageReceipts: []
                ))
            }
        }

        do {
            _ = try await MeetingProcessingPipeline(
                asrServiceProvider: {
                    XCTFail("Canonical fixture must not load ASR")
                    return ASRService()
                },
                managesModelResidency: false,
                serializationGate: MeetingProcessingSerializationGate(),
                backendRegistry: scopeRegistry,
                backendID: nil,
                chunkObserver: UnreadableFixtureObserver()
            ).process(
                session: session,
                sessionDirectory: FileManager.default.temporaryDirectory,
                progress: { _ in }
            )
            XCTFail("Empty evidence text must not pass through the pipeline")
        } catch {
            XCTAssertEqual(error as? MeetingBackendEvidenceError, .emptyText(unitID: "u-0"))
        }
    }

    func testPipelineRejectsAnOutcomeThatContradictsTheDeclaredResultContract() async throws {
        // Declared canonical, returns the legacy shape: the pipeline must not reinterpret it.
        let canonicalRegistry = MeetingTranscriptionBackendRegistry(defaultBackendID: Self.fixtureBackendID)
        canonicalRegistry.register(Self.fixtureBackendID) { [self] _ in
            FixtureMeetingBackend(
                descriptor: self.makeFixtureDescriptor(resultContract: .canonicalEvidence)
            ) { plan in
                .legacyCompatibility(self.makeResult(attemptID: plan.attemptID, text: "wrong shape"))
            }
        }
        do {
            _ = try await MeetingProcessingPipeline(
                asrServiceProvider: {
                    XCTFail("Canonical fixture must not load ASR")
                    return ASRService()
                },
                managesModelResidency: false,
                serializationGate: MeetingProcessingSerializationGate(),
                backendRegistry: canonicalRegistry,
                backendID: nil,
                chunkObserver: UnreadableFixtureObserver()
            ).process(
                session: self.makeSession(),
                sessionDirectory: FileManager.default.temporaryDirectory,
                progress: { _ in }
            )
            XCTFail("A legacy outcome under a canonical contract must be rejected")
        } catch {
            XCTAssertEqual(
                error as? MeetingBackendError,
                .outcomeContractMismatch(backend: Self.fixtureBackendID, declared: .canonicalEvidence)
            )
        }

        // Declared legacy, returns canonical evidence: likewise a typed failure.
        let legacyRegistry = MeetingTranscriptionBackendRegistry(defaultBackendID: Self.fixtureBackendID)
        legacyRegistry.register(Self.fixtureBackendID) { [self] _ in
            FixtureMeetingBackend(descriptor: self.makeFixtureDescriptor(resultContract: .legacyResult)) { plan in
                .canonicalEvidence(MeetingCanonicalResultBundle(
                    evidence: MeetingFinalTranscriptEvidence(
                        backendID: plan.backendID,
                        attemptID: plan.attemptID,
                        units: []
                    ),
                    coverageReceipts: []
                ))
            }
        }
        do {
            _ = try await self.makePipeline(registry: legacyRegistry, backendID: nil).process(
                session: self.makeSession(),
                sessionDirectory: FileManager.default.temporaryDirectory,
                progress: { _ in }
            )
            XCTFail("Canonical evidence under a legacy contract must be rejected")
        } catch {
            XCTAssertEqual(
                error as? MeetingBackendError,
                .outcomeContractMismatch(backend: Self.fixtureBackendID, declared: .legacyResult)
            )
        }
    }

    // MARK: - Evidence validation

    private struct EvidenceFixture {
        let plan: MeetingBackendPlan
        let trackID: MeetingAudioTrackID
        let otherTrackID: MeetingAudioTrackID
        let epoch: MeetingAnalysisEpochID
    }

    private func makeEvidenceFixture(
        precisions: Set<MeetingTextUnitPrecision> = [.word, .utterance]
    ) throws -> EvidenceFixture {
        let microphone = self.makeTrack(
            kind: .microphone,
            chunks: [self.makeChunk(sequence: 0, path: "tracks/microphone/chunk_0.caf")]
        )
        let application = self.makeTrack(
            kind: .applicationAudio,
            chunks: [self.makeChunk(sequence: 0, path: "tracks/application/chunk_0.caf")]
        )
        let session = self.makeSession(tracks: [microphone, application])
        let request = MeetingBackendRequest(
            attemptID: UUID(),
            session: session,
            sessionDirectory: FileManager.default.temporaryDirectory,
            configuration: MeetingFinalProcessingConfiguration()
        )
        let plan = MeetingBackendPlan(
            request: request,
            descriptor: self.makeFixtureDescriptor(precisions: precisions)
        )
        return try EvidenceFixture(
            plan: plan,
            trackID: microphone.id,
            otherTrackID: application.id,
            epoch: MeetingAnalysisEpochID(trackID: microphone.id, ordinal: 0)
        )
    }

    private func makeUnit(
        _ fixture: EvidenceFixture,
        id: String = "u-0",
        precision: MeetingTextUnitPrecision = .word,
        text: String = "hello",
        analysisStart: TimeInterval = 1,
        analysisEnd: TimeInterval = 2,
        trackID: MeetingAudioTrackID? = nil,
        epoch: MeetingAnalysisEpochID? = nil,
        speaker: MeetingBackendSpeakerAssignment? = nil,
        // nil requests the fixture default; an empty collection tests explicitly missing data.
        // swiftlint:disable:next discouraged_optional_collection
        analysisSpanIDs: [String]? = nil,
        confidence: Double? = nil
    ) -> MeetingFinalTextUnit {
        let resolvedEpoch = epoch ?? fixture.epoch
        return MeetingFinalTextUnit(
            id: id,
            trackID: trackID ?? fixture.trackID,
            analysisEpochID: resolvedEpoch,
            precision: precision,
            text: text,
            analysisStart: analysisStart,
            analysisEnd: analysisEnd,
            speaker: speaker ?? .assigned(MeetingBackendSpeakerToken(analysisEpochID: resolvedEpoch, label: "slot-0")),
            analysisSpanIDs: analysisSpanIDs ?? ["span-0"],
            confidence: confidence
        )
    }

    private func evidence(
        _ fixture: EvidenceFixture,
        units: [MeetingFinalTextUnit],
        activity: [MeetingBackendSpeakerActivity] = []
    ) -> MeetingFinalTranscriptEvidence {
        MeetingFinalTranscriptEvidence(
            backendID: fixture.plan.backendID,
            attemptID: fixture.plan.attemptID,
            units: units,
            speakerActivity: activity
        )
    }

    func testEvidenceAcceptsWordAndUtteranceUnitsAndOptionalActivity() throws {
        let fixture = try self.makeEvidenceFixture()
        let payload = self.evidence(
            fixture,
            units: [
                self.makeUnit(fixture, id: "w-0", precision: .word, analysisStart: 1, analysisEnd: 1.4),
                self.makeUnit(
                    fixture,
                    id: "utt-0",
                    precision: .utterance,
                    text: "a whole sentence",
                    analysisStart: 2,
                    analysisEnd: 6,
                    speaker: .unassigned,
                    confidence: 0.75
                ),
                self.makeUnit(
                    fixture,
                    id: "utt-1",
                    precision: .utterance,
                    text: "overlapped",
                    analysisStart: 6,
                    analysisEnd: 7,
                    speaker: .ambiguous([
                        MeetingBackendSpeakerToken(analysisEpochID: fixture.epoch, label: "slot-0"),
                        MeetingBackendSpeakerToken(analysisEpochID: fixture.epoch, label: "slot-1"),
                    ])
                ),
            ],
            activity: [
                MeetingBackendSpeakerActivity(
                    token: MeetingBackendSpeakerToken(analysisEpochID: fixture.epoch, label: "slot-0"),
                    start: 1,
                    end: 1.4
                ),
            ]
        )
        XCTAssertEqual(try payload.validated(against: fixture.plan), payload)
    }

    func testEvidenceRejectsUnitsWithoutDeclaredPrecisionSupport() throws {
        let fixture = try self.makeEvidenceFixture(precisions: [.utterance])
        let payload = self.evidence(fixture, units: [self.makeUnit(fixture, id: "w-0", precision: .word)])
        XCTAssertThrowsError(try payload.validated(against: fixture.plan)) { error in
            XCTAssertEqual(
                error as? MeetingBackendEvidenceError,
                .unsupportedPrecision(unitID: "w-0", precision: .word)
            )
        }
    }

    func testEvidenceScopeValidationAdmitsInvalidTimingForQuarantine() throws {
        // Scope validation answers "does this reference something planned?", not "is this timing
        // usable?". Impossible bounds are quarantined per unit at assembly time so every input
        // unit still receives exactly one sidecar disposition.
        let fixture = try self.makeEvidenceFixture()
        let invalidIntervals: [(TimeInterval, TimeInterval)] = [
            (.nan, 2),
            (1, .nan),
            (1, .infinity),
            (-1, 2),
            (2, 2),
            (3, 1),
        ]
        for (start, end) in invalidIntervals {
            let payload = self.evidence(fixture, units: [
                self.makeUnit(fixture, analysisStart: start, analysisEnd: end),
            ])
            XCTAssertNoThrow(
                try payload.validated(against: fixture.plan),
                "start=\(start) end=\(end) is a quarantine matter, not a scope error"
            )
        }
    }

    func testEvidenceRejectsDuplicateAndEmptyUnitIdentifiers() throws {
        let fixture = try self.makeEvidenceFixture()
        let duplicates = self.evidence(fixture, units: [
            self.makeUnit(fixture, id: "same", analysisStart: 1, analysisEnd: 2),
            self.makeUnit(fixture, id: "same", analysisStart: 3, analysisEnd: 4),
        ])
        XCTAssertThrowsError(try duplicates.validated(against: fixture.plan)) { error in
            XCTAssertEqual(error as? MeetingBackendEvidenceError, .duplicateUnitID("same"))
        }

        let empty = self.evidence(fixture, units: [self.makeUnit(fixture, id: "  ")])
        XCTAssertThrowsError(try empty.validated(against: fixture.plan)) { error in
            XCTAssertEqual(error as? MeetingBackendEvidenceError, .emptyUnitID)
        }
    }

    func testEvidenceRejectsSourcesOutsideThePlannedScope() throws {
        let fixture = try self.makeEvidenceFixture()

        let unknownTrack = self.evidence(fixture, units: [self.makeUnit(
            fixture, trackID: UUID(), epoch: fixture.epoch
        )])
        XCTAssertThrowsError(try unknownTrack.validated(against: fixture.plan)) { error in
            XCTAssertEqual(error as? MeetingBackendEvidenceError, .unknownSourceTrack(unitID: "u-0"))
        }

        let noSpans = self.evidence(fixture, units: [self.makeUnit(fixture, analysisSpanIDs: [])])
        XCTAssertThrowsError(try noSpans.validated(against: fixture.plan)) { error in
            XCTAssertEqual(error as? MeetingBackendEvidenceError, .missingAnalysisSpans(unitID: "u-0"))
        }

        let duplicateSpans = self.evidence(fixture, units: [self.makeUnit(
            fixture,
            analysisSpanIDs: ["span-0", "span-0"]
        )])
        XCTAssertThrowsError(try duplicateSpans.validated(against: fixture.plan)) { error in
            XCTAssertEqual(
                error as? MeetingBackendEvidenceError,
                .duplicateAnalysisSpanID(unitID: "u-0")
            )
        }

        // A microphone unit may not carry an epoch minted for the application track: the epoch is
        // what scopes speaker state, so crossing tracks here would silently merge identities.
        let foreignEpoch = self.evidence(fixture, units: [self.makeUnit(
            fixture,
            epoch: MeetingAnalysisEpochID(trackID: fixture.otherTrackID, ordinal: 0)
        )])
        XCTAssertThrowsError(try foreignEpoch.validated(against: fixture.plan)) { error in
            XCTAssertEqual(error as? MeetingBackendEvidenceError, .analysisEpochOutOfScope(unitID: "u-0"))
        }

        let negativeEpoch = self.evidence(fixture, units: [self.makeUnit(
            fixture,
            epoch: MeetingAnalysisEpochID(trackID: fixture.trackID, ordinal: -1),
            speaker: .unassigned
        )])
        XCTAssertThrowsError(try negativeEpoch.validated(against: fixture.plan)) { error in
            XCTAssertEqual(
                error as? MeetingBackendEvidenceError,
                .invalidAnalysisEpochOrdinal(unitID: "u-0")
            )
        }
    }

    func testEvidenceRejectsSpeakerTokensFromAnotherEpochOrTrack() throws {
        let fixture = try self.makeEvidenceFixture()

        let laterEpochToken = self.evidence(fixture, units: [self.makeUnit(
            fixture,
            speaker: .assigned(MeetingBackendSpeakerToken(
                analysisEpochID: MeetingAnalysisEpochID(trackID: fixture.trackID, ordinal: 1),
                label: "slot-0"
            ))
        )])
        XCTAssertThrowsError(try laterEpochToken.validated(against: fixture.plan)) { error in
            XCTAssertEqual(error as? MeetingBackendEvidenceError, .speakerTokenOutOfScope(unitID: "u-0"))
        }

        let crossTrackCandidate = self.evidence(fixture, units: [self.makeUnit(
            fixture,
            speaker: .ambiguous([
                MeetingBackendSpeakerToken(analysisEpochID: fixture.epoch, label: "slot-0"),
                MeetingBackendSpeakerToken(
                    analysisEpochID: MeetingAnalysisEpochID(trackID: fixture.otherTrackID, ordinal: 0),
                    label: "slot-0"
                ),
            ])
        )])
        XCTAssertThrowsError(try crossTrackCandidate.validated(against: fixture.plan)) { error in
            XCTAssertEqual(error as? MeetingBackendEvidenceError, .speakerTokenOutOfScope(unitID: "u-0"))
        }

        let singleCandidateAmbiguity = self.evidence(fixture, units: [self.makeUnit(
            fixture,
            speaker: .ambiguous([MeetingBackendSpeakerToken(analysisEpochID: fixture.epoch, label: "slot-0")])
        )])
        XCTAssertThrowsError(try singleCandidateAmbiguity.validated(against: fixture.plan)) { error in
            XCTAssertEqual(error as? MeetingBackendEvidenceError, .invalidAmbiguity(unitID: "u-0"))
        }

        let emptyTokenLabel = self.evidence(fixture, units: [self.makeUnit(
            fixture,
            speaker: .assigned(MeetingBackendSpeakerToken(
                analysisEpochID: fixture.epoch,
                label: "  "
            ))
        )])
        XCTAssertThrowsError(try emptyTokenLabel.validated(against: fixture.plan)) { error in
            XCTAssertEqual(
                error as? MeetingBackendEvidenceError,
                .emptySpeakerTokenLabel(unitID: "u-0")
            )
        }
    }

    func testEvidenceScopeAdmitsOutOfRangeConfidenceForQuarantine() throws {
        // An out-of-range confidence is a value defect, not a scope violation: it quarantines the
        // unit at assembly rather than failing the payload. Absent confidence stays fine.
        let fixture = try self.makeEvidenceFixture()
        for value in [Double.nan, -0.01, 1.01, .infinity] {
            let payload = self.evidence(fixture, units: [self.makeUnit(fixture, confidence: value)])
            XCTAssertNoThrow(try payload.validated(against: fixture.plan), "confidence=\(value)")
        }
        let absent = self.evidence(fixture, units: [self.makeUnit(fixture, confidence: nil)])
        XCTAssertNoThrow(try absent.validated(against: fixture.plan))
    }

    func testEvidenceRejectsMismatchedBackendOrAttemptAndBadActivity() throws {
        let fixture = try self.makeEvidenceFixture()
        let otherBackend = MeetingBackendID(rawValue: "someone-else")

        let wrongBackend = MeetingFinalTranscriptEvidence(
            backendID: otherBackend,
            attemptID: fixture.plan.attemptID,
            units: [self.makeUnit(fixture)]
        )
        XCTAssertThrowsError(try wrongBackend.validated(against: fixture.plan)) { error in
            XCTAssertEqual(
                error as? MeetingBackendEvidenceError,
                .backendMismatch(expected: fixture.plan.backendID, actual: otherBackend)
            )
        }

        let wrongAttempt = MeetingFinalTranscriptEvidence(
            backendID: fixture.plan.backendID,
            attemptID: UUID(),
            units: [self.makeUnit(fixture)]
        )
        XCTAssertThrowsError(try wrongAttempt.validated(against: fixture.plan)) { error in
            guard case .attemptMismatch = (error as? MeetingBackendEvidenceError) else {
                return XCTFail("expected attemptMismatch, got \(error)")
            }
        }

        let badActivity = self.evidence(
            fixture,
            units: [self.makeUnit(fixture)],
            activity: [MeetingBackendSpeakerActivity(
                token: MeetingBackendSpeakerToken(analysisEpochID: fixture.epoch, label: "slot-0"),
                start: 5,
                end: 5
            )]
        )
        XCTAssertThrowsError(try badActivity.validated(against: fixture.plan)) { error in
            XCTAssertEqual(error as? MeetingBackendEvidenceError, .invalidActivityTiming(index: 0))
        }

        let unplannedActivityTrack = self.evidence(
            fixture,
            units: [self.makeUnit(fixture)],
            activity: [MeetingBackendSpeakerActivity(
                token: MeetingBackendSpeakerToken(
                    analysisEpochID: MeetingAnalysisEpochID(trackID: UUID(), ordinal: 0),
                    label: "slot-0"
                ),
                start: 1,
                end: 2
            )]
        )
        XCTAssertThrowsError(try unplannedActivityTrack.validated(against: fixture.plan)) { error in
            XCTAssertEqual(error as? MeetingBackendEvidenceError, .activityTokenOutOfScope(index: 0))
        }

        let negativeActivityEpoch = self.evidence(
            fixture,
            units: [self.makeUnit(fixture)],
            activity: [MeetingBackendSpeakerActivity(
                token: MeetingBackendSpeakerToken(
                    analysisEpochID: MeetingAnalysisEpochID(trackID: fixture.trackID, ordinal: -1),
                    label: "slot-0"
                ),
                start: 1,
                end: 2
            )]
        )
        XCTAssertThrowsError(try negativeActivityEpoch.validated(against: fixture.plan)) { error in
            XCTAssertEqual(
                error as? MeetingBackendEvidenceError,
                .invalidActivityEpochOrdinal(index: 0)
            )
        }
    }
}

final class MeetingCalendarReminderPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func candidate(
        id: String = "event",
        startOffset: TimeInterval,
        duration: TimeInterval = 30 * 60,
        isAllDay: Bool = false,
        declined: Bool = false,
        links: [String] = ["https://meet.google.com/abc-defg-hij"]
    ) -> MeetingCalendarReminderCandidate {
        MeetingCalendarReminderCandidate(
            eventIdentifier: id,
            title: "Daily",
            start: self.now.addingTimeInterval(startOffset),
            end: self.now.addingTimeInterval(startOffset + duration),
            isAllDay: isAllDay,
            currentUserDeclined: declined,
            linkSources: links,
            attendees: []
        )
    }

    func testOffersACallStartingWithinTheLeadTimeOrRecentlyStarted() throws {
        let soon = try XCTUnwrap(MeetingCalendarReminderPolicy.dueReminder(among: [self.candidate(startOffset: 45)], at: self.now, alreadyOffered: []))
        XCTAssertEqual(soon.conferenceURL.absoluteString, "https://meet.google.com/abc-defg-hij")
        XCTAssertEqual(soon.serviceName, "Google Meet")
        XCTAssertTrue(soon.calendarMatch.matchedByConferenceLink)
        XCTAssertNotNil(MeetingCalendarReminderPolicy.dueReminder(among: [self.candidate(startOffset: -4 * 60)], at: self.now, alreadyOffered: []))
    }

    func testIgnoresCallsOutsideTheOfferWindow() {
        XCTAssertNil(MeetingCalendarReminderPolicy.dueReminder(among: [self.candidate(startOffset: 5 * 60)], at: self.now, alreadyOffered: []))
        XCTAssertNil(MeetingCalendarReminderPolicy.dueReminder(among: [self.candidate(startOffset: -6 * 60)], at: self.now, alreadyOffered: []))
        XCTAssertNil(
            MeetingCalendarReminderPolicy.dueReminder(among: [self.candidate(startOffset: -3 * 60, duration: 2 * 60)], at: self.now, alreadyOffered: []),
            "An event that already ended is never offered"
        )
    }

    func testIgnoresAllDayDeclinedAndLinklessEvents() {
        let events = [
            self.candidate(id: "all-day", startOffset: 30, isAllDay: true),
            self.candidate(id: "declined", startOffset: 30, declined: true),
            self.candidate(id: "no-link", startOffset: 30, links: ["Room 4", "https://calendar.google.com/event?eid=1"]),
        ]
        XCTAssertNil(MeetingCalendarReminderPolicy.dueReminder(among: events, at: self.now, alreadyOffered: []))
    }

    func testOffersEachOccurrenceOnceAndPrefersTheEarliest() throws {
        let early = self.candidate(id: "early", startOffset: -60)
        let later = self.candidate(id: "later", startOffset: 50)
        let first = try XCTUnwrap(MeetingCalendarReminderPolicy.dueReminder(among: [later, early], at: self.now, alreadyOffered: []))
        XCTAssertEqual(first.eventIdentifier, "early")
        let second = try XCTUnwrap(MeetingCalendarReminderPolicy.dueReminder(among: [later, early], at: self.now, alreadyOffered: [first.id]))
        XCTAssertEqual(second.eventIdentifier, "later")
    }

    func testFindsTheCallLinkInNotesAmongOtherLinks() {
        let notes = "Agenda: https://docs.google.com/document/d/1\nJoin Zoom Meeting\nhttps://us02web.zoom.us/j/123456789?pwd=abc\nDial in: +1 555"
        XCTAssertEqual(MeetingCalendarReminderPolicy.conferenceURL(in: ["", notes])?.host, "us02web.zoom.us")
        XCTAssertNil(MeetingCalendarReminderPolicy.conferenceURL(in: ["https://meet.google.com/landing"]))
    }

    func testDescribesTheStartRelativeToNow() {
        XCTAssertEqual(MeetingCalendarReminderPolicy.startDescription(start: self.now.addingTimeInterval(60), now: self.now), "Starts in 1 min")
        XCTAssertEqual(MeetingCalendarReminderPolicy.startDescription(start: self.now.addingTimeInterval(-180), now: self.now), "Started 3 min ago")
        XCTAssertEqual(MeetingCalendarReminderPolicy.startDescription(start: self.now.addingTimeInterval(10), now: self.now), "Starting now")
    }
}

final class MeetingUpcomingEventsPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }

    private func entry(
        id: String,
        title: String = "Daily",
        startOffset: TimeInterval,
        duration: TimeInterval = 30 * 60,
        isAllDay: Bool = false,
        declined: Bool = false,
        tentative: Bool = false,
        links: [String] = []
    ) -> (candidate: MeetingCalendarReminderCandidate, isTentative: Bool, color: MeetingUpcomingEvent.Color?) {
        (
            candidate: MeetingCalendarReminderCandidate(
                eventIdentifier: id,
                title: title,
                start: self.now.addingTimeInterval(startOffset),
                end: self.now.addingTimeInterval(startOffset + duration),
                isAllDay: isAllDay,
                currentUserDeclined: declined,
                linkSources: links,
                attendees: []
            ),
            isTentative: tentative,
            color: nil
        )
    }

    func testListsTimedEventsThatHaveNotEndedEarliestFirst() {
        let events = MeetingUpcomingEventsPolicy.upcoming(from: [
            self.entry(id: "later", startOffset: 3600),
            self.entry(id: "running", startOffset: -600),
            self.entry(id: "ended", startOffset: -3600),
            self.entry(id: "all-day", startOffset: 0, isAllDay: true),
            self.entry(id: "declined", startOffset: 600, declined: true),
            self.entry(id: "tentative", startOffset: 1800, tentative: true),
        ], at: self.now)
        XCTAssertEqual(events.map(\.title).count, 3)
        XCTAssertEqual(events.map { $0.id.components(separatedBy: "@")[0] }, ["running", "tentative", "later"])
        XCTAssertEqual(events.map(\.isTentative), [false, true, false])
    }

    func testOffersJoinOnlyForACallLinkAboutToStartOrRunning() throws {
        let events = MeetingUpcomingEventsPolicy.upcoming(from: [
            self.entry(id: "running", startOffset: -600, links: ["https://meet.google.com/abc-defg-hij"]),
            self.entry(id: "soon", startOffset: 4 * 60, links: ["https://zoom.us/j/123456789"]),
            self.entry(id: "later", startOffset: 3600, links: ["https://meet.google.com/xyz-abcd-efg"]),
            self.entry(id: "no-link", startOffset: -60, links: ["Room 4"]),
        ], at: self.now)
        let byID = Dictionary(uniqueKeysWithValues: events.map { ($0.id.components(separatedBy: "@")[0], $0) })
        XCTAssertTrue(MeetingUpcomingEventsPolicy.isJoinable(try XCTUnwrap(byID["running"]), at: self.now))
        XCTAssertTrue(MeetingUpcomingEventsPolicy.isJoinable(try XCTUnwrap(byID["soon"]), at: self.now))
        XCTAssertFalse(MeetingUpcomingEventsPolicy.isJoinable(try XCTUnwrap(byID["later"]), at: self.now))
        XCTAssertFalse(MeetingUpcomingEventsPolicy.isJoinable(try XCTUnwrap(byID["no-link"]), at: self.now))
        XCTAssertEqual(byID["soon"]?.reminder?.serviceName, "Zoom")
    }

    func testMatchesTheDetectedRoomToItsRunningEvent() {
        let events = MeetingUpcomingEventsPolicy.upcoming(from: [
            self.entry(id: "other", title: "AI", startOffset: -300, links: ["https://meet.google.com/zzz-zzzz-zzz"]),
            self.entry(id: "otc", title: "OTC Refinement", startOffset: -600, links: ["https://meet.google.com/abc-defg-hij?authuser=0"]),
            self.entry(id: "next", title: "OTC Refinement", startOffset: 7 * 24 * 3600 - 60, links: ["https://meet.google.com/abc-defg-hij"]),
        ], at: self.now)
        let match = MeetingUpcomingEventsPolicy.event(matchingConferenceFragment: "meet.google.com/abc-defg-hij", among: events, at: self.now)
        XCTAssertEqual(match?.title, "OTC Refinement")
        XCTAssertEqual(match?.id.components(separatedBy: "@")[0], "otc", "next week's occurrence of the same room is not the call running now")
        XCTAssertNil(MeetingUpcomingEventsPolicy.event(matchingConferenceFragment: nil, among: events, at: self.now))
        XCTAssertNil(MeetingUpcomingEventsPolicy.event(matchingConferenceFragment: "meet.google.com/qqq-qqqq-qqq", among: events, at: self.now))
    }

    func testRowLabelsNameTheDayTimeDurationAndCall() throws {
        let locale = Locale(identifier: "en_US")
        let startOfToday = self.calendar.startOfDay(for: self.now)
        func event(at date: Date, minutes: Double = 30, reminder: MeetingCalendarReminder? = nil, tentative: Bool = false) -> MeetingUpcomingEvent {
            MeetingUpcomingEvent(
                id: "e",
                title: "E",
                start: date,
                end: date.addingTimeInterval(minutes * 60),
                isTentative: tentative,
                calendarColor: nil,
                reminder: reminder,
                searchableText: ""
            )
        }
        let laterToday = self.now.addingTimeInterval(3600)
        XCTAssertEqual(MeetingUpcomingEventsPolicy.dayLabel(for: event(at: laterToday), at: self.now, calendar: self.calendar, locale: locale), "Today")
        let tomorrow = try XCTUnwrap(self.calendar.date(byAdding: .day, value: 1, to: startOfToday)).addingTimeInterval(9.5 * 3600)
        XCTAssertEqual(MeetingUpcomingEventsPolicy.dayLabel(for: event(at: tomorrow), at: self.now, calendar: self.calendar, locale: locale), "Tomorrow")
        XCTAssertEqual(
            MeetingUpcomingEventsPolicy.startTime(for: event(at: tomorrow), calendar: self.calendar, locale: locale)
                .replacingOccurrences(of: "\u{202F}", with: " "),
            "9:30 AM"
        )
        let inThreeDays = try XCTUnwrap(self.calendar.date(byAdding: .day, value: 3, to: startOfToday)).addingTimeInterval(14 * 3600)
        XCTAssertEqual(MeetingUpcomingEventsPolicy.dayLabel(for: event(at: inThreeDays), at: self.now, calendar: self.calendar, locale: locale), "Mon")

        XCTAssertEqual(MeetingUpcomingEventsPolicy.durationLabel(for: event(at: laterToday, minutes: 30)), "30 min")
        XCTAssertEqual(MeetingUpcomingEventsPolicy.durationLabel(for: event(at: laterToday, minutes: 60)), "1 h")
        XCTAssertEqual(MeetingUpcomingEventsPolicy.durationLabel(for: event(at: laterToday, minutes: 75)), "1 h 15 min")

        let call = MeetingCalendarReminder(
            id: "e",
            eventIdentifier: "e",
            title: "E",
            start: laterToday,
            end: laterToday.addingTimeInterval(1800),
            conferenceURL: try XCTUnwrap(URL(string: "https://meet.google.com/abc-defg-hij")),
            serviceName: "Google Meet",
            attendees: [
                MeetingCalendarAttendee(name: "Ana", email: "ana@example.com", isOrganizer: true),
                MeetingCalendarAttendee(name: "Paul", email: "paul@example.com", isOrganizer: false),
            ]
        )
        XCTAssertEqual(
            MeetingUpcomingEventsPolicy.detailParts(for: event(at: laterToday, reminder: call, tentative: true)),
            ["30 min", "Google Meet", "2 people", "Not accepted yet"]
        )
        XCTAssertEqual(MeetingUpcomingEventsPolicy.detailParts(for: event(at: laterToday)), ["30 min"])

        XCTAssertEqual(MeetingUpcomingEventsPolicy.joinStatus(for: event(at: self.now.addingTimeInterval(200)), at: self.now), "In 4 min")
        XCTAssertEqual(MeetingUpcomingEventsPolicy.joinStatus(for: event(at: self.now.addingTimeInterval(-60)), at: self.now), "Now")
    }
}

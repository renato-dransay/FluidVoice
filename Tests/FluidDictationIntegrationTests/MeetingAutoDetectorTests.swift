@testable import FluidVoice_Debug
import Foundation
import XCTest

// MARK: - Fakes (protocols only — no CoreAudio/AX/NSWorkspace)

@MainActor
private final class FakeClock: MeetingClockProviding {
    var current: Date
    init(_ date: Date = Date(timeIntervalSince1970: 1_700_000_000)) { self.current = date }
    func now() -> Date { self.current }
}

@MainActor
private final class FakeWorkspaceEvents: WorkspaceEventsProviding {
    var onEvent: ((WorkspaceEvent) -> Void)?
    var frontmostProcessID: Int32?
    func start(isRegistryApp: @escaping (String) -> Bool, onBackfill: @escaping ([WorkspaceEvent]) -> Void) {}
    func stop() {}
}

@MainActor
private final class FakeMicActivity: MicActivitySignalProviding {
    var onEdge: ((MicActivityEdge) -> Void)?
    func start() {}
    func stop() {}
}

@MainActor
private final class FakeAudioProcessActivity: AudioProcessActivityProviding {
    var activeBundleIdentifiers: Set<String> = []
    /// Bundles whose helper plays audio but has no microphone input running.
    var outputOnlyBundleIdentifiers: Set<String> = []
    var snapshotOverride: AudioProcessActivitySnapshot?
    var snapshotCount = 0
    var beforeSnapshot: (() -> Void)?

    func snapshot() async -> AudioProcessActivitySnapshot {
        self.snapshotCount += 1
        self.beforeSnapshot?()
        if let snapshotOverride { return snapshotOverride }
        let processes = self.activeBundleIdentifiers.map { bundle in
            let owner = bundle == "us.zoom.caphost" ? "us.zoom.xos" : bundle
            return AudioProcessDescriptor(
                processID: 55,
                bundleIdentifier: bundle,
                executablePath: "/Applications/\(owner).app/Contents/Helpers/\(bundle)",
                isInputRunning: bundle != "us.zoom.caphost" && !self.outputOnlyBundleIdentifiers.contains(bundle),
                isOutputRunning: true
            )
        }
        let owners = self.activeBundleIdentifiers.map { bundle in
            let owner = bundle == "us.zoom.caphost" ? "us.zoom.xos" : bundle
            return MeetingProcessOwner(
                processID: 5,
                bundleIdentifier: owner,
                bundlePath: "/Applications/\(owner).app"
            )
        }
        return AudioProcessActivitySnapshot(processes: processes, owners: owners, queryState: .valid)
    }
}

@MainActor
private final class FakeWindowSnapshotProvider: WindowSnapshotProviding {
    var axTitles: [String] = []
    func snapshot(interestPIDs: Set<Int32>) -> [WindowSnapshot] { [] }
    func titles(processID: Int32) async -> [String] { self.axTitles }
}

@MainActor
private final class FakeBrowserTabReader: BrowserTabReading {
    var url: BrowserTabURL?
    var meetingName: String?
    var meetingNameReads = 0
    func frontmostTabURL(bundleIdentifier: String, processID: Int32) async -> BrowserTabURL? { self.url }
    func frontmostMeetingName(bundleIdentifier: String, processID: Int32) async -> String? {
        self.meetingNameReads += 1
        return self.meetingName
    }
}

@MainActor
private final class FakeActivityGate: DetectionActivityGate {
    var isIdle = true
    var preflightResult = true
    func preflightPasses() -> Bool { self.preflightResult }
}

/// Plain reference box so the detector's enablement closures don't need to capture `self` while
/// `DetectorHarness` is still mid-initialization.
@MainActor
private final class ToggleFlags {
    var nativeEnabled = true
    var browserEnabled = true
    /// Conference fragments a calendar event scheduled right now links to.
    var scheduledFragments: Set<String> = []
    var calendarLookups: [String] = []
}

@MainActor
private final class DetectorHarness {
    let clock = FakeClock()
    let gate = FakeActivityGate()
    let flags = ToggleFlags()
    let audioProcessActivity = FakeAudioProcessActivity()
    let windowProvider = FakeWindowSnapshotProvider()
    let browserReader = FakeBrowserTabReader()
    let workspace = FakeWorkspaceEvents()
    var prompts: [MeetingAutoDetector.PromptRequest] = []
    var nudges = 0
    var invalidated: [UUID] = []
    let detector: MeetingAutoDetector

    var nativeEnabled: Bool {
        get { self.flags.nativeEnabled }
        set { self.flags.nativeEnabled = newValue }
    }

    var browserEnabled: Bool {
        get { self.flags.browserEnabled }
        set { self.flags.browserEnabled = newValue }
    }

    init() {
        let flags = self.flags
        self.detector = MeetingAutoDetector(
            workspaceEvents: self.workspace,
            micActivity: FakeMicActivity(),
            audioProcessActivity: self.audioProcessActivity,
            windowSnapshotProvider: self.windowProvider,
            browserTabReader: self.browserReader,
            activityGate: self.gate,
            clock: self.clock,
            isNativeDetectionEnabled: { flags.nativeEnabled },
            isBrowserDetectionEnabled: { flags.browserEnabled },
            isScheduledInCalendar: { fragment, _ in
                flags.calendarLookups.append(fragment)
                return flags.scheduledFragments.contains(fragment)
            }
        )
        self.detector.onPromptRequested = { [weak self] request in self?.prompts.append(request) }
        self.detector.onStillRecordingNudge = { [weak self] in self?.nudges += 1 }
        self.detector.onEpisodeInvalidated = { [weak self] episodeID in self?.invalidated.append(episodeID) }
    }

    func advance(_ seconds: TimeInterval) {
        self.clock.current.addTimeInterval(seconds)
    }

    /// Arms + fronts a native app, then confirms it with a matching window and a coincident mic edge.
    @discardableResult
    func confirmZoom(pid: Int32 = 100) -> UUID? {
        self.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "us.zoom.xos", processID: pid), at: self.clock.now())
        self.detector.handleWindowSnapshot(
            [.init(processID: pid, windowID: 900, title: "Zoom Meeting", layer: 0)],
            at: self.clock.now()
        )
        self.detector.handleMicEdge(.init(isActive: true), at: self.clock.now())
        return self.prompts.last?.episodeID
    }
}

@MainActor
final class MeetingAutoDetectorTests: XCTestCase {
    func testAutomaticSourcePublishesConfirmedTargetWithoutConsumingPrompt() throws {
        let h = DetectorHarness()
        var changes: [MeetingAutoDetector.ResolvedTarget?] = []
        h.detector.onAutomaticTargetChanged = { changes.append($0) }
        XCTAssertNil(h.detector.automaticTarget)
        let episode = try XCTUnwrap(h.confirmZoom())
        XCTAssertEqual(h.detector.automaticTarget?.bundleIdentifier, "us.zoom.xos")
        XCTAssertEqual(h.detector.automaticTarget?.pid, 100)
        XCTAssertEqual(h.detector.automaticTarget?.windowID, 900)
        XCTAssertTrue(h.detector.canStart(episodeID: episode), "Selecting a source must not consume or start a recording")
        let count = changes.count
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(changes.count, count, "Unchanged evidence must not trigger source refreshes")
        h.detector.timeoutDismissed(episodeID: episode)
        XCTAssertNotNil(h.detector.automaticTarget, "Prompt timeout must not hide a live source from the manual page")
        h.detector.handleWindowSnapshot([], at: h.clock.now())
        XCTAssertNil(h.detector.automaticTarget, "Do not retain a source through the episode's teardown grace period")
    }

    func testAutomaticSourceClearsWhenDetectionDisabledOrStopped() {
        let h = DetectorHarness()
        h.confirmZoom()
        XCTAssertNotNil(h.detector.automaticTarget)
        h.nativeEnabled = false
        h.detector.tick(at: h.clock.now())
        XCTAssertNil(h.detector.automaticTarget)
        h.nativeEnabled = true
        h.detector.tick(at: h.clock.now())
        XCTAssertNotNil(h.detector.automaticTarget)
        h.detector.stop()
        XCTAssertNil(h.detector.automaticTarget)
    }

    func testAutomaticSourceDoesNotGuessBetweenTwoLiveMeetings() {
        let h = DetectorHarness()
        h.confirmZoom(pid: 100)
        h.confirmZoom(pid: 200)
        h.detector.handleWindowSnapshot([
            .init(processID: 100, windowID: 900, title: "Zoom Meeting", layer: 0),
            .init(processID: 200, windowID: 900, title: "Zoom Meeting", layer: 0),
        ], at: h.clock.now())
        XCTAssertNil(h.detector.automaticTarget)
        h.detector.handleWorkspaceEvent(.init(kind: .terminated, bundleIdentifier: "us.zoom.xos", processID: 200), at: h.clock.now())
        XCTAssertEqual(h.detector.automaticTarget?.pid, 100)
        h.detector.disarmAndClearTransientState()
        XCTAssertNil(h.detector.automaticTarget)
    }

    // MARK: - Generic HAL ownership resolver

    func testAudioResolverMapsHelpersInsideEachRegisteredNativeBundle() {
        let apps = [
            ("com.microsoft.teams2", "/Applications/Microsoft Teams.app"),
            ("com.microsoft.teams", "/Applications/Classic Teams.app"),
            ("us.zoom.xos", "/Applications/zoom.us.app"),
            ("com.cisco.webexmeetingsapp", "/Applications/Webex.app"),
            ("Cisco-Systems.Spark", "/Applications/Webex New.app"),
        ]
        for (bundle, root) in apps {
            let result = MeetingAudioProcessResolver.activeOwnerInputByPID(snapshot: .init(
                processes: [.init(
                    processID: 900,
                    bundleIdentifier: "helper.unknown",
                    executablePath: root + "/Contents/Helpers/Module.app/Contents/MacOS/Module",
                    isInputRunning: true,
                    isOutputRunning: false
                )],
                owners: [.init(processID: 42, bundleIdentifier: bundle, bundlePath: root)],
                queryState: .valid
            ))
            XCTAssertEqual(result?[42], true, "helper attribution should work for \(bundle)")
        }
    }

    func testAudioResolverRejectsPrefixSpoofRelativeMissingAndAmbiguousOwners() {
        // nil requests the fixture default; an empty collection tests explicitly missing data.
        // swiftlint:disable:next discouraged_optional_collection
        func resolve(_ processPath: String?, owners: [MeetingProcessOwner]) -> [Int32: Bool]? {
            MeetingAudioProcessResolver.activeOwnerInputByPID(snapshot: .init(
                processes: [.init(processID: 1, bundleIdentifier: nil, executablePath: processPath, isInputRunning: true, isOutputRunning: false)],
                owners: owners,
                queryState: .valid
            ))
        }
        let owner = MeetingProcessOwner(processID: 10, bundleIdentifier: "com.microsoft.teams2", bundlePath: "/Applications/Teams.app")
        XCTAssertEqual(resolve("/Applications/Teams.app.evil/Contents/MacOS/x", owners: [owner]), [:])
        XCTAssertNil(resolve(nil, owners: [owner]))
        XCTAssertNil(resolve("Applications/Teams.app/Contents/MacOS/x", owners: [owner]))
        XCTAssertNil(resolve(
            "/Applications/Teams.app/Contents/MacOS/x",
            owners: [owner, .init(processID: 11, bundleIdentifier: "com.microsoft.teams2", bundlePath: "/Applications/Teams.app")]
        ))
        XCTAssertEqual(
            resolve("/Applications/Teams.app/Contents/MacOS/x", owners: [.init(processID: 10, bundleIdentifier: "com.tinyspeck.slackmacgap", bundlePath: "/Applications/Teams.app")]),
            [:],
            "apps outside the registry never become audio owners"
        )
        XCTAssertEqual(
            resolve("/Applications/Teams.app/Contents/MacOS/x", owners: [.init(processID: 10, bundleIdentifier: "com.microsoft.teams2", bundlePath: "relative/Teams.app")]),
            [:]
        )
    }

    func testAudioResolverAcceptsBrowserOwnerAndRejectsUnknownQuery() {
        let browser = MeetingProcessOwner(processID: 3, bundleIdentifier: "com.google.Chrome", bundlePath: "/Applications/Chrome.app")
        let process = AudioProcessDescriptor(
            processID: 4,
            bundleIdentifier: nil,
            executablePath: "/Applications/Chrome.app/Contents/MacOS/Chrome",
            isInputRunning: true,
            isOutputRunning: true
        )
        XCTAssertNil(MeetingAudioProcessResolver.activeOwnerInputByPID(snapshot: .init(processes: [process], owners: [browser], queryState: .unknown)))
        XCTAssertEqual(
            MeetingAudioProcessResolver.activeOwnerInputByPID(snapshot: .init(processes: [process], owners: [browser], queryState: .valid)),
            [3: true],
            "a browser's own audio helper is attributable input evidence"
        )
    }

    // MARK: - Recording titles: calendar, app-exposed name, service, app

    func testRecordingTitleLayers() {
        XCTAssertEqual(MeetingRecordingTitle.resolve(mode: .onlineCall, calendarTitle: "Weekly sync", exposedTitle: "Other", serviceName: "Google Meet", applicationDisplayName: "Vivaldi"), "Weekly sync")
        XCTAssertEqual(MeetingRecordingTitle.resolve(mode: .onlineCall, calendarTitle: " ", exposedTitle: "Design review", serviceName: "Google Meet", applicationDisplayName: "Vivaldi"), "Design review")
        XCTAssertEqual(MeetingRecordingTitle.resolve(mode: .onlineCall, calendarTitle: nil, exposedTitle: nil, serviceName: "Google Meet", applicationDisplayName: "Vivaldi"), "Google Meet call")
        XCTAssertEqual(MeetingRecordingTitle.resolve(mode: .onlineCall, calendarTitle: nil, exposedTitle: nil, serviceName: nil, applicationDisplayName: "Vivaldi"), "Vivaldi call")
        XCTAssertEqual(MeetingRecordingTitle.resolve(mode: .onlineCall, calendarTitle: nil, exposedTitle: nil, serviceName: nil, applicationDisplayName: nil), "Meeting")
        XCTAssertEqual(MeetingRecordingTitle.resolve(mode: .inRoom, calendarTitle: "Weekly sync", exposedTitle: nil, serviceName: nil, applicationDisplayName: nil), "In-room meeting")
    }

    func testExposedTitleMatcherReadsTeamsMeetingNamesOnly() {
        XCTAssertEqual(MeetingExposedTitleMatcher.meetingName(fromWindowTitle: "Weekly sync | Microsoft Teams"), "Weekly sync")
        XCTAssertEqual(MeetingExposedTitleMatcher.meetingName(fromWindowTitle: "Design review - Microsoft Teams"), "Design review")
        for title in ["Chat | Microsoft Teams", "Calendar | Microsoft Teams", "Microsoft Teams", "Zoom Meeting", "Meet – abc-defg-hij - Vivaldi", ""] {
            XCTAssertNil(MeetingExposedTitleMatcher.meetingName(fromWindowTitle: title), title)
        }
    }

    func testMeetHeadingAcceptanceRejectsRoomCodesAndLabels() {
        XCTAssertEqual(AXBrowserTabReader.acceptedMeetHeading("  Weekly sync "), "Weekly sync")
        for text in ["abc-defg-hij", "Google Meet", "Ready to join?", "Meeting details", "", "x"] {
            XCTAssertNil(AXBrowserTabReader.acceptedMeetHeading(text), text)
        }
    }

    func testResolvedTargetCarriesServiceFragmentAndTeamsWindowName() throws {
        let h = DetectorHarness()
        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "com.microsoft.teams2", processID: 5), at: h.clock.now())
        h.detector.handleWindowSnapshot([.init(processID: 5, windowID: 42, title: "Weekly sync | Microsoft Teams", layer: 0)], at: h.clock.now())
        h.detector.handleMicEdge(.init(isActive: true), at: h.clock.now())
        let teams = try XCTUnwrap(h.prompts.first)
        let teamsTarget = try XCTUnwrap(h.detector.resolvedTarget(for: teams.episodeID))
        XCTAssertEqual(teamsTarget.exposedTitle, "Weekly sync")
        XCTAssertNil(teamsTarget.serviceName)
        XCTAssertNil(teamsTarget.conferenceFragment)

        let meet = DetectorHarness()
        meet.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "com.vivaldi.Vivaldi", processID: 9), at: meet.clock.now())
        meet.detector.handleBrowserTabURL(.init(host: "meet.google.com", path: "/abc-defg-hij"), pid: 9, bundleIdentifier: "com.vivaldi.Vivaldi", at: meet.clock.now())
        meet.detector.handleMicEdge(.init(isActive: true), at: meet.clock.now())
        let meetTarget = try XCTUnwrap(meet.detector.automaticTarget)
        XCTAssertEqual(meetTarget.serviceName, "Google Meet")
        XCTAssertEqual(meetTarget.conferenceFragment, "meet.google.com/abc-defg-hij")
        XCTAssertNil(meetTarget.exposedTitle)
    }

    func testMeetPageHeadingBecomesExposedTitleOnceAndResetsWithRoom() async throws {
        let h = DetectorHarness()
        h.browserReader.url = .init(host: "meet.google.com", path: "/abc-defg-hij")
        h.browserReader.meetingName = "Weekly sync"
        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "com.vivaldi.Vivaldi", processID: 9), at: h.clock.now())
        await h.detector.pollBrowserTabs(at: h.clock.now())
        h.detector.handleMicEdge(.init(isActive: true), at: h.clock.now())
        let target = try XCTUnwrap(h.detector.automaticTarget)
        XCTAssertEqual(target.exposedTitle, "Weekly sync")
        XCTAssertEqual(h.browserReader.meetingNameReads, 1)

        h.advance(30)
        await h.detector.pollBrowserTabs(at: h.clock.now())
        XCTAssertEqual(h.browserReader.meetingNameReads, 1, "a known name is not re-read")

        h.browserReader.url = .init(host: "meet.google.com", path: "/xyz-wxyz-xyz")
        h.browserReader.meetingName = nil
        h.advance(30)
        await h.detector.pollBrowserTabs(at: h.clock.now())
        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "com.vivaldi.Vivaldi", processID: 9), at: h.clock.now())
        h.detector.handleMicEdge(.init(isActive: true), at: h.clock.now())
        XCTAssertEqual(h.prompts.count, 2, "a new room is a new episode")
        XCTAssertNil(h.detector.resolvedTarget(for: h.prompts[1].episodeID)?.exposedTitle, "the old room's name must not leak into the new room")
        XCTAssertEqual(h.browserReader.meetingNameReads, 2)
    }

    // MARK: - Browser audio evidence from process input (no device edge, e.g. Bluetooth headsets)

    func testBrowserProcessInputConfirmsWithoutDeviceEdge() async {
        let h = DetectorHarness()
        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "com.vivaldi.Vivaldi", processID: 5), at: h.clock.now())
        h.detector.handleWindowSnapshot([.init(processID: 5, windowID: 1, title: "Meet – abc-defg-hij - Vivaldi", layer: 0)], at: h.clock.now())
        XCTAssertTrue(h.prompts.isEmpty)
        h.audioProcessActivity.activeBundleIdentifiers = ["com.vivaldi.Vivaldi"]
        await h.detector.pollAudioProcessActivity(at: h.clock.now())
        XCTAssertEqual(h.prompts.count, 1)
        XCTAssertEqual(h.prompts.first?.serviceName, "Google Meet")
    }

    func testBrowserOutputOnlyProcessAudioNeverConfirms() async {
        let h = DetectorHarness()
        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "com.vivaldi.Vivaldi", processID: 5), at: h.clock.now())
        h.detector.handleWindowSnapshot([.init(processID: 5, windowID: 1, title: "Meet – abc-defg-hij - Vivaldi", layer: 0)], at: h.clock.now())
        h.audioProcessActivity.activeBundleIdentifiers = ["com.vivaldi.Vivaldi"]
        h.audioProcessActivity.outputOnlyBundleIdentifiers = ["com.vivaldi.Vivaldi"]
        await h.detector.pollAudioProcessActivity(at: h.clock.now())
        XCTAssertTrue(h.prompts.isEmpty, "a browser playing media is not a meeting")
    }

    func testWebAppConfirmsFromHostBrowserProcessInput() async throws {
        let h = DetectorHarness()
        let shim = "com.vivaldi.Vivaldi.app.kjgfgldnnfoeklkmfkjfagphfepbbdan"
        h.detector.handleBackfill([.init(kind: .launched, bundleIdentifier: "com.vivaldi.Vivaldi", processID: 5)])
        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: shim, processID: 41), at: h.clock.now())
        h.detector.handleWindowSnapshot([.init(processID: 41, windowID: 3, title: "Meet – abc-defg-hij", layer: 0)], at: h.clock.now())
        h.audioProcessActivity.activeBundleIdentifiers = ["com.vivaldi.Vivaldi"]
        await h.detector.pollAudioProcessActivity(at: h.clock.now())
        let prompt = try XCTUnwrap(h.prompts.first)
        XCTAssertEqual(prompt.bundleIdentifier, shim)
        XCTAssertEqual(h.detector.resolvedTarget(for: prompt.episodeID)?.bundleIdentifier, "com.vivaldi.Vivaldi")
    }

    func testBackfilledBrowserInFrontWhenProcessInputBeginsConfirms() async {
        let h = DetectorHarness()
        h.workspace.frontmostProcessID = 5
        h.detector.handleBackfill([.init(kind: .launched, bundleIdentifier: "com.vivaldi.Vivaldi", processID: 5)])
        h.detector.handleWindowSnapshot([.init(processID: 5, windowID: 1, title: "Meet – abc-defg-hij", layer: 0)], at: h.clock.now())
        h.audioProcessActivity.activeBundleIdentifiers = ["com.vivaldi.Vivaldi"]
        await h.detector.pollAudioProcessActivity(at: h.clock.now())
        XCTAssertEqual(h.prompts.count, 1, "in front when the browser's microphone opens is frontmost evidence")

        let background = DetectorHarness()
        background.workspace.frontmostProcessID = 99
        background.detector.handleBackfill([.init(kind: .launched, bundleIdentifier: "com.vivaldi.Vivaldi", processID: 5)])
        background.detector.handleWindowSnapshot([.init(processID: 5, windowID: 1, title: "Meet – abc-defg-hij", layer: 0)], at: background.clock.now())
        background.audioProcessActivity.activeBundleIdentifiers = ["com.vivaldi.Vivaldi"]
        await background.detector.pollAudioProcessActivity(at: background.clock.now())
        XCTAssertTrue(background.prompts.isEmpty, "a background browser never confirms")
    }

    func testBackgroundBrowserCallConfirmsWhenCalendarSchedulesThatRoomNow() async {
        let h = DetectorHarness()
        h.workspace.frontmostProcessID = 99
        h.flags.scheduledFragments = ["meet.google.com/abc-defg-hij"]
        h.detector.handleBackfill([.init(kind: .launched, bundleIdentifier: "com.vivaldi.Vivaldi", processID: 5)])
        h.audioProcessActivity.activeBundleIdentifiers = ["com.vivaldi.Vivaldi"]
        await h.detector.pollAudioProcessActivity(at: h.clock.now())
        h.browserReader.url = .init(host: "meet.google.com", path: "/abc-defg-hij")
        await h.detector.pollBrowserTabs(at: h.clock.now())
        XCTAssertEqual(h.prompts.count, 1, "a calendar event linking to the live room stands in for frontmost evidence")
        XCTAssertEqual(h.detector.automaticTarget?.bundleIdentifier, "com.vivaldi.Vivaldi")
        XCTAssertEqual(h.detector.automaticTarget?.conferenceFragment, "meet.google.com/abc-defg-hij")
    }

    func testBackgroundBrowserCallWithoutMatchingCalendarEventDoesNotConfirm() async {
        let h = DetectorHarness()
        h.workspace.frontmostProcessID = 99
        h.flags.scheduledFragments = ["meet.google.com/zzz-zzzz-zzz"]
        h.detector.handleBackfill([.init(kind: .launched, bundleIdentifier: "com.vivaldi.Vivaldi", processID: 5)])
        h.audioProcessActivity.activeBundleIdentifiers = ["com.vivaldi.Vivaldi"]
        await h.detector.pollAudioProcessActivity(at: h.clock.now())
        h.browserReader.url = .init(host: "meet.google.com", path: "/abc-defg-hij")
        await h.detector.pollBrowserTabs(at: h.clock.now())
        XCTAssertTrue(h.prompts.isEmpty, "another room on the calendar never corroborates this one")
        XCTAssertEqual(h.flags.calendarLookups, ["meet.google.com/abc-defg-hij"])

        h.advance(2)
        await h.detector.pollAudioProcessActivity(at: h.clock.now())
        await h.detector.pollBrowserTabs(at: h.clock.now())
        XCTAssertEqual(h.flags.calendarLookups.count, 1, "a miss is not re-queried on every poll")
    }

    func testBackgroundBrowserWithoutMicrophoneSkipsCalendarLookup() async {
        let h = DetectorHarness()
        h.workspace.frontmostProcessID = 99
        h.flags.scheduledFragments = ["meet.google.com/abc-defg-hij"]
        h.detector.handleBackfill([.init(kind: .launched, bundleIdentifier: "com.vivaldi.Vivaldi", processID: 5)])
        h.browserReader.url = .init(host: "meet.google.com", path: "/abc-defg-hij")
        await h.detector.pollBrowserTabs(at: h.clock.now())
        XCTAssertTrue(h.prompts.isEmpty, "a scheduled room open without a live microphone is not a call")
        XCTAssertTrue(h.flags.calendarLookups.isEmpty)
    }

    func testBrowserProcessInputEndingEndsEpisode() async {
        let h = DetectorHarness()
        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "com.vivaldi.Vivaldi", processID: 5), at: h.clock.now())
        h.detector.handleWindowSnapshot([.init(processID: 5, windowID: 1, title: "Meet – abc-defg-hij", layer: 0)], at: h.clock.now())
        h.audioProcessActivity.activeBundleIdentifiers = ["com.vivaldi.Vivaldi"]
        await h.detector.pollAudioProcessActivity(at: h.clock.now())
        XCTAssertEqual(h.prompts.count, 1)
        h.audioProcessActivity.activeBundleIdentifiers = []
        await h.detector.pollAudioProcessActivity(at: h.clock.now())
        h.advance(61)
        await h.detector.pollAudioProcessActivity(at: h.clock.now())
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.invalidated, [h.prompts[0].episodeID])
    }

    func testBrowserProcessInputRequiresBrowserToggle() async {
        let h = DetectorHarness()
        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "com.vivaldi.Vivaldi", processID: 5), at: h.clock.now())
        h.detector.handleWindowSnapshot([.init(processID: 5, windowID: 1, title: "Meet – abc-defg-hij", layer: 0)], at: h.clock.now())
        h.browserEnabled = false
        h.audioProcessActivity.activeBundleIdentifiers = ["com.vivaldi.Vivaldi"]
        await h.detector.pollAudioProcessActivity(at: h.clock.now())
        XCTAssertTrue(h.prompts.isEmpty)
    }

    func testAudioResolverRejectsSymlinkEscapingBundle() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("meeting-resolver-\(UUID().uuidString)")
        let app = root.appendingPathComponent("Teams.app")
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data().write(to: outside.appendingPathComponent("Module"))
        let link = app.appendingPathComponent("Contents")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        defer { try? FileManager.default.removeItem(at: root) }
        let result = MeetingAudioProcessResolver.activeOwnerInputByPID(snapshot: .init(
            processes: [.init(processID: 1, bundleIdentifier: nil, executablePath: link.path + "/Module", isInputRunning: true, isOutputRunning: false)],
            owners: [.init(processID: 2, bundleIdentifier: "com.microsoft.teams2", bundlePath: app.path)],
            queryState: .valid
        ))
        XCTAssertEqual(result, [:])
    }

    func testGenericOutputOnlyHelperDoesNotCreateNewPrompt() async {
        let h = DetectorHarness()
        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "com.microsoft.teams2", processID: 5), at: h.clock.now())
        h.detector.handleWindowSnapshot([.init(processID: 5, windowID: 9, title: nil, layer: 0)], at: h.clock.now())
        h.audioProcessActivity.snapshotOverride = .init(
            processes: [.init(
                processID: 55,
                bundleIdentifier: "teams.helper",
                executablePath: "/Applications/com.microsoft.teams2.app/Contents/Helpers/Module",
                isInputRunning: false,
                isOutputRunning: true
            )],
            owners: [.init(processID: 5, bundleIdentifier: "com.microsoft.teams2", bundlePath: "/Applications/com.microsoft.teams2.app")],
            queryState: .valid
        )
        await h.detector.pollAudioProcessActivity(at: h.clock.now())
        XCTAssertTrue(h.prompts.isEmpty)
    }

    func testNativePollTakesOneSnapshot() async {
        let h = DetectorHarness()
        h.detector.handleWorkspaceEvent(.init(kind: .launched, bundleIdentifier: "com.microsoft.teams2", processID: 5), at: h.clock.now())
        h.detector.handleWorkspaceEvent(.init(kind: .launched, bundleIdentifier: "us.zoom.xos", processID: 6), at: h.clock.now())
        h.audioProcessActivity.snapshotOverride = .init(processes: [], owners: [], queryState: .valid)
        await h.detector.pollAudioProcessActivity(at: h.clock.now())
        XCTAssertEqual(h.audioProcessActivity.snapshotCount, 1)
    }

    func testSnapshotCannotApplyToReusedPIDAfterTermination() async {
        let h = DetectorHarness()
        h.detector.handleWorkspaceEvent(.init(kind: .launched, bundleIdentifier: "com.microsoft.teams2", processID: 5), at: h.clock.now())
        h.audioProcessActivity.snapshotOverride = .init(
            processes: [.init(
                processID: 55,
                bundleIdentifier: "teams.helper",
                executablePath: "/Applications/Teams.app/Contents/Helpers/Module",
                isInputRunning: true,
                isOutputRunning: true
            )],
            owners: [.init(processID: 5, bundleIdentifier: "com.microsoft.teams2", bundlePath: "/Applications/Teams.app")],
            queryState: .valid
        )
        h.audioProcessActivity.beforeSnapshot = {
            h.detector.handleWorkspaceEvent(.init(kind: .terminated, bundleIdentifier: "com.microsoft.teams2", processID: 5), at: h.clock.now())
            h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "com.microsoft.teams2", processID: 5), at: h.clock.now())
            h.detector.handleWindowSnapshot([.init(processID: 5, windowID: 7, title: nil, layer: 0)], at: h.clock.now())
        }
        await h.detector.pollAudioProcessActivity(at: h.clock.now())
        XCTAssertTrue(h.prompts.isEmpty)
    }

    func testUnknownAudioQueryCannotCreateNativePrompt() async {
        let h = DetectorHarness()
        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "com.microsoft.teams2", processID: 5), at: h.clock.now())
        h.detector.handleAudioProcessActivity(true, pid: 5, at: h.clock.now())
        h.audioProcessActivity.snapshotOverride = .init(processes: [], owners: [], queryState: .unknown)
        await h.detector.pollAudioProcessActivity(at: h.clock.now())
        h.detector.handleWindowSnapshot([.init(processID: 5, windowID: 1, title: nil, layer: 0)], at: h.clock.now())
        XCTAssertTrue(h.prompts.isEmpty)
    }

    func testUnknownQueryResetsContinuousInactivityAndPreservesEpisode() async {
        let h = DetectorHarness()
        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "us.zoom.xos", processID: 5), at: h.clock.now())
        h.detector.handleWindowSnapshot([.init(processID: 5, windowID: 1, title: "Zoom", layer: 0)], at: h.clock.now())
        h.detector.handleAudioProcessActivity(true, pid: 5, at: h.clock.now())
        XCTAssertEqual(h.prompts.count, 1)
        h.detector.handleAudioProcessActivity(false, pid: 5, at: h.clock.now())
        h.detector.handleMicEdge(.init(isActive: false), at: h.clock.now())
        h.advance(30)
        h.audioProcessActivity.snapshotOverride = .init(processes: [], owners: [], queryState: .unknown)
        await h.detector.pollAudioProcessActivity(at: h.clock.now())
        h.advance(70)
        h.detector.tick(at: h.clock.now())
        XCTAssertTrue(h.invalidated.isEmpty)
        h.audioProcessActivity.snapshotOverride = .init(processes: [], owners: [], queryState: .valid)
        await h.detector.pollAudioProcessActivity(at: h.clock.now())
        h.detector.tick(at: h.clock.now())
        XCTAssertTrue(h.invalidated.isEmpty)
        h.advance(61)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.invalidated, [h.prompts[0].episodeID])
    }

    func testUnknownNativeSnapshotDoesNotBlockBrowserURLDetection() async {
        let h = DetectorHarness()
        h.audioProcessActivity.snapshotOverride = .init(processes: [], owners: [], queryState: .unknown)
        await h.detector.pollAudioProcessActivity(at: h.clock.now())
        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "com.google.Chrome", processID: 8), at: h.clock.now())
        h.detector.handleMicEdge(.init(isActive: true), at: h.clock.now())
        h.detector.handleBrowserTabURL(.init(host: "meet.google.com", path: "/abc-defg-hij"), pid: 8, bundleIdentifier: "com.google.Chrome", at: h.clock.now())
        XCTAssertEqual(h.prompts.count, 1)
        XCTAssertEqual(h.prompts.first?.tier, .browserTier2)
    }

    func testLiveAudioProcessOwnershipProbe() async throws {
        guard ProcessInfo.processInfo.environment["FV_DETECTOR_LIVE_PROBE"] == "1" else {
            throw XCTSkip("Opt-in read-only live Core Audio ownership probe")
        }
        let snapshot = await CoreAudioProcessActivityProvider().snapshot()
        XCTAssertEqual(snapshot.queryState, .valid)
        let result = try XCTUnwrap(MeetingAudioProcessResolver.activeOwnerInputByPID(snapshot: snapshot))
        for owner in snapshot.owners {
            print("FV_DETECTOR_PROBE owner=\(owner.bundleIdentifier) pid=\(owner.processID) active=\(result[owner.processID] != nil) input=\(result[owner.processID] == true)")
        }
        for process in snapshot.processes where process.bundleIdentifier?.contains("teams") == true {
            print("FV_DETECTOR_PROBE process=\(process.bundleIdentifier ?? "unknown") pid=\(process.processID) input=\(process.isInputRunning) output=\(process.isOutputRunning)")
            if process.isInputRunning {
                let owner = try XCTUnwrap(snapshot.owners.first { $0.bundleIdentifier == "com.microsoft.teams2" })
                XCTAssertEqual(result[owner.processID], true)
            }
        }
    }

    func testActiveBeforeForegroundCanRecoverAfterStaleWindowDeadline() {
        let h = DetectorHarness()
        h.detector.handleWorkspaceEvent(.init(kind: .launched, bundleIdentifier: "com.microsoft.teams2", processID: 5), at: h.clock.now())
        h.detector.handleAudioProcessActivity(true, pid: 5, at: h.clock.now())
        h.advance(31)
        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "com.microsoft.teams2", processID: 5), at: h.clock.now())
        h.detector.handleWindowSnapshot([.init(processID: 5, windowID: 2, title: nil, layer: 0)], at: h.clock.now())
        h.detector.handleAudioProcessActivity(true, pid: 5, at: h.clock.now())
        XCTAssertEqual(h.prompts.count, 1)
    }

    func testUnrelatedMicReleaseDoesNotEndProcessConfirmedEpisode() {
        let h = DetectorHarness()
        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "us.zoom.xos", processID: 5), at: h.clock.now())
        h.detector.handleWindowSnapshot([.init(processID: 5, windowID: 3, title: "Zoom", layer: 0)], at: h.clock.now())
        h.detector.handleAudioProcessActivity(true, pid: 5, at: h.clock.now())
        XCTAssertEqual(h.prompts.count, 1)
        h.detector.handleMicEdge(.init(isActive: false), at: h.clock.now())
        h.advance(61)
        h.detector.tick(at: h.clock.now())
        h.detector.handleAudioProcessActivity(true, pid: 5, at: h.clock.now())
        XCTAssertEqual(h.prompts.count, 1)
    }

    // MARK: - Prompt suppression

    func testPromptSuppressionAllowsDetectedMeetingAppFullScreen() {
        let reason = MeetingDetectionPromptController.suppressionReason(
            frontmostBundleIdentifier: "us.zoom.xos",
            isFrontmostFullScreen: true,
            isDictationOverlayPresented: false,
            requestBundleIdentifier: "us.zoom.xos"
        )
        XCTAssertNil(reason)
    }

    func testPromptSuppressionBlocksDifferentFullScreenAppAndDictationOverlay() {
        let fullScreenReason = MeetingDetectionPromptController.suppressionReason(
            frontmostBundleIdentifier: "com.apple.iWork.Keynote",
            isFrontmostFullScreen: true,
            isDictationOverlayPresented: false,
            requestBundleIdentifier: "us.zoom.xos"
        )
        XCTAssertEqual(fullScreenReason, .fullscreenOtherApp)

        let overlayReason = MeetingDetectionPromptController.suppressionReason(
            frontmostBundleIdentifier: "us.zoom.xos",
            isFrontmostFullScreen: true,
            isDictationOverlayPresented: true,
            requestBundleIdentifier: "us.zoom.xos"
        )
        XCTAssertEqual(overlayReason, .dictationOverlay)
    }

    func testPromptAutoDismissRemainingTimeClampsElapsedTime() {
        XCTAssertEqual(MeetingDetectionPromptController.remainingAutoDismissSeconds(20, after: 7.5), 12.5)
        XCTAssertEqual(MeetingDetectionPromptController.remainingAutoDismissSeconds(2, after: 4), 0)
        XCTAssertEqual(MeetingDetectionPromptController.remainingAutoDismissSeconds(2, after: -1), 2)
    }

    func testPromptDefaultsToTopCenterOfVisibleFrame() {
        let visibleFrame = NSRect(x: 100, y: 50, width: 1200, height: 800)
        let frame = MeetingDetectionPromptController.defaultFrame(
            panelSize: MeetingDetectionPromptController.panelSize,
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(frame.midX, visibleFrame.midX)
        XCTAssertEqual(frame.maxY, visibleFrame.maxY - 12)
        XCTAssertEqual(frame.size, MeetingDetectionPromptController.panelSize)
    }

    func testSuppressedReminderRetriesThenTimesOutWithinBudget() {
        XCTAssertEqual(
            MeetingDetectionPromptController.reminderPresentationDecision(remainingBudget: 20, isSuppressed: false),
            .present
        )
        XCTAssertEqual(
            MeetingDetectionPromptController.reminderPresentationDecision(remainingBudget: 20, isSuppressed: true),
            .retryAfter(MeetingDetectionPromptController.suppressionRetryInterval)
        )
        XCTAssertEqual(
            MeetingDetectionPromptController.reminderPresentationDecision(remainingBudget: 0.2, isSuppressed: true),
            .retryAfter(0.2)
        )
        XCTAssertEqual(
            MeetingDetectionPromptController.reminderPresentationDecision(remainingBudget: 0, isSuppressed: true),
            .timeout
        )
        XCTAssertEqual(
            MeetingDetectionPromptController.reminderPresentationDecision(remainingBudget: 0, isSuppressed: false),
            .timeout
        )
    }

    func testReplacingPromptTimesOutThePreviousEpisodeOnly() {
        let first = UUID()
        let second = UUID()
        XCTAssertEqual(
            MeetingDetectionPromptController.episodeToTimeoutOnReplacement(existing: first, incoming: second),
            first
        )
        XCTAssertNil(MeetingDetectionPromptController.episodeToTimeoutOnReplacement(existing: first, incoming: first))
        XCTAssertNil(MeetingDetectionPromptController.episodeToTimeoutOnReplacement(existing: nil, incoming: second))
    }

    func testCheapSuppressionDecisionShortCircuitsAX() {
        XCTAssertEqual(
            MeetingDetectionPromptController.cheapSuppressionDecision(
                frontmostBundleIdentifier: "us.zoom.xos",
                frontmostProcessIdentifier: 100,
                isDictationOverlayPresented: true,
                requestBundleIdentifier: "us.zoom.xos"
            ),
            .suppressed(.dictationOverlay)
        )
        XCTAssertEqual(
            MeetingDetectionPromptController.cheapSuppressionDecision(
                frontmostBundleIdentifier: "us.zoom.xos",
                frontmostProcessIdentifier: 100,
                isDictationOverlayPresented: false,
                requestBundleIdentifier: "us.zoom.xos"
            ),
            .presentNow
        )
        XCTAssertEqual(
            MeetingDetectionPromptController.cheapSuppressionDecision(
                frontmostBundleIdentifier: "com.apple.iWork.Keynote",
                frontmostProcessIdentifier: 200,
                isDictationOverlayPresented: false,
                requestBundleIdentifier: "us.zoom.xos"
            ),
            .queryFullscreen(200)
        )
        XCTAssertEqual(
            MeetingDetectionPromptController.cheapSuppressionDecision(
                frontmostBundleIdentifier: nil,
                frontmostProcessIdentifier: nil,
                isDictationOverlayPresented: false,
                requestBundleIdentifier: "us.zoom.xos"
            ),
            .presentNow
        )
    }

    func testSilentInvalidationOnlyMatchesVisibleOrPendingPrompt() {
        let visible = UUID()
        let pending = UUID()
        let other = UUID()
        XCTAssertTrue(
            MeetingDetectionPromptController.shouldSilentlyInvalidatePrompt(
                episodeID: visible,
                visibleEpisodeID: visible,
                pendingEpisodeID: pending
            )
        )
        XCTAssertTrue(
            MeetingDetectionPromptController.shouldSilentlyInvalidatePrompt(
                episodeID: pending,
                visibleEpisodeID: visible,
                pendingEpisodeID: pending
            )
        )
        XCTAssertFalse(
            MeetingDetectionPromptController.shouldSilentlyInvalidatePrompt(
                episodeID: other,
                visibleEpisodeID: visible,
                pendingEpisodeID: pending
            )
        )
    }

    func testStartErrorMessageSurfacesCaptureAndPreflightFailures() {
        XCTAssertEqual(
            MeetingDetectionPromptController.startErrorMessage(
                from: MeetingCaptureError.applicationUnavailable("us.zoom.xos"),
                appDisplayName: "Zoom"
            ),
            "Zoom is no longer available to record."
        )
        XCTAssertEqual(
            MeetingDetectionPromptController.startErrorMessage(
                from: MeetingAutoDetector.StartError.cannotStart,
                appDisplayName: "Zoom"
            ),
            "Can't start recording right now."
        )
        XCTAssertEqual(
            MeetingDetectionPromptController.startErrorMessage(
                from: MeetingCaptureError.microphonePermissionDenied,
                appDisplayName: "Zoom"
            ),
            "Microphone permission is required to record this meeting."
        )
    }

    func testCaptureTargetFailsClosedWhenPreferredAppIsRequiredAndMissing() {
        let chrome = MeetingApplicationIdentity(bundleIdentifier: "com.google.Chrome", displayName: "Chrome")
        let zoom = MeetingApplicationIdentity(bundleIdentifier: "us.zoom.xos", displayName: "Zoom")

        XCTAssertEqual(
            try MeetingCaptureSourceCatalog.resolveApplication(
                from: [chrome, zoom],
                preferredBundleIdentifier: "us.zoom.xos",
                requirePreferredApplication: true
            ).bundleIdentifier,
            "us.zoom.xos"
        )

        XCTAssertThrowsError(
            try MeetingCaptureSourceCatalog.resolveApplication(
                from: [chrome],
                preferredBundleIdentifier: "us.zoom.xos",
                requirePreferredApplication: true
            )
        ) { error in
            guard let captureError = error as? MeetingCaptureError,
                  case .applicationUnavailable("us.zoom.xos") = captureError
            else {
                return XCTFail("expected applicationUnavailable, got \(error)")
            }
        }

        XCTAssertEqual(
            try MeetingCaptureSourceCatalog.resolveApplication(
                from: [chrome],
                preferredBundleIdentifier: "us.zoom.xos",
                requirePreferredApplication: false
            ).bundleIdentifier,
            "com.google.Chrome",
            "manual/default setup may still fall back when the preferred app is absent"
        )

        XCTAssertEqual(
            try MeetingCaptureSourceCatalog.resolveApplication(
                from: [chrome],
                preferredBundleIdentifier: nil,
                requirePreferredApplication: false
            ).bundleIdentifier,
            "com.google.Chrome"
        )
    }

    // MARK: - Coincidence window

    func testParkedTabWithLateMicNeverPrompts() {
        let h = DetectorHarness()
        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "com.google.Chrome", processID: 1), at: h.clock.now())
        h.detector.handleBrowserTabURL(.init(host: "meet.google.com", path: "/abc-defg-hij"), pid: 1, bundleIdentifier: "com.google.Chrome", at: h.clock.now())

        h.advance(40) // evidence is now stale relative to the coincidence window
        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "com.google.Chrome", processID: 1), at: h.clock.now())
        h.detector.handleMicEdge(.init(isActive: true), at: h.clock.now())

        XCTAssertTrue(h.prompts.isEmpty, "evidence older than the 30s coincidence window must not confirm")
    }

    // MARK: - Fail-closed on unreadable AXURL

    func testUnreadableAXURLNeverPrompts() {
        let h = DetectorHarness()
        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "com.google.Chrome", processID: 1), at: h.clock.now())
        h.detector.handleBrowserTabURL(nil, pid: 1, bundleIdentifier: "com.google.Chrome", at: h.clock.now())
        h.detector.handleMicEdge(.init(isActive: true), at: h.clock.now())
        XCTAssertTrue(h.prompts.isEmpty)
    }

    // MARK: - YouTube-hostname never matches

    func testYouTubeNeverMatchesInCallURL() {
        XCTAssertFalse(MeetingInCallURLMatcher.isInCallURL(host: "www.youtube.com", path: "/watch"))
        XCTAssertFalse(MeetingInCallURLMatcher.isInCallURL(host: "youtube.com", path: "/live/abc-defg-hij"))
    }

    // MARK: - Tier-1 frontmost-at-edge gate

    func testZoomConfirmsOnlyWhenFrontmostNearTheMicEdge() {
        let h = DetectorHarness()
        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "us.zoom.xos", processID: 5), at: h.clock.now())
        h.detector.handleWindowSnapshot(
            [.init(processID: 5, windowID: 42, title: "Zoom Meeting", layer: 0)],
            at: h.clock.now()
        )
        h.advance(20) // beyond the 15s frontmost lead
        h.detector.handleMicEdge(.init(isActive: true), at: h.clock.now())
        XCTAssertTrue(h.prompts.isEmpty, "stale frontmost must not confirm")

        let h2 = DetectorHarness()
        XCTAssertNotNil(h2.confirmZoom(), "frontmost within the lead window must confirm")
    }

    func testZoomNonMeetingWindowTitlesNeverConfirm() {
        for title in ["Zoom Workplace", "Zoom Client Healthcheck", ""] {
            let h = DetectorHarness()
            h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "us.zoom.xos", processID: 5), at: h.clock.now())
            h.detector.handleWindowSnapshot(
                [.init(processID: 5, windowID: 42, title: title, layer: 0)],
                at: h.clock.now()
            )
            h.detector.handleMicEdge(.init(isActive: true), at: h.clock.now())
            XCTAssertTrue(h.prompts.isEmpty, "\(title) must not count as meeting evidence")
        }
    }

    func testZoomTitleConfirmsWithAudioAndWindowEvidence() {
        let h = DetectorHarness()
        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "us.zoom.xos", processID: 5), at: h.clock.now())
        h.detector.handleWindowSnapshot(
            [.init(processID: 5, windowID: 42, title: "Zoom", layer: 0)],
            at: h.clock.now()
        )
        h.detector.handleMicEdge(.init(isActive: true), at: h.clock.now())
        XCTAssertEqual(h.prompts.count, 1)
    }

    func testProcessAudioConfirmsMutedZoomJoinWithoutDeviceMicEdge() async {
        let h = DetectorHarness()
        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "us.zoom.xos", processID: 5), at: h.clock.now())
        h.detector.handleWindowSnapshot(
            [.init(processID: 5, windowID: 42, title: "Zoom", layer: 0)],
            at: h.clock.now()
        )
        h.audioProcessActivity.activeBundleIdentifiers = ["us.zoom.caphost"]
        await h.detector.pollAudioProcessActivity(at: h.clock.now())
        XCTAssertEqual(h.prompts.count, 1)
    }

    func testAudioEvidenceAloneNeverPromptsAndWindowEvidenceAloneNeverPrompts() {
        let audioOnly = DetectorHarness()
        audioOnly.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "us.zoom.xos", processID: 5), at: audioOnly.clock.now())
        audioOnly.detector.handleAudioProcessActivity(true, pid: 5, at: audioOnly.clock.now())
        XCTAssertTrue(audioOnly.prompts.isEmpty)

        let windowOnly = DetectorHarness()
        windowOnly.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "us.zoom.xos", processID: 5), at: windowOnly.clock.now())
        windowOnly.detector.handleWindowSnapshot(
            [.init(processID: 5, windowID: 42, title: "Zoom", layer: 0)],
            at: windowOnly.clock.now()
        )
        XCTAssertTrue(windowOnly.prompts.isEmpty)
    }

    // MARK: - Backfill arms only

    func testBackfillAlonesNeverConfirms() {
        let h = DetectorHarness()
        h.detector.handleBackfill([.init(kind: .launched, bundleIdentifier: "us.zoom.xos", processID: 7)])
        h.detector.handleWindowSnapshot(
            [.init(processID: 7, windowID: 1, title: "Zoom Meeting", layer: 0)],
            at: h.clock.now()
        )
        h.detector.handleMicEdge(.init(isActive: true), at: h.clock.now())
        XCTAssertTrue(h.prompts.isEmpty, "backfill seeds no frontmost timestamp, so it can never confirm by itself")
    }

    func testBackfilledBrowserInFrontAtMicEdgeConfirms() {
        let h = DetectorHarness()
        h.browserEnabled = true
        h.workspace.frontmostProcessID = 8
        h.detector.handleBackfill([.init(kind: .launched, bundleIdentifier: "com.google.Chrome", processID: 8)])
        h.detector.handleBrowserTabURL(.init(host: "meet.google.com", path: "/abc-defg-hij"), pid: 8, bundleIdentifier: "com.google.Chrome", at: h.clock.now())
        h.detector.handleMicEdge(.init(isActive: true), at: h.clock.now())
        XCTAssertEqual(h.prompts.count, 1, "a browser already in front when the mic opens is frontmost evidence; the in-call URL still gates it")
        XCTAssertEqual(h.prompts.first?.serviceName, "Google Meet")
    }

    func testBackfilledBrowserInFrontWithoutInCallURLDoesNotConfirm() {
        let h = DetectorHarness()
        h.browserEnabled = true
        h.workspace.frontmostProcessID = 8
        h.detector.handleBackfill([.init(kind: .launched, bundleIdentifier: "com.google.Chrome", processID: 8)])
        h.detector.handleBrowserTabURL(.init(host: "meet.google.com", path: "/landing"), pid: 8, bundleIdentifier: "com.google.Chrome", at: h.clock.now())
        h.detector.handleMicEdge(.init(isActive: true), at: h.clock.now())
        XCTAssertTrue(h.prompts.isEmpty, "frontmost-now never substitutes for window evidence")
    }

    func testBackfilledNativeAppInFrontAtMicEdgeStillNeedsActivation() {
        let h = DetectorHarness()
        h.workspace.frontmostProcessID = 7
        h.detector.handleBackfill([.init(kind: .launched, bundleIdentifier: "us.zoom.xos", processID: 7)])
        h.detector.handleWindowSnapshot(
            [.init(processID: 7, windowID: 1, title: "Zoom Meeting", layer: 0)],
            at: h.clock.now()
        )
        h.detector.handleMicEdge(.init(isActive: true), at: h.clock.now())
        XCTAssertTrue(h.prompts.isEmpty, "native apps keep the activation rule; their windows persist all day")
    }

    // MARK: - Episode dedup + back-to-back re-arm

    func testDuplicateConfirmDoesNotReprompt() {
        let h = DetectorHarness()
        h.confirmZoom()
        XCTAssertEqual(h.prompts.count, 1)
        h.detector.handleMicEdge(.init(isActive: true), at: h.clock.now())
        XCTAssertEqual(h.prompts.count, 1, "the same window key must not re-arm while still live")
    }

    func testBackToBackMeetingAfterReleaseRearmsTheSameWindow() throws {
        let h = DetectorHarness()
        let firstEpisode = h.confirmZoom()
        XCTAssertNotNil(firstEpisode)
        h.detector.timeoutDismissed(episodeID: try XCTUnwrap(firstEpisode))

        // Window disappears; after grace + the 60s release window the episode is evicted.
        h.detector.handleWindowSnapshot([], at: h.clock.now())
        h.advance(70)
        h.detector.tick(at: h.clock.now())

        // A fresh meeting on the same window number re-arms.
        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "us.zoom.xos", processID: 100), at: h.clock.now())
        h.detector.handleWindowSnapshot(
            [.init(processID: 100, windowID: 900, title: "Zoom Meeting", layer: 0)],
            at: h.clock.now()
        )
        h.detector.handleMicEdge(.init(isActive: true), at: h.clock.now())
        XCTAssertEqual(h.prompts.count, 2, "a genuinely new meeting must re-arm after the old episode ends")
    }

    func testTeamsBackToBackRearmsViaMicReleaseDespitePersistentWindow() {
        // Teams' main window never closes, so window loss can't end the episode — mic release must.
        let h = DetectorHarness()
        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "com.microsoft.teams2", processID: 300), at: h.clock.now())
        h.detector.handleWindowSnapshot([.init(processID: 300, windowID: 950, title: nil, layer: 0)], at: h.clock.now())
        h.detector.handleMicEdge(.init(isActive: true), at: h.clock.now())
        XCTAssertEqual(h.prompts.count, 1)
        h.detector.timeoutDismissed(episodeID: h.prompts[0].episodeID)

        h.detector.handleMicEdge(.init(isActive: false), at: h.clock.now())
        h.advance(70)
        h.detector.tick(at: h.clock.now())

        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "com.microsoft.teams2", processID: 300), at: h.clock.now())
        h.detector.handleWindowSnapshot([.init(processID: 300, windowID: 950, title: nil, layer: 0)], at: h.clock.now())
        h.detector.handleMicEdge(.init(isActive: true), at: h.clock.now())
        XCTAssertEqual(h.prompts.count, 2, "a second Teams meeting after mic release must re-prompt even though the main window persisted")
    }

    func testProcessAudioInactiveForSixtySecondsEndsEpisodeAndReprompts() {
        let h = DetectorHarness()
        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "us.zoom.xos", processID: 100), at: h.clock.now())
        h.detector.handleWindowSnapshot(
            [.init(processID: 100, windowID: 900, title: "Zoom", layer: 0)],
            at: h.clock.now()
        )
        h.detector.handleAudioProcessActivity(true, pid: 100, at: h.clock.now())
        XCTAssertEqual(h.prompts.count, 1)
        h.detector.timeoutDismissed(episodeID: h.prompts[0].episodeID)

        h.detector.handleAudioProcessActivity(false, pid: 100, at: h.clock.now())
        h.advance(70)
        h.detector.tick(at: h.clock.now())

        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "us.zoom.xos", processID: 100), at: h.clock.now())
        h.detector.handleWindowSnapshot(
            [.init(processID: 100, windowID: 900, title: "Zoom", layer: 0)],
            at: h.clock.now()
        )
        h.detector.handleAudioProcessActivity(true, pid: 100, at: h.clock.now())
        XCTAssertEqual(h.prompts.count, 2)
    }

    // MARK: - Stop mid-call, no re-prompt

    func testStoppingOurRecordingMidCallDoesNotReprompt() throws {
        let h = DetectorHarness()
        let episodeID = try XCTUnwrap(h.confirmZoom())
        XCTAssertTrue(h.detector.startTapped(episodeID: episodeID))

        // The window is still there (the user is still in the call) — no eviction, no re-prompt.
        h.detector.handleWindowSnapshot(
            [.init(processID: 100, windowID: 900, title: "Zoom Meeting", layer: 0)],
            at: h.clock.now()
        )
        h.advance(70)
        h.detector.tick(at: h.clock.now())
        h.detector.handleMicEdge(.init(isActive: true), at: h.clock.now())
        XCTAssertEqual(h.prompts.count, 1, "stopping our own recording must not retire a still-live episode")
    }

    // MARK: - Manual start consumes the episode

    func testStartTappedIsSingleShot() throws {
        let h = DetectorHarness()
        let episodeID = try XCTUnwrap(h.confirmZoom())
        XCTAssertTrue(h.detector.startTapped(episodeID: episodeID))
        XCTAssertFalse(h.detector.startTapped(episodeID: episodeID), "a second Start on the same episode must be a no-op")
    }

    func testStartTappedFailsWhenPreflightNoLongerPasses() throws {
        let h = DetectorHarness()
        let episodeID = try XCTUnwrap(h.confirmZoom())
        h.gate.preflightResult = false
        XCTAssertFalse(h.detector.startTapped(episodeID: episodeID))
    }

    func testCanStartDoesNotConsumeEpisode() throws {
        let h = DetectorHarness()
        let episodeID = try XCTUnwrap(h.confirmZoom())
        XCTAssertTrue(h.detector.canStart(episodeID: episodeID))
        XCTAssertTrue(h.detector.canStart(episodeID: episodeID), "canStart must not consume")
        XCTAssertTrue(h.detector.startTapped(episodeID: episodeID))
        XCTAssertFalse(h.detector.canStart(episodeID: episodeID))
    }

    func testAdoptStartedEpisodeSkipsPreflightAndStartTappedStaysSingleShot() throws {
        let h = DetectorHarness()
        let episodeID = try XCTUnwrap(h.confirmZoom())
        h.gate.preflightResult = false
        XCTAssertFalse(h.detector.startTapped(episodeID: episodeID))
        h.detector.adoptStartedEpisode(episodeID: episodeID)
        XCTAssertFalse(h.detector.canStart(episodeID: episodeID))
        XCTAssertFalse(h.detector.startTapped(episodeID: episodeID))
        h.detector.adoptStartedEpisode(episodeID: episodeID)
    }

    func testAdoptStartedEpisodeAfterTimeoutOwnsTheEpisodeAndResetsDismissals() throws {
        let h = DetectorHarness()
        var suggested = false
        h.detector.onSuggestDisablingAutoDetect = { suggested = true }

        for pid: Int32 in [1, 2] {
            let episodeID = try XCTUnwrap(h.confirmZoom(pid: pid))
            h.detector.dismissTapped(episodeID: episodeID, at: h.clock.now())
            h.advance(3600)
        }

        let timedOut = try XCTUnwrap(h.confirmZoom(pid: 3))
        h.detector.timeoutDismissed(episodeID: timedOut)
        XCTAssertFalse(h.detector.startTapped(episodeID: timedOut))
        XCTAssertFalse(h.detector.canStart(episodeID: timedOut))
        h.detector.adoptStartedEpisode(episodeID: timedOut)

        h.detector.handleWindowSnapshot([], at: h.clock.now())
        h.advance(65)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.nudges, 1, "adopting after timeout must still arm the still-recording nudge")

        let dismissedEpisode = try XCTUnwrap(h.confirmZoom(pid: 4))
        h.detector.dismissTapped(episodeID: dismissedEpisode, at: h.clock.now())
        XCTAssertFalse(suggested, "adopting after timeout must still reset the rolling counter")
    }

    // MARK: - Preflight gate silence

    func testMissingScreenRecordingAtConfirmRequestsSetup() {
        let h = DetectorHarness()
        h.gate.preflightResult = false
        h.confirmZoom()
        XCTAssertEqual(h.prompts.count, 1)
        XCTAssertEqual(h.prompts.first?.cta, .setup)
    }

    func testBusyEvidenceStaysSilentThenPromptsWhenIdle() {
        let h = DetectorHarness()
        h.gate.isIdle = false
        h.confirmZoom()
        XCTAssertTrue(h.prompts.isEmpty)
        h.gate.isIdle = true
        h.detector.handleWindowSnapshot(
            [.init(processID: 100, windowID: 900, title: "Zoom Meeting", layer: 0)],
            at: h.clock.now()
        )
        XCTAssertEqual(h.prompts.count, 1)
        XCTAssertEqual(h.prompts.first?.cta, .record)
    }

    func testRedactedZoomUsesAXMeetingTitleEvenWhenWorkplaceComesFirst() async {
        let h = DetectorHarness()
        h.windowProvider.axTitles = ["Zoom Workplace", "Zoom Meeting"]
        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "us.zoom.xos", processID: 100), at: h.clock.now())
        h.detector.handleWindowSnapshot([.init(processID: 100, windowID: 900, title: nil, layer: 0)], at: h.clock.now())
        h.detector.handleMicEdge(.init(isActive: true), at: h.clock.now())
        await Task.yield()
        XCTAssertEqual(h.prompts.count, 1)
        XCTAssertEqual(h.prompts.first?.cta, .record)
    }

    func testRedactedZoomWithoutAXTitlesDedupesUnreadableHealth() async {
        let h = DetectorHarness()
        var health: [MeetingAutoDetector.Health] = []
        h.detector.onHealthChanged = { health.append($0) }
        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "us.zoom.xos", processID: 100), at: h.clock.now())
        let redacted: [WindowSnapshot] = [.init(processID: 100, windowID: 900, title: nil, layer: 0)]
        h.detector.handleWindowSnapshot(redacted, at: h.clock.now())
        h.detector.handleWindowSnapshot(redacted, at: h.clock.now())
        await Task.yield()
        XCTAssertEqual(health, [.zoomWindowTitleUnreadable])
        XCTAssertTrue(h.prompts.isEmpty)
    }

    func testRedactedZoomWithOnlyWorkplaceIsReadableButDoesNotPrompt() async {
        let h = DetectorHarness()
        h.windowProvider.axTitles = ["Zoom Workplace"]
        var health: [MeetingAutoDetector.Health] = []
        h.detector.onHealthChanged = { health.append($0) }
        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "us.zoom.xos", processID: 100), at: h.clock.now())
        h.detector.handleWindowSnapshot([.init(processID: 100, windowID: 900, title: nil, layer: 0)], at: h.clock.now())
        await Task.yield()
        XCTAssertEqual(health, [.ready])
        XCTAssertTrue(h.prompts.isEmpty)
    }

    func testPrimaryActionSetupNeverRoutesToRecording() {
        XCTAssertEqual(
            MeetingDetectionPromptController.primaryAction(for: .setup),
            .openSetup
        )
        XCTAssertEqual(
            MeetingDetectionPromptController.primaryAction(for: .record),
            .startRecording
        )
    }

    func testTeamsNilWindowTitleStillPrompts() {
        let h = DetectorHarness()
        h.detector.handleWorkspaceEvent(
            .init(kind: .activated, bundleIdentifier: "com.microsoft.teams2", processID: 100),
            at: h.clock.now()
        )
        h.detector.handleWindowSnapshot(
            [.init(processID: 100, windowID: 901, title: nil, layer: 0)],
            at: h.clock.now()
        )
        h.detector.handleMicEdge(.init(isActive: true), at: h.clock.now())
        XCTAssertEqual(h.prompts.count, 1)
        XCTAssertEqual(h.prompts.first?.cta, .record)
    }

    // MARK: - Dismissal suppression + rolling counter

    func testExplicitDismissSuppressesTheBundleForThirtyMinutes() throws {
        let h = DetectorHarness()
        let firstEpisode = try XCTUnwrap(h.confirmZoom(pid: 1))
        h.detector.dismissTapped(episodeID: firstEpisode, at: h.clock.now())

        h.detector.handleWindowSnapshot([], at: h.clock.now()) // window loss + eviction so the same window can re-arm
        h.advance(70)
        h.detector.tick(at: h.clock.now())

        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "us.zoom.xos", processID: 1), at: h.clock.now())
        h.detector.handleWindowSnapshot(
            [.init(processID: 1, windowID: 900, title: "Zoom Meeting", layer: 0)],
            at: h.clock.now()
        )
        h.detector.handleMicEdge(.init(isActive: true), at: h.clock.now())
        XCTAssertEqual(h.prompts.count, 1, "the bundle stays suppressed for 30 minutes after an explicit dismiss")
    }

    func testTimeoutDismissDoesNotSuppressOrCount() throws {
        let h = DetectorHarness()
        let episodeID = try XCTUnwrap(h.confirmZoom())
        h.detector.timeoutDismissed(episodeID: episodeID)

        h.detector.handleWindowSnapshot([], at: h.clock.now())
        h.advance(70)
        h.detector.tick(at: h.clock.now())

        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "us.zoom.xos", processID: 100), at: h.clock.now())
        h.detector.handleWindowSnapshot(
            [.init(processID: 100, windowID: 900, title: "Zoom Meeting", layer: 0)],
            at: h.clock.now()
        )
        h.detector.handleMicEdge(.init(isActive: true), at: h.clock.now())
        XCTAssertEqual(h.prompts.count, 2, "a 20s auto-dismiss must not suppress the bundle")
    }

    func testThreeDismissalsWithinFourteenDaysSuggestsDisabling() throws {
        let h = DetectorHarness()
        var suggested = false
        h.detector.onSuggestDisablingAutoDetect = { suggested = true }

        for pid: Int32 in [1, 2, 3] {
            let episodeID = try XCTUnwrap(h.confirmZoom(pid: pid))
            h.detector.dismissTapped(episodeID: episodeID, at: h.clock.now())
            h.advance(3600)
        }
        XCTAssertTrue(suggested)
    }

    func testAcceptedStartResetsTheDismissalCounter() throws {
        let h = DetectorHarness()
        var suggested = false
        h.detector.onSuggestDisablingAutoDetect = { suggested = true }

        for pid: Int32 in [1, 2] {
            let episodeID = try XCTUnwrap(h.confirmZoom(pid: pid))
            h.detector.dismissTapped(episodeID: episodeID, at: h.clock.now())
            h.advance(3600)
        }
        let acceptedEpisode = try XCTUnwrap(h.confirmZoom(pid: 3))
        XCTAssertTrue(h.detector.startTapped(episodeID: acceptedEpisode))

        let dismissedEpisode = try XCTUnwrap(h.confirmZoom(pid: 4))
        h.detector.dismissTapped(episodeID: dismissedEpisode, at: h.clock.now())
        XCTAssertFalse(suggested, "an accepted Start must reset the rolling counter")
    }

    // MARK: - Lock / sleep disarm

    func testDisarmClearsAllTransientState() {
        let h = DetectorHarness()
        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "us.zoom.xos", processID: 9), at: h.clock.now())
        h.detector.handleWindowSnapshot(
            [.init(processID: 9, windowID: 1, title: "Zoom Meeting", layer: 0)],
            at: h.clock.now()
        )
        h.detector.disarmAndClearTransientState()
        h.detector.handleMicEdge(.init(isActive: true), at: h.clock.now())
        XCTAssertTrue(h.prompts.isEmpty, "disarm must drop frontmost/window evidence so a later edge cannot confirm")
    }

    func testEvictingUnconsumedEpisodeInvalidatesAndConsumedDoesNot() throws {
        let h = DetectorHarness()
        let unconsumed = try XCTUnwrap(h.confirmZoom(pid: 1))
        let consumed = try XCTUnwrap(h.confirmZoom(pid: 2))
        XCTAssertTrue(h.detector.startTapped(episodeID: consumed))

        h.detector.handleWindowSnapshot([], at: h.clock.now())
        h.advance(70)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.invalidated, [unconsumed])
    }

    func testDisarmInvalidatesUnconsumedEpisodesOnly() throws {
        let h = DetectorHarness()
        let unconsumed = try XCTUnwrap(h.confirmZoom(pid: 1))
        let consumed = try XCTUnwrap(h.confirmZoom(pid: 2))
        XCTAssertTrue(h.detector.startTapped(episodeID: consumed))

        h.detector.disarmAndClearTransientState()
        XCTAssertEqual(h.invalidated, [unconsumed])
    }

    // MARK: - Still-recording nudge

    func testStillRecordingNudgeFiresOnceAfterWindowGoneSixtySeconds() throws {
        let h = DetectorHarness()
        let episodeID = try XCTUnwrap(h.confirmZoom())
        XCTAssertTrue(h.detector.startTapped(episodeID: episodeID))

        h.detector.handleWindowSnapshot([], at: h.clock.now())
        h.advance(65)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.nudges, 1)

        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.nudges, 1, "the nudge fires once per session")
    }

    // MARK: - Registry / URL matcher sanity

    func testRegistryTierLookup() {
        XCTAssertEqual(MeetingAppRegistry.tier(forBundleIdentifier: "us.zoom.xos"), .nativeTier1)
        XCTAssertEqual(MeetingAppRegistry.tier(forBundleIdentifier: "com.google.Chrome"), .browserTier2)
        XCTAssertEqual(MeetingAppRegistry.tier(forBundleIdentifier: "com.google.Chrome.app.abcdef"), .browserTier2)
        XCTAssertNil(MeetingAppRegistry.tier(forBundleIdentifier: "com.tinyspeck.slackmacgap"))
        XCTAssertNil(MeetingAppRegistry.tier(forBundleIdentifier: "com.apple.FaceTime"))
        XCTAssertEqual(MeetingAppRegistry.tier(forBundleIdentifier: "com.vivaldi.Vivaldi"), .browserTier2)
        XCTAssertEqual(MeetingAppRegistry.tier(forBundleIdentifier: "com.vivaldi.Vivaldi.app.kjgfgldnnfoeklkmfkjfagphfepbbdan"), .browserTier2)
        XCTAssertNil(MeetingAppRegistry.tier(forBundleIdentifier: "com.vivaldi.Vivaldi.application"))
        XCTAssertNil(MeetingAppRegistry.tier(forBundleIdentifier: "com.vivaldi.Vivaldi.app."))
    }

    func testRegistryMapsPWABundleToHostBrowser() {
        XCTAssertEqual(MeetingAppRegistry.hostBrowserBundleIdentifier(forPWABundleIdentifier: "com.vivaldi.Vivaldi.app.kjgf"), "com.vivaldi.Vivaldi")
        XCTAssertEqual(MeetingAppRegistry.hostBrowserBundleIdentifier(forPWABundleIdentifier: "com.google.Chrome.app.abc"), "com.google.Chrome")
        XCTAssertEqual(MeetingAppRegistry.hostBrowserBundleIdentifier(forPWABundleIdentifier: "com.microsoft.edgemac.app.abc"), "com.microsoft.edgemac")
        XCTAssertNil(MeetingAppRegistry.hostBrowserBundleIdentifier(forPWABundleIdentifier: "com.vivaldi.Vivaldi"))
        XCTAssertNil(MeetingAppRegistry.hostBrowserBundleIdentifier(forPWABundleIdentifier: "com.google.Chrome"))
        XCTAssertNil(MeetingAppRegistry.hostBrowserBundleIdentifier(forPWABundleIdentifier: "us.zoom.xos"))
        XCTAssertNil(MeetingAppRegistry.hostBrowserBundleIdentifier(forPWABundleIdentifier: "com.example.app.abc"))
    }

    func testMeetWindowTitleMatcherAcceptsRoomTitlesAndRejectsOthers() {
        let room = BrowserTabURL(host: "meet.google.com", path: "/abc-defg-hij")
        for title in ["Meet – abc-defg-hij", "Meet – abc-defg-hij - Vivaldi", "Meet - abc-defg-hij - Google Chrome", "Meet — abc-defg-hij"] {
            XCTAssertEqual(MeetingInCallTitleMatcher.inCallURL(fromWindowTitle: title), room, title)
        }
        for title in ["Google Meet", "Meet", "Meet – landing", "Meet – ABC-DEFG-HIJ", "Meet – abc-defg-hij-klm", "Zoom Meeting - Google Chrome", "Meeting | Microsoft Teams", "YouTube - Vivaldi", ""] {
            XCTAssertNil(MeetingInCallTitleMatcher.inCallURL(fromWindowTitle: title), title)
        }
    }

    func testBrowserTabURLParseRequiresWebScheme() {
        XCTAssertEqual(AXBrowserTabReader.parse("https://meet.google.com/abc-defg-hij"), BrowserTabURL(host: "meet.google.com", path: "/abc-defg-hij"))
        XCTAssertEqual(AXBrowserTabReader.parse("http://zoom.us/wc/123"), BrowserTabURL(host: "zoom.us", path: "/wc/123"))
        for url in ["chrome-extension://mpognobbkildjkofajifpdfhcoklimli/browser.html", "vivaldi://startpage", "chrome://newtab/", "about:blank", "file:///tmp/a.html", "not a url"] {
            XCTAssertNil(AXBrowserTabReader.parse(url), url)
        }
    }

    // MARK: - Browser window-title evidence (Accessibility-free)

    func testMeetWindowTitleConfirmsVivaldiTabWithoutURL() {
        let h = DetectorHarness()
        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "com.vivaldi.Vivaldi", processID: 9), at: h.clock.now())
        h.detector.handleBrowserTabURL(nil, pid: 9, bundleIdentifier: "com.vivaldi.Vivaldi", at: h.clock.now())
        h.detector.handleWindowSnapshot([.init(processID: 9, windowID: 1, title: "Meet – abc-defg-hij - Vivaldi", layer: 0)], at: h.clock.now())
        h.detector.handleMicEdge(.init(isActive: true), at: h.clock.now())
        XCTAssertEqual(h.prompts.count, 1)
        XCTAssertEqual(h.prompts.first?.tier, .browserTier2)
        XCTAssertEqual(h.prompts.first?.bundleIdentifier, "com.vivaldi.Vivaldi")
        XCTAssertEqual(h.prompts.first?.serviceName, "Google Meet")
        XCTAssertEqual(h.detector.automaticTarget, .init(bundleIdentifier: "com.vivaldi.Vivaldi", pid: 9, windowID: nil, serviceName: "Google Meet", conferenceFragment: "meet.google.com/abc-defg-hij"))
    }

    func testMeetWindowTitleConfirmsPWAShim() {
        let h = DetectorHarness()
        let shim = "com.vivaldi.Vivaldi.app.kjgfgldnnfoeklkmfkjfagphfepbbdan"
        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: shim, processID: 41), at: h.clock.now())
        h.detector.handleWindowSnapshot([.init(processID: 41, windowID: 3, title: "Meet – abc-defg-hij", layer: 0)], at: h.clock.now())
        h.detector.handleMicEdge(.init(isActive: true), at: h.clock.now())
        XCTAssertEqual(h.prompts.count, 1)
        XCTAssertEqual(h.prompts.first?.bundleIdentifier, shim)
        XCTAssertEqual(h.prompts.first?.serviceName, "Google Meet")
    }

    func testPWAEpisodeResolvesCaptureTargetToHostBrowser() throws {
        let h = DetectorHarness()
        let shim = "com.vivaldi.Vivaldi.app.kjgfgldnnfoeklkmfkjfagphfepbbdan"
        h.detector.handleBackfill([
            .init(kind: .launched, bundleIdentifier: "com.vivaldi.Vivaldi", processID: 40),
            .init(kind: .launched, bundleIdentifier: shim, processID: 41),
        ])
        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: shim, processID: 41), at: h.clock.now())
        h.detector.handleWindowSnapshot([.init(processID: 41, windowID: 3, title: "Meet – abc-defg-hij", layer: 0)], at: h.clock.now())
        h.detector.handleMicEdge(.init(isActive: true), at: h.clock.now())
        let prompt = try XCTUnwrap(h.prompts.first)
        XCTAssertEqual(prompt.bundleIdentifier, shim, "the prompt still names the web app")
        let host = MeetingAutoDetector.ResolvedTarget(bundleIdentifier: "com.vivaldi.Vivaldi", pid: 40, windowID: nil, serviceName: "Google Meet", conferenceFragment: "meet.google.com/abc-defg-hij")
        XCTAssertEqual(h.detector.resolvedTarget(for: prompt.episodeID), host)
        XCTAssertEqual(h.detector.automaticTarget, host)
    }

    func testPWAEpisodeWithoutResolvedHostHasNoCaptureTarget() throws {
        let h = DetectorHarness()
        let shim = "com.google.Chrome.app.abcdef"
        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: shim, processID: 41), at: h.clock.now())
        h.detector.handleWindowSnapshot([.init(processID: 41, windowID: 3, title: "Meet – abc-defg-hij", layer: 0)], at: h.clock.now())
        h.detector.handleMicEdge(.init(isActive: true), at: h.clock.now())
        let prompt = try XCTUnwrap(h.prompts.first, "the prompt still appears; only Start is refused")
        XCTAssertNil(h.detector.resolvedTarget(for: prompt.episodeID), "the shim would record silence, so it is never a capture source")
        XCTAssertNil(h.detector.automaticTarget)
    }

    func testBackgroundBrowserWindowTitleNeverStartsEvidence() {
        let h = DetectorHarness()
        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "com.vivaldi.Vivaldi", processID: 9), at: h.clock.now())
        h.detector.handleWindowSnapshot([
            .init(processID: 9, windowID: 1, title: "Inbox - Vivaldi", layer: 0),
            .init(processID: 9, windowID: 2, title: "Meet – abc-defg-hij - Vivaldi", layer: 0),
        ], at: h.clock.now())
        h.detector.handleMicEdge(.init(isActive: true), at: h.clock.now())
        XCTAssertTrue(h.prompts.isEmpty, "a call parked behind the frontmost window is not the user's current activity")
    }

    func testLiveTitleEpisodeSurvivesSwitchingToAnotherBrowserWindow() {
        let h = DetectorHarness()
        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "com.vivaldi.Vivaldi", processID: 9), at: h.clock.now())
        h.detector.handleWindowSnapshot([.init(processID: 9, windowID: 2, title: "Meet – abc-defg-hij - Vivaldi", layer: 0)], at: h.clock.now())
        h.detector.handleMicEdge(.init(isActive: true), at: h.clock.now())
        XCTAssertEqual(h.prompts.count, 1)
        h.detector.handleWindowSnapshot([
            .init(processID: 9, windowID: 1, title: "Inbox - Vivaldi", layer: 0),
            .init(processID: 9, windowID: 2, title: "Meet – abc-defg-hij - Vivaldi", layer: 0),
        ], at: h.clock.now())
        XCTAssertNotNil(h.detector.automaticTarget, "the call is still running in its own window")
        XCTAssertEqual(h.prompts.count, 1)
    }

    func testTitleAndURLForSameRoomShareOneEpisode() {
        let h = DetectorHarness()
        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "com.vivaldi.Vivaldi", processID: 9), at: h.clock.now())
        h.detector.handleWindowSnapshot([.init(processID: 9, windowID: 1, title: "Meet – abc-defg-hij - Vivaldi", layer: 0)], at: h.clock.now())
        h.detector.handleMicEdge(.init(isActive: true), at: h.clock.now())
        h.advance(2)
        h.detector.handleBrowserTabURL(.init(host: "meet.google.com", path: "/abc-defg-hij"), pid: 9, bundleIdentifier: "com.vivaldi.Vivaldi", at: h.clock.now())
        h.detector.handleWindowSnapshot([.init(processID: 9, windowID: 1, title: "Meet – abc-defg-hij - Vivaldi", layer: 0)], at: h.clock.now())
        XCTAssertEqual(h.prompts.count, 1)
        XCTAssertNotNil(h.detector.automaticTarget)
    }

    func testURLMissDoesNotEndTitleSustainedEpisode() {
        let h = DetectorHarness()
        let title = [WindowSnapshot(processID: 9, windowID: 1, title: "Meet – abc-defg-hij - Vivaldi", layer: 0)]
        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "com.vivaldi.Vivaldi", processID: 9), at: h.clock.now())
        h.detector.handleWindowSnapshot(title, at: h.clock.now())
        h.detector.handleMicEdge(.init(isActive: true), at: h.clock.now())
        XCTAssertEqual(h.prompts.count, 1)
        for _ in 0..<31 {
            h.advance(2)
            h.detector.handleBrowserTabURL(nil, pid: 9, bundleIdentifier: "com.vivaldi.Vivaldi", at: h.clock.now())
            h.detector.handleWindowSnapshot(title, at: h.clock.now())
            h.detector.tick(at: h.clock.now())
        }
        XCTAssertTrue(h.invalidated.isEmpty)
        XCTAssertNotNil(h.detector.automaticTarget)
    }

    func testTitleMissDoesNotEndURLSustainedEpisode() {
        let h = DetectorHarness()
        let url = BrowserTabURL(host: "meet.google.com", path: "/abc-defg-hij")
        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "com.google.Chrome", processID: 8), at: h.clock.now())
        h.detector.handleBrowserTabURL(url, pid: 8, bundleIdentifier: "com.google.Chrome", at: h.clock.now())
        h.detector.handleMicEdge(.init(isActive: true), at: h.clock.now())
        XCTAssertEqual(h.prompts.count, 1)
        for _ in 0..<31 {
            h.advance(2)
            h.detector.handleWindowSnapshot([.init(processID: 8, windowID: 1, title: "Untitled", layer: 0)], at: h.clock.now())
            h.detector.handleBrowserTabURL(url, pid: 8, bundleIdentifier: "com.google.Chrome", at: h.clock.now())
            h.detector.tick(at: h.clock.now())
        }
        XCTAssertTrue(h.invalidated.isEmpty)
        XCTAssertNotNil(h.detector.automaticTarget)
    }

    func testBothSourcesLostEndsEpisode() {
        let h = DetectorHarness()
        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "com.vivaldi.Vivaldi", processID: 9), at: h.clock.now())
        h.detector.handleWindowSnapshot([.init(processID: 9, windowID: 1, title: "Meet – abc-defg-hij - Vivaldi", layer: 0)], at: h.clock.now())
        h.detector.handleBrowserTabURL(.init(host: "meet.google.com", path: "/abc-defg-hij"), pid: 9, bundleIdentifier: "com.vivaldi.Vivaldi", at: h.clock.now())
        h.detector.handleMicEdge(.init(isActive: true), at: h.clock.now())
        XCTAssertEqual(h.prompts.count, 1)
        h.detector.handleBrowserTabURL(nil, pid: 9, bundleIdentifier: "com.vivaldi.Vivaldi", at: h.clock.now())
        XCTAssertNotNil(h.detector.automaticTarget, "one source still sees the call")
        h.detector.handleWindowSnapshot([], at: h.clock.now())
        XCTAssertNil(h.detector.automaticTarget)
        h.advance(61)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.invalidated, [h.prompts[0].episodeID])
    }

    func testTitleDoesNotRekeyLiveURLEvidence() {
        let h = DetectorHarness()
        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "com.vivaldi.Vivaldi", processID: 9), at: h.clock.now())
        h.detector.handleBrowserTabURL(.init(host: "meet.google.com", path: "/abc-defg-hij"), pid: 9, bundleIdentifier: "com.vivaldi.Vivaldi", at: h.clock.now())
        h.detector.handleMicEdge(.init(isActive: true), at: h.clock.now())
        let target = h.detector.automaticTarget
        XCTAssertNotNil(target)
        h.detector.handleWindowSnapshot([.init(processID: 9, windowID: 2, title: "Meet – xyz-wxyz-xyz - Vivaldi", layer: 0)], at: h.clock.now())
        XCTAssertEqual(h.prompts.count, 1)
        XCTAssertEqual(h.detector.automaticTarget, target)
    }

    func testTitleOnlyEvidenceForAnotherRoomCountsAsLoss() {
        let h = DetectorHarness()
        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "com.vivaldi.Vivaldi", processID: 9), at: h.clock.now())
        h.detector.handleWindowSnapshot([.init(processID: 9, windowID: 1, title: "Meet – abc-defg-hij", layer: 0)], at: h.clock.now())
        h.detector.handleMicEdge(.init(isActive: true), at: h.clock.now())
        XCTAssertEqual(h.prompts.count, 1)
        h.detector.handleWindowSnapshot([.init(processID: 9, windowID: 2, title: "Meet – xyz-wxyz-xyz", layer: 0)], at: h.clock.now())
        XCTAssertNil(h.detector.automaticTarget, "a different room must not silently keep the old episode alive")
    }

    func testGenericBrowserTitlesNeverConfirm() {
        for title in ["Zoom Meeting - Vivaldi", "Meeting | Microsoft Teams", "YouTube - Vivaldi", "Google Meet"] {
            let h = DetectorHarness()
            h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "com.vivaldi.Vivaldi", processID: 9), at: h.clock.now())
            h.detector.handleWindowSnapshot([.init(processID: 9, windowID: 1, title: title, layer: 0)], at: h.clock.now())
            h.detector.handleMicEdge(.init(isActive: true), at: h.clock.now())
            XCTAssertTrue(h.prompts.isEmpty, title)
        }
    }

    func testNativeOnlySnapshotDoesNotClearBrowserURLEvidence() {
        let h = DetectorHarness()
        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "com.google.Chrome", processID: 8), at: h.clock.now())
        h.detector.handleBrowserTabURL(.init(host: "meet.google.com", path: "/abc-defg-hij"), pid: 8, bundleIdentifier: "com.google.Chrome", at: h.clock.now())
        h.detector.handleMicEdge(.init(isActive: true), at: h.clock.now())
        XCTAssertNotNil(h.detector.automaticTarget)
        h.detector.handleWindowSnapshot([.init(processID: 100, windowID: 900, title: "Zoom Workplace", layer: 0)], at: h.clock.now())
        XCTAssertNotNil(h.detector.automaticTarget)
    }

    func testBrowserTitleEvidenceRequiresBrowserToggle() {
        let h = DetectorHarness()
        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "com.vivaldi.Vivaldi", processID: 9), at: h.clock.now())
        h.browserEnabled = false
        h.detector.handleWindowSnapshot([.init(processID: 9, windowID: 1, title: "Meet – abc-defg-hij", layer: 0)], at: h.clock.now())
        h.detector.handleMicEdge(.init(isActive: true), at: h.clock.now())
        XCTAssertTrue(h.prompts.isEmpty)
    }

    func testInCallURLMatcherAcceptsRoomsAndRejectsLandingPages() {
        XCTAssertTrue(MeetingInCallURLMatcher.isInCallURL(host: "meet.google.com", path: "/abc-defg-hij"))
        XCTAssertFalse(MeetingInCallURLMatcher.isInCallURL(host: "meet.google.com", path: "/"))
        XCTAssertTrue(MeetingInCallURLMatcher.isInCallURL(host: "us04web.zoom.us", path: "/j/123456789"))
        XCTAssertFalse(MeetingInCallURLMatcher.isInCallURL(host: "zoom.us", path: "/pricing"))
        XCTAssertTrue(MeetingInCallURLMatcher.isInCallURL(host: "teams.microsoft.com", path: "/l/meetup-join/abc"))
        XCTAssertTrue(MeetingInCallURLMatcher.isInCallURL(host: "whereby.com", path: "/my-room"))
        XCTAssertFalse(MeetingInCallURLMatcher.isInCallURL(host: "whereby.com", path: "/pricing"))
        XCTAssertTrue(MeetingInCallURLMatcher.isInCallURL(host: "meet.jit.si", path: "/SomeRoomName"))
    }

    // MARK: - windowID preference in MeetingWindowSelector

    func testWindowSelectorPrefersPreferredWindowIDWhenEligible() {
        let candidates = [
            MeetingWindowCandidate(windowID: 1, title: "Untitled", frame: CGRect(x: 0, y: 0, width: 400, height: 400), layer: 0, zOrderIndex: 0),
            MeetingWindowCandidate(windowID: 2, title: "Small", frame: CGRect(x: 0, y: 0, width: 210, height: 110), layer: 0, zOrderIndex: 1),
        ]
        let selected = MeetingWindowSelector.selectWindow(from: candidates, preferredWindowID: 2)
        XCTAssertEqual(selected?.windowID, 2, "the preferred window must win even though it ranks lower")
    }

    func testWindowSelectorFallsBackWhenPreferredWindowIsGone() {
        let candidates = [
            MeetingWindowCandidate(windowID: 1, title: "Untitled", frame: CGRect(x: 0, y: 0, width: 400, height: 400), layer: 0, zOrderIndex: 0),
        ]
        let selected = MeetingWindowSelector.selectWindow(from: candidates, preferredWindowID: 999)
        XCTAssertEqual(selected?.windowID, 1)
    }
}

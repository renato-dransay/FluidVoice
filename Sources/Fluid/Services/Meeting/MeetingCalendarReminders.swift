import AppKit
import EventKit
import Foundation

/// A calendar event with a call link, offered shortly before it starts so the user can join and
/// record in one step. Only the link, title, times and attendees are read; nothing is written back.
nonisolated struct MeetingCalendarReminder: Equatable, Sendable, Identifiable {
    /// Event identifier plus start time, so each occurrence of a recurring meeting is offered once.
    var id: String
    var eventIdentifier: String
    var title: String
    var start: Date
    var end: Date
    var conferenceURL: URL
    var serviceName: String?
    var attendees: [MeetingCalendarAttendee]

    var calendarMatch: MeetingCalendarMatch {
        MeetingCalendarMatch(eventIdentifier: self.eventIdentifier, title: self.title, attendees: self.attendees, matchedByConferenceLink: true)
    }
}

/// EventKit-free snapshot of one event so reminder selection can be unit tested.
nonisolated struct MeetingCalendarReminderCandidate: Equatable, Sendable {
    var eventIdentifier: String
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var currentUserDeclined: Bool
    /// The event URL, location and notes, in that order of preference for the call link.
    var linkSources: [String]
    var attendees: [MeetingCalendarAttendee]
}

nonisolated enum MeetingCalendarReminderPolicy {
    /// The reminder appears this long before the start time…
    static let leadTime: TimeInterval = 60
    /// …and stays offered until this long after it, for people joining late.
    static let lateJoinWindow: TimeInterval = 5 * 60
    /// Events are fetched across the whole offer window.
    static let lookBehind: TimeInterval = lateJoinWindow
    static let lookAhead: TimeInterval = leadTime + 60

    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// The first link in the sources that is a supported in-call URL (Google Meet room, Zoom
    /// meeting, Teams meeting, Whereby or Jitsi room), so a calendar page or dial-in link never counts.
    static func conferenceURL(in sources: [String]) -> URL? {
        guard let detector = self.linkDetector else { return nil }
        for source in sources where !source.isEmpty {
            let range = NSRange(source.startIndex..., in: source)
            for match in detector.matches(in: source, options: [], range: range) {
                guard let url = match.url,
                      let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
                      let host = url.host, MeetingInCallURLMatcher.isInCallURL(host: host, path: url.path)
                else { continue }
                return url
            }
        }
        return nil
    }

    /// The earliest event whose offer window contains `now` and that has not been offered yet.
    /// All-day events, declined invitations and events without a call link never qualify.
    static func dueReminder(
        among candidates: [MeetingCalendarReminderCandidate],
        at now: Date,
        alreadyOffered: Set<String>
    ) -> MeetingCalendarReminder? {
        let due = candidates.compactMap { candidate -> MeetingCalendarReminder? in
            guard !candidate.isAllDay, !candidate.currentUserDeclined,
                  candidate.start.addingTimeInterval(-self.leadTime) <= now,
                  now < candidate.start.addingTimeInterval(self.lateJoinWindow),
                  now < candidate.end,
                  let url = self.conferenceURL(in: candidate.linkSources)
            else { return nil }
            let id = self.reminderID(eventIdentifier: candidate.eventIdentifier, start: candidate.start)
            guard !alreadyOffered.contains(id) else { return nil }
            let host = url.host?.lowercased() ?? ""
            let title = candidate.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return MeetingCalendarReminder(
                id: id,
                eventIdentifier: candidate.eventIdentifier,
                title: title.isEmpty ? "Calendar meeting" : title,
                start: candidate.start,
                end: candidate.end,
                conferenceURL: url,
                serviceName: MeetingAutoDetector.serviceName(forEvidenceKey: "url:\(host)\(url.path)"),
                attendees: candidate.attendees
            )
        }
        return due.min { $0.start < $1.start }
    }

    static func reminderID(eventIdentifier: String, start: Date) -> String {
        "\(eventIdentifier)@\(Int(start.timeIntervalSince1970))"
    }

    /// Native apps that take over a call link opened in the browser. When one is installed, its
    /// audio is the call; otherwise the call runs in the browser that opens the link.
    static func nativeAppBundleIdentifier(for url: URL) -> String? {
        let host = url.host?.lowercased() ?? ""
        if host == "zoom.us" || host.hasSuffix(".zoom.us") { return "us.zoom.xos" }
        if host == "teams.microsoft.com" || host == "teams.live.com" { return "com.microsoft.teams2" }
        return nil
    }

    /// Short relative start time for the reminder, e.g. "Starts in 1 min" or "Started 3 min ago".
    static func startDescription(start: Date, now: Date) -> String {
        let seconds = start.timeIntervalSince(now)
        if abs(seconds) < 30 { return "Starting now" }
        let minutes = max(1, Int((abs(seconds) / 60).rounded()))
        return seconds > 0 ? "Starts in \(minutes) min" : "Started \(minutes) min ago"
    }
}

/// Polls Mac Calendar and presents one reminder per upcoming call. Prompt-only, like automatic
/// detection: recording starts only from the reminder's Open & Transcribe button.
@MainActor
final class MeetingCalendarReminderScheduler {
    private static let pollInterval: TimeInterval = 15
    private static let logSource = "MeetingCalendarReminders"

    private var store: EKEventStore?
    private var timer: Timer?
    private var storeObserver: NSObjectProtocol?
    /// Offered reminder IDs with their start time, pruned once the offer window has passed.
    private var offered: [String: Date] = [:]

    func start() {
        guard self.timer == nil else { return }
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        timer.tolerance = 3
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        self.storeObserver = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        DebugLogger.shared.info("reminders-started", source: Self.logSource)
        self.tick()
    }

    func tick(now: Date = Date()) {
        self.offered = self.offered.filter { now < $0.value.addingTimeInterval(MeetingCalendarReminderPolicy.lateJoinWindow) }
        let controller = MeetingCalendarReminderController.shared
        if AppServices.shared.hasActiveMeetingSessionActivity {
            controller.dismissIfIdle()
            return
        }
        guard SettingsStore.shared.meetingCalendarRemindersEnabled,
              EventKitMeetingCalendarProvider.authorizationState == .fullAccess,
              controller.reminder == nil,
              MeetingDetectionPromptController.shared.request == nil
        else { return }

        let store = self.store ?? EKEventStore()
        self.store = store
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-MeetingCalendarReminderPolicy.lookBehind),
            end: now.addingTimeInterval(MeetingCalendarReminderPolicy.lookAhead),
            calendars: nil
        )
        let candidates = store.events(matching: predicate).map(Self.candidate(from:))
        guard let reminder = MeetingCalendarReminderPolicy.dueReminder(
            among: candidates,
            at: now,
            alreadyOffered: Set(self.offered.keys)
        ) else { return }
        self.offered[reminder.id] = reminder.start
        DebugLogger.shared.info(
            "reminder-due service=\(reminder.serviceName ?? "other") startsInSeconds=\(Int(reminder.start.timeIntervalSince(now)))",
            source: Self.logSource
        )
        controller.present(reminder)
    }

    static func candidate(from event: EKEvent) -> MeetingCalendarReminderCandidate {
        var participants = (event.attendees ?? []).map { participant in
            MeetingCalendarParticipantRecord(
                name: participant.name,
                urlString: participant.url.absoluteString,
                isCurrentUser: participant.isCurrentUser,
                kind: Self.kind(of: participant)
            )
        }
        if let organizer = event.organizer,
           !participants.contains(where: { $0.urlString?.lowercased() == organizer.url.absoluteString.lowercased() })
        {
            participants.append(MeetingCalendarParticipantRecord(
                name: organizer.name,
                urlString: organizer.url.absoluteString,
                isCurrentUser: organizer.isCurrentUser,
                kind: Self.kind(of: organizer)
            ))
        }
        let declined = event.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false
        return MeetingCalendarReminderCandidate(
            eventIdentifier: event.eventIdentifier ?? "",
            title: event.title ?? "",
            start: event.startDate,
            end: event.endDate,
            isAllDay: event.isAllDay,
            currentUserDeclined: declined,
            linkSources: [event.url?.absoluteString, event.location, event.notes].compactMap { $0 },
            attendees: MeetingCalendarRanking.attendees(from: participants, organizerURLString: event.organizer?.url.absoluteString)
        )
    }

    private static func kind(of participant: EKParticipant) -> MeetingCalendarParticipantRecord.Kind {
        switch participant.participantType {
        case .person: .person
        case .room: .room
        case .resource: .resource
        case .group: .group
        case .unknown: .unknown
        @unknown default: .unknown
        }
    }
}

extension AppServices {
    /// How long a Zoom or Teams link may take to hand off from the browser to the installed app.
    private static let nativeHandoffTimeout: TimeInterval = 30

    /// Opens the call link, then records the app that actually runs the call. For Zoom and Teams
    /// links that is the installed native app only once it comes forward after the link opened;
    /// a declined or blocked handoff, or joining on the web, records the browser instead.
    func openCalendarMeetingAndRecord(_ reminder: MeetingCalendarReminder) async throws {
        let browserBundleIdentifier = NSWorkspace.shared.urlForApplication(toOpen: reminder.conferenceURL)
            .flatMap { Bundle(url: $0)?.bundleIdentifier }
        let nativeBundleIdentifier = MeetingCalendarReminderPolicy.nativeAppBundleIdentifier(for: reminder.conferenceURL)
            .flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil ? $0 : nil }
        NSWorkspace.shared.open(reminder.conferenceURL)

        var targetBundleIdentifier = browserBundleIdentifier
        if let nativeBundleIdentifier, try await Self.awaitHandoff(to: nativeBundleIdentifier) {
            targetBundleIdentifier = nativeBundleIdentifier
        }
        guard let targetBundleIdentifier else {
            throw MeetingCaptureError.applicationUnavailable(nativeBundleIdentifier ?? "browser")
        }
        DebugLogger.shared.info(
            "reminder-target bundle=\(targetBundleIdentifier) native=\(targetBundleIdentifier == nativeBundleIdentifier)",
            source: "MeetingCalendarReminders"
        )

        // Capture sources can lag briefly behind an app that just launched or came forward.
        let deadline = Date().addingTimeInterval(5)
        var configuration: MeetingCaptureConfiguration
        while true {
            do {
                configuration = try await self.meetingSessionCoordinator.defaultConfiguration(
                    mode: .onlineCall,
                    title: MeetingRecordingTitle.resolve(
                        mode: .onlineCall,
                        calendarTitle: reminder.title,
                        exposedTitle: nil,
                        serviceName: reminder.serviceName,
                        applicationDisplayName: nil
                    ),
                    preferredBundleIdentifier: targetBundleIdentifier,
                    preferredWindowID: nil,
                    requirePreferredApplication: true
                )
                break
            } catch MeetingCaptureError.applicationUnavailable where Date() < deadline {
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        configuration.calendar = reminder.calendarMatch
        try Task.checkCancellation()
        _ = try await self.meetingSessionCoordinator.startRecording(configuration: configuration)
        DebugLogger.shared.info("reminder-recording-started bundle=\(targetBundleIdentifier)", source: "MeetingCalendarReminders")
    }

    /// True once the native app becomes frontmost after another app was, i.e. after the browser
    /// opened the link and handed the call over. Being installed or already running proves nothing.
    private static func awaitHandoff(to bundleIdentifier: String) async throws -> Bool {
        let deadline = Date().addingTimeInterval(self.nativeHandoffTimeout)
        var sawAnotherAppFrontmost = false
        while Date() < deadline {
            let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            if frontmost != bundleIdentifier {
                sawAnotherAppFrontmost = true
            } else if sawAnotherAppFrontmost {
                return true
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }
}

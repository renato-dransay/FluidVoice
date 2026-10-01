import AppKit
import Combine
import EventKit
import Foundation

/// One calendar event in FluidMeet's "Upcoming events" list. Only the title, times, calendar color,
/// response status, call link and attendees are read; nothing is written back.
nonisolated struct MeetingUpcomingEvent: Equatable, Sendable, Identifiable {
    struct Color: Equatable, Sendable {
        var red: Double
        var green: Double
        var blue: Double
    }

    /// Event identifier plus start time, so each occurrence of a recurring meeting is its own row.
    var id: String
    var title: String
    var start: Date
    var end: Date
    /// Not yet accepted: the invitation is tentative or still waiting for a reply.
    var isTentative: Bool
    var calendarColor: Color?
    /// A Google Meet, Zoom, Teams, Whereby or Jitsi room the event links to.
    var reminder: MeetingCalendarReminder?
    /// Lowercased event URL, location and notes, for matching a detected call's room.
    var searchableText: String
}

nonisolated enum MeetingUpcomingEventsPolicy {
    /// Events are listed from now until this far ahead.
    static let horizon: TimeInterval = 7 * 24 * 3600
    /// The list shows this many events until the user asks for all of them.
    static let collapsedLimit = 5
    /// Join and Transcribe appear this long before an event with a call link starts.
    static let joinLeadTime: TimeInterval = 5 * 60

    /// Timed events that have not ended and were not declined, earliest first.
    static func upcoming(
        from candidates: [(candidate: MeetingCalendarReminderCandidate, isTentative: Bool, color: MeetingUpcomingEvent.Color?)],
        at now: Date
    ) -> [MeetingUpcomingEvent] {
        candidates
            .filter { !$0.candidate.isAllDay && !$0.candidate.currentUserDeclined && $0.candidate.end > now }
            .map { entry in
                let candidate = entry.candidate
                let title = candidate.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let id = MeetingCalendarReminderPolicy.reminderID(eventIdentifier: candidate.eventIdentifier, start: candidate.start)
                let reminder = MeetingCalendarReminderPolicy.conferenceURL(in: candidate.linkSources).map { url in
                    MeetingCalendarReminder(
                        id: id,
                        eventIdentifier: candidate.eventIdentifier,
                        title: title.isEmpty ? "Calendar meeting" : title,
                        start: candidate.start,
                        end: candidate.end,
                        conferenceURL: url,
                        serviceName: MeetingAutoDetector.serviceName(forEvidenceKey: "url:\(url.host?.lowercased() ?? "")\(url.path)"),
                        attendees: candidate.attendees
                    )
                }
                return MeetingUpcomingEvent(
                    id: id,
                    title: title.isEmpty ? "Untitled event" : title,
                    start: candidate.start,
                    end: candidate.end,
                    isTentative: entry.isTentative,
                    calendarColor: entry.color,
                    reminder: reminder,
                    searchableText: candidate.linkSources.joined(separator: "\n").lowercased()
                )
            }
            .sorted { ($0.start, $0.id) < ($1.start, $1.id) }
    }

    /// True once the call is about to start and until it ends, when Join and Transcribe are offered.
    static func isJoinable(_ event: MeetingUpcomingEvent, at now: Date) -> Bool {
        event.reminder != nil && event.start.addingTimeInterval(-self.joinLeadTime) <= now && now < event.end
    }

    /// The running or imminent event whose call link is the detected room, e.g. "meet.google.com/abc-defg-hij".
    static func event(matchingConferenceFragment fragment: String?, among events: [MeetingUpcomingEvent], at now: Date) -> MeetingUpcomingEvent? {
        guard let fragment = fragment?.lowercased(), !fragment.isEmpty else { return nil }
        return events.first { self.isJoinable($0, at: now) && $0.searchableText.contains(fragment) }
    }

    /// "11:00 – 11:30 AM" today, "Tomorrow 9:30 AM", or "Fri 9:30 AM" later in the week.
    static func timeLabel(for event: MeetingUpcomingEvent, at now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        if calendar.isDate(event.start, inSameDayAs: now) {
            let formatter = DateIntervalFormatter()
            formatter.calendar = calendar
            formatter.locale = locale
            formatter.timeZone = calendar.timeZone
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            return formatter.string(from: event.start, to: event.end)
        }
        let time = DateFormatter()
        time.calendar = calendar
        time.locale = locale
        time.timeZone = calendar.timeZone
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(event.start, inSameDayAs: tomorrow) {
            time.dateStyle = .none
            time.timeStyle = .short
            return "Tomorrow \(time.string(from: event.start))"
        }
        time.setLocalizedDateFormatFromTemplate("EEEjmm")
        return time.string(from: event.start)
    }
}

/// Keeps FluidMeet's upcoming events current while the meeting home is on screen.
@MainActor
final class MeetingUpcomingEventsModel: ObservableObject {
    @Published private(set) var events: [MeetingUpcomingEvent] = []
    @Published private(set) var now = Date()
    @Published private(set) var isAvailable = false
    /// The event whose Transcribe action is starting a recording, and the last failure.
    @Published private(set) var startingEventID: String?
    @Published private(set) var errorMessage: String?

    private static let refreshInterval: TimeInterval = 30
    private var store: EKEventStore?
    private var timer: Timer?
    private var storeObserver: NSObjectProtocol?

    func start() {
        guard self.timer == nil else { return }
        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        self.storeObserver = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        self.refresh()
    }

    func stop() {
        self.timer?.invalidate()
        self.timer = nil
        if let storeObserver { NotificationCenter.default.removeObserver(storeObserver) }
        self.storeObserver = nil
    }

    func refresh() {
        let now = Date()
        self.now = now
        let settings = SettingsStore.shared
        guard settings.meetingCalendarNamesEnabled || settings.meetingCalendarRemindersEnabled,
              EventKitMeetingCalendarProvider.authorizationState == .fullAccess
        else {
            self.isAvailable = false
            self.events = []
            return
        }
        let store = self.store ?? EKEventStore()
        self.store = store
        let predicate = store.predicateForEvents(withStart: now, end: now.addingTimeInterval(MeetingUpcomingEventsPolicy.horizon), calendars: nil)
        let candidates = store.events(matching: predicate).map { event in
            (
                candidate: MeetingCalendarReminderScheduler.candidate(from: event),
                isTentative: Self.isTentative(event),
                color: Self.color(of: event)
            )
        }
        self.events = MeetingUpcomingEventsPolicy.upcoming(from: candidates, at: now)
        self.isAvailable = true
    }

    func join(_ event: MeetingUpcomingEvent) {
        guard let url = event.reminder?.conferenceURL else { return }
        NSWorkspace.shared.open(url)
        DebugLogger.shared.info("upcoming-join", source: "MeetingUpcomingEvents")
    }

    /// Opens the call link and records it, exactly like the reminder's Open & Transcribe.
    func openAndTranscribe(_ event: MeetingUpcomingEvent) {
        guard let reminder = event.reminder, self.startingEventID == nil else { return }
        self.startingEventID = event.id
        self.errorMessage = nil
        DebugLogger.shared.info("upcoming-open-and-transcribe", source: "MeetingUpcomingEvents")
        Task { @MainActor [weak self] in
            do {
                try await AppServices.shared.openCalendarMeetingAndRecord(reminder)
                MeetingCalendarReminderController.shared.dismissIfIdle()
                self?.startingEventID = nil
            } catch {
                DebugLogger.shared.warning("upcoming-start-failed error=\(error)", source: "MeetingUpcomingEvents")
                self?.startingEventID = nil
                self?.errorMessage = MeetingDetectionPromptController.startErrorMessage(
                    from: error,
                    appDisplayName: reminder.serviceName ?? "The meeting app"
                )
            }
        }
    }

    private static func isTentative(_ event: EKEvent) -> Bool {
        guard let me = event.attendees?.first(where: \.isCurrentUser) else { return false }
        return me.participantStatus == .tentative || me.participantStatus == .pending
    }

    private static func color(of event: EKEvent) -> MeetingUpcomingEvent.Color? {
        guard let cgColor = event.calendar?.cgColor,
              let color = NSColor(cgColor: cgColor)?.usingColorSpace(.sRGB)
        else { return nil }
        return .init(red: Double(color.redComponent), green: Double(color.greenComponent), blue: Double(color.blueComponent))
    }
}

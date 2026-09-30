import EventKit
import Foundation

/// One calendar participant offered to the speaker picker. Names are only suggestions; the
/// pipeline never assigns them to a speaker on its own.
nonisolated struct MeetingCalendarAttendee: Codable, Equatable, Sendable {
    var name: String
    var email: String?
    var isOrganizer: Bool
}

/// The calendar event a recording was matched to. Persisted on the session manifest.
nonisolated struct MeetingCalendarMatch: Codable, Equatable, Sendable {
    var eventIdentifier: String
    var title: String
    var attendees: [MeetingCalendarAttendee]
    var matchedByConferenceLink: Bool
}

@MainActor
protocol MeetingCalendarProviding: AnyObject {
    /// `conferenceFragment` is a lowercase substring identifying the call, e.g.
    /// "meet.google.com/abc-defg-hij", "zoom.us/j/123456789", "teams.microsoft.com/l/meetup-join";
    /// nil when unknown.
    func match(at date: Date, conferenceFragment: String?) async -> MeetingCalendarMatch?
}

/// Process-wide access point. Settable so tests and previews can install a fake.
@MainActor
enum MeetingCalendarContext {
    static var shared: any MeetingCalendarProviding = EventKitMeetingCalendarProvider()
}

/// Used when calendar context is unavailable or intentionally off.
@MainActor
final class DisabledMeetingCalendarProvider: MeetingCalendarProviding {
    func match(at date: Date, conferenceFragment: String?) async -> MeetingCalendarMatch? { nil }
}

// MARK: - Pure ranking model

/// EventKit-free snapshot of one calendar event so the ranking can be unit tested.
nonisolated struct MeetingCalendarEventCandidate: Equatable, Sendable {
    var eventIdentifier: String
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    /// Lowercased concatenation of the event URL, location and notes.
    var searchableText: String
    var attendees: [MeetingCalendarAttendee]

    var match: MeetingCalendarMatch {
        MeetingCalendarMatch(
            eventIdentifier: self.eventIdentifier,
            title: self.title,
            attendees: self.attendees,
            matchedByConferenceLink: false
        )
    }
}

/// EventKit-free snapshot of one event participant so attendee mapping can be unit tested.
nonisolated struct MeetingCalendarParticipantRecord: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case person
        case room
        case resource
        case group
        case unknown
    }

    var name: String?
    /// The participant URL as a string, typically "mailto:someone@example.com".
    var urlString: String?
    var isCurrentUser: Bool
    var kind: Kind
}

nonisolated enum MeetingCalendarRanking {
    /// Events are looked up from `date - lookBehind` to `date + lookAhead`.
    static let lookBehind: TimeInterval = 15 * 60
    static let lookAhead: TimeInterval = 10 * 60

    /// A conference-link match wins outright. Otherwise the single non-all-day event overlapping
    /// `date` is used; two or more overlapping events without a link match are ambiguous and yield nil.
    static func bestMatch(
        among candidates: [MeetingCalendarEventCandidate],
        at date: Date,
        conferenceFragment: String?
    ) -> MeetingCalendarMatch? {
        let timed = candidates.filter { !$0.isAllDay }
        if let fragment = conferenceFragment?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines),
           !fragment.isEmpty
        {
            let linked = timed.filter { $0.searchableText.contains(fragment) }
            if let winner = Self.closest(to: date, among: linked) {
                var match = winner.match
                match.matchedByConferenceLink = true
                return match
            }
        }
        let overlapping = timed.filter { $0.start <= date && date < $0.end }
        guard overlapping.count == 1, let only = overlapping.first else { return nil }
        return only.match
    }

    /// Maps raw participants to attendees: the current user and rooms/resources are dropped, the
    /// name falls back to the email local part, and the organizer is flagged by URL.
    static func attendees(
        from participants: [MeetingCalendarParticipantRecord],
        organizerURLString: String?
    ) -> [MeetingCalendarAttendee] {
        let organizerEmail = organizerURLString.flatMap(Self.email(fromParticipantURL:))
        var seenKeys = Set<String>()
        var attendees: [MeetingCalendarAttendee] = []
        for participant in participants {
            guard !participant.isCurrentUser else { continue }
            switch participant.kind {
            case .room, .resource: continue
            case .person, .group, .unknown: break
            }
            let email = participant.urlString.flatMap(Self.email(fromParticipantURL:))
            let trimmedName = participant.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let name = trimmedName.isEmpty ? (email.map(Self.localPart(of:)) ?? "") : trimmedName
            guard !name.isEmpty else { continue }
            let key = (email ?? name).lowercased()
            guard seenKeys.insert(key).inserted else { continue }
            attendees.append(MeetingCalendarAttendee(
                name: name,
                email: email,
                isOrganizer: email != nil && email?.lowercased() == organizerEmail?.lowercased()
            ))
        }
        return attendees
    }

    private static func closest(
        to date: Date,
        among candidates: [MeetingCalendarEventCandidate]
    ) -> MeetingCalendarEventCandidate? {
        candidates.min { lhs, rhs in
            let lhsOverlaps = lhs.start <= date && date < lhs.end
            let rhsOverlaps = rhs.start <= date && date < rhs.end
            if lhsOverlaps != rhsOverlaps { return lhsOverlaps }
            return abs(lhs.start.timeIntervalSince(date)) < abs(rhs.start.timeIntervalSince(date))
        }
    }

    private static func email(fromParticipantURL urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("mailto:") else { return nil }
        let address = String(trimmed.dropFirst("mailto:".count))
        guard address.contains("@") else { return nil }
        return address
    }

    private static func localPart(of email: String) -> String {
        email.split(separator: "@", maxSplits: 1).first.map(String.init) ?? email
    }
}

// MARK: - EventKit provider

/// Reads Mac Calendar through EventKit. Google Calendar arrives through the Google account added in
/// System Settings > Internet Accounts; nothing is ever written back.
@MainActor
final class EventKitMeetingCalendarProvider: MeetingCalendarProviding {
    enum AuthorizationState: Equatable, Sendable {
        case notDetermined
        case fullAccess
        case denied
        case restricted
        case limited
    }

    private static let logSource = "MeetingCalendar"
    private var store: EKEventStore?

    static var authorizationState: AuthorizationState {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: return .notDetermined
        case .fullAccess: return .fullAccess
        case .denied: return .denied
        case .restricted: return .restricted
        case .writeOnly, .authorized: return .limited
        @unknown default: return .limited
        }
    }

    /// Prompts for full calendar access. Only the Settings toggle calls this; a detected meeting never does.
    static func requestAccess() async -> Bool {
        if Self.authorizationState == .fullAccess { return true }
        do {
            let granted = try await EKEventStore().requestFullAccessToEvents()
            DebugLogger.shared.info("Calendar access request granted=\(granted)", source: Self.logSource)
            return granted
        } catch {
            DebugLogger.shared.log("Calendar access request failed: \(error.localizedDescription)", source: Self.logSource)
            return false
        }
    }

    func match(at date: Date, conferenceFragment: String?) async -> MeetingCalendarMatch? {
        guard SettingsStore.shared.meetingCalendarNamesEnabled,
              Self.authorizationState == .fullAccess
        else {
            return nil
        }
        let store = self.store ?? EKEventStore()
        self.store = store
        let predicate = store.predicateForEvents(
            withStart: date.addingTimeInterval(-MeetingCalendarRanking.lookBehind),
            end: date.addingTimeInterval(MeetingCalendarRanking.lookAhead),
            calendars: nil
        )
        let candidates = store.events(matching: predicate).map(Self.candidate(from:))
        let match = MeetingCalendarRanking.bestMatch(
            among: candidates,
            at: date,
            conferenceFragment: conferenceFragment
        )
        DebugLogger.shared.info(
            "Calendar lookup candidates=\(candidates.count) matched=\(match != nil) byLink=\(match?.matchedByConferenceLink ?? false) attendees=\(match?.attendees.count ?? 0)",
            source: Self.logSource
        )
        return match
    }

    private static func candidate(from event: EKEvent) -> MeetingCalendarEventCandidate {
        let searchable = [event.url?.absoluteString, event.location, event.notes]
            .compactMap { $0 }
            .joined(separator: "\n")
            .lowercased()
        var participants = (event.attendees ?? []).map(Self.record(from:))
        if let organizer = event.organizer {
            let organizerRecord = Self.record(from: organizer)
            let alreadyListed = participants.contains {
                $0.urlString != nil && $0.urlString?.lowercased() == organizerRecord.urlString?.lowercased()
            }
            if !alreadyListed { participants.append(organizerRecord) }
        }
        return MeetingCalendarEventCandidate(
            eventIdentifier: event.eventIdentifier ?? "",
            title: (event.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            start: event.startDate,
            end: event.endDate,
            isAllDay: event.isAllDay,
            searchableText: searchable,
            attendees: MeetingCalendarRanking.attendees(
                from: participants,
                organizerURLString: event.organizer?.url.absoluteString
            )
        )
    }

    private static func record(from participant: EKParticipant) -> MeetingCalendarParticipantRecord {
        let kind: MeetingCalendarParticipantRecord.Kind
        switch participant.participantType {
        case .person: kind = .person
        case .room: kind = .room
        case .resource: kind = .resource
        case .group: kind = .group
        case .unknown: kind = .unknown
        @unknown default: kind = .unknown
        }
        return MeetingCalendarParticipantRecord(
            name: participant.name,
            urlString: participant.url.absoluteString,
            isCurrentUser: participant.isCurrentUser,
            kind: kind
        )
    }
}

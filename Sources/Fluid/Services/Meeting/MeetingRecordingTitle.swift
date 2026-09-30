import Foundation

/// Picks a recording title from the best available source, in order: the matched calendar
/// event, the name the meeting app itself exposes, the detected service, the captured app.
nonisolated enum MeetingRecordingTitle {
    static func resolve(
        mode: MeetingCaptureMode,
        calendarTitle: String?,
        exposedTitle: String?,
        serviceName: String?,
        applicationDisplayName: String?
    ) -> String {
        guard mode == .onlineCall else { return "In-room meeting" }
        if let calendarTitle = self.clean(calendarTitle) { return calendarTitle }
        if let exposedTitle = self.clean(exposedTitle) { return exposedTitle }
        if let serviceName = self.clean(serviceName) { return "\(serviceName) call" }
        if let applicationDisplayName = self.clean(applicationDisplayName) { return "\(applicationDisplayName) call" }
        return "Meeting"
    }

    private static func clean(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

/// Meeting names that apps expose in their own window titles. Only Microsoft Teams does today:
/// its meeting windows are titled "<meeting name> | Microsoft Teams". Zoom titles every meeting
/// window "Zoom Meeting" and Google Meet titles tabs with the room code only, so both return nil.
nonisolated enum MeetingExposedTitleMatcher {
    private static let teamsSuffixes = [" | Microsoft Teams", " - Microsoft Teams"]
    /// Teams titles its non-meeting views with these section names.
    private static let teamsSectionTitles: Set<String> = [
        "", "Microsoft Teams", "Chat", "Activity", "Teams", "Calendar", "Calls", "Files", "Apps", "OneDrive",
        "Meeting", "Meetings", "Join a meeting", "Pre-join", "Meeting | Microsoft Teams",
    ]

    static func meetingName(fromWindowTitle title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in self.teamsSuffixes where trimmed.hasSuffix(suffix) {
            let name = String(trimmed.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !self.teamsSectionTitles.contains(name), !name.hasPrefix("Meeting with ") || name.count > 13 else { return nil }
            return name.isEmpty ? nil : name
        }
        return nil
    }
}

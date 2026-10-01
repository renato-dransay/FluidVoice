import SwiftUI

/// FluidMeet's "Coming up": the next calendar events, with Join and Transcribe on a call that is
/// about to start or running. Hidden until calendar access is granted.
struct MeetingUpcomingEventsList: View {
    @ObservedObject var model: MeetingUpcomingEventsModel
    /// The event whose call auto-detection already found; Transcribe records that call in place.
    let liveEventID: String?
    let isEnabled: Bool
    let onTranscribeLive: () -> Void

    @Environment(\.theme) private var theme
    @State private var showsAll = false

    private var visibleEvents: [MeetingUpcomingEvent] {
        self.showsAll ? self.model.events : Array(self.model.events.prefix(MeetingUpcomingEventsPolicy.collapsedLimit))
    }

    var body: some View {
        if self.model.isAvailable {
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Coming up")
                        .font(self.theme.typography.sectionTitle)
                        .foregroundStyle(self.theme.palette.primaryText)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    if self.model.events.count > MeetingUpcomingEventsPolicy.collapsedLimit {
                        Button(self.showsAll ? "Show fewer" : "View all") { self.showsAll.toggle() }
                            .buttonStyle(.plain)
                            .foregroundStyle(self.theme.palette.accent)
                            .accessibilityLabel(self.showsAll ? "Show fewer upcoming events" : "View all upcoming events")
                    }
                }

                ThemedCard(style: .subtle, padding: 0) {
                    if self.model.events.isEmpty {
                        HStack(spacing: self.theme.metrics.spacing.md) {
                            Image(systemName: "calendar")
                                .foregroundStyle(self.theme.palette.accent)
                            Text("Nothing on your calendar for the next seven days.")
                                .font(self.theme.typography.bodySmall)
                                .foregroundStyle(self.theme.palette.secondaryText)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(self.visibleEvents) { event in
                                self.row(for: event)
                                if event.id != self.visibleEvents.last?.id {
                                    Divider().opacity(0.4).padding(.horizontal, 18)
                                }
                            }
                        }
                    }
                }

                if let errorMessage = self.model.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(self.theme.typography.bodySmall)
                        .foregroundStyle(self.theme.palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Could not start recording. \(errorMessage)")
                }
            }
        }
    }

    private func row(for event: MeetingUpcomingEvent) -> some View {
        MeetingUpcomingEventRow(
            event: event,
            now: self.model.now,
            isLive: event.id == self.liveEventID,
            isStarting: self.model.startingEventID == event.id,
            isEnabled: self.isEnabled && self.model.startingEventID == nil,
            onJoin: { self.model.join(event) },
            onTranscribe: {
                if event.id == self.liveEventID {
                    self.onTranscribeLive()
                } else {
                    self.model.openAndTranscribe(event)
                }
            }
        )
    }
}

private struct MeetingUpcomingEventRow: View {
    let event: MeetingUpcomingEvent
    let now: Date
    let isLive: Bool
    let isStarting: Bool
    let isEnabled: Bool
    let onJoin: () -> Void
    let onTranscribe: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    private var isJoinable: Bool {
        self.isLive || MeetingUpcomingEventsPolicy.isJoinable(self.event, at: self.now)
    }

    private var calendarColor: Color {
        guard let color = self.event.calendarColor else { return self.theme.palette.accent }
        return Color(.sRGB, red: color.red, green: color.green, blue: color.blue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
            HStack(alignment: .center, spacing: self.theme.metrics.spacing.md) {
                self.when
                self.colorBar
                self.summary
                Spacer(minLength: self.theme.metrics.spacing.sm)
                if self.isJoinable {
                    self.status
                }
            }
            if self.isJoinable {
                FluidGlassControlGroup {
                    HStack(spacing: self.theme.metrics.spacing.sm) {
                        self.transcribeAction
                        self.joinAction
                    }
                }
                .padding(.leading, Self.timeColumnWidth + 3 + self.theme.metrics.spacing.md * 2)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(self.theme.palette.accent.opacity(self.isJoinable ? 0.05 : (self.isHovered ? 0.03 : 0)))
        .animation(self.reduceMotion ? nil : .easeOut(duration: 0.14), value: self.isHovered)
        .contentShape(Rectangle())
        .onHover { self.isHovered = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(self.accessibilityLabel)
    }

    private static let timeColumnWidth: CGFloat = 64

    private var when: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(MeetingUpcomingEventsPolicy.startTime(for: self.event))
                .font(self.theme.typography.bodyStrong)
                .monospacedDigit()
                .foregroundStyle(self.theme.palette.primaryText)
            Text(MeetingUpcomingEventsPolicy.dayLabel(for: self.event, at: self.now))
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.secondaryText)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(width: Self.timeColumnWidth, alignment: .trailing)
        .accessibilityHidden(true)
    }

    /// The calendar's color as a slim bar; hollow while the invitation is not accepted yet.
    private var colorBar: some View {
        Capsule()
            .fill(self.calendarColor.opacity(self.event.isTentative ? 0.25 : 1))
            .overlay {
                if self.event.isTentative {
                    Capsule().strokeBorder(self.calendarColor, lineWidth: 1)
                }
            }
            .frame(width: 3, height: 34)
            .accessibilityHidden(true)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(self.event.title)
                .font(self.theme.typography.bodyStrong)
                .foregroundStyle(self.theme.palette.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)
            HStack(spacing: self.theme.metrics.spacing.xs) {
                ForEach(Array(MeetingUpcomingEventsPolicy.detailParts(for: self.event).enumerated()), id: \.offset) { index, part in
                    if index > 0 {
                        Text("·").foregroundStyle(self.theme.palette.tertiaryText)
                    }
                    Text(part)
                }
            }
            .font(self.theme.typography.caption)
            .foregroundStyle(self.theme.palette.secondaryText)
            .lineLimit(1)
        }
        .layoutPriority(1)
        .accessibilityHidden(true)
    }

    private var status: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(self.theme.palette.accent)
                .frame(width: 6, height: 6)
            Text(MeetingUpcomingEventsPolicy.joinStatus(for: self.event, at: self.now))
        }
        .font(self.theme.typography.captionStrong)
        .foregroundStyle(self.theme.palette.accent)
        .padding(.horizontal, self.theme.metrics.spacing.sm)
        .padding(.vertical, 3)
        .background(self.theme.palette.accent.opacity(0.12), in: Capsule())
        .fixedSize()
        .accessibilityHidden(true)
    }

    private var transcribeAction: some View {
        Button(action: self.onTranscribe) {
            Label(self.isStarting ? "Starting…" : "Transcribe", systemImage: self.isStarting ? "hourglass" : "record.circle")
        }
        .meetingGlassAction(prominent: true, tone: self.theme.palette.accent)
        .disabled(!self.isEnabled)
        .help(self.isLive ? "Record this call" : "Open the call and record it")
        .accessibilityLabel(self.isLive ? "Transcribe \(self.event.title)" : "Open and transcribe \(self.event.title)")
    }

    private var joinAction: some View {
        Button(action: self.onJoin) {
            Label("Join", systemImage: "arrow.up.right")
                .foregroundStyle(self.theme.palette.accent)
        }
        .meetingGlassAction()
        .disabled(!self.isEnabled)
        .help("Open the call link")
        .accessibilityLabel("Join \(self.event.title)")
    }

    private var accessibilityLabel: String {
        let details = MeetingUpcomingEventsPolicy.detailParts(for: self.event).joined(separator: ", ")
        let when = self.isJoinable
            ? MeetingUpcomingEventsPolicy.joinStatus(for: self.event, at: self.now)
            : "\(MeetingUpcomingEventsPolicy.dayLabel(for: self.event, at: self.now)) at \(MeetingUpcomingEventsPolicy.startTime(for: self.event))"
        return "\(self.event.title), \(when), \(details)"
    }
}

import SwiftUI

/// FluidMeet's "Upcoming events": the next calendar events, with Join and Transcribe on a call
/// that is about to start or running. Hidden until calendar access is granted.
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
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
                Text("Upcoming events")
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .padding(.horizontal, self.theme.metrics.spacing.md)
                    .padding(.bottom, self.theme.metrics.spacing.xs)
                    .accessibilityAddTraits(.isHeader)

                if self.model.events.isEmpty {
                    Text("Nothing on your calendar for the next seven days.")
                        .font(self.theme.typography.body)
                        .foregroundStyle(self.theme.palette.secondaryText)
                        .padding(.horizontal, self.theme.metrics.spacing.md)
                } else {
                    ForEach(self.visibleEvents) { event in
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
                    if self.model.events.count > MeetingUpcomingEventsPolicy.collapsedLimit {
                        self.viewAllButton
                    }
                }

                if let errorMessage = self.model.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(self.theme.typography.bodySmall)
                        .foregroundStyle(self.theme.palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, self.theme.metrics.spacing.md)
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
        }
    }

    private var viewAllButton: some View {
        Button {
            self.showsAll.toggle()
        } label: {
            HStack(spacing: self.theme.metrics.spacing.md) {
                Image(systemName: self.showsAll ? "chevron.up" : "ellipsis")
                    .frame(width: 12)
                Text(self.showsAll ? "Show fewer" : "View all")
                Spacer(minLength: 0)
            }
            .font(self.theme.typography.body)
            .foregroundStyle(self.theme.palette.secondaryText)
            .padding(.horizontal, self.theme.metrics.spacing.md)
            .padding(.vertical, self.theme.metrics.spacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .meetingHoverFeedback(cornerRadius: 10)
        .accessibilityLabel(self.showsAll ? "Show fewer upcoming events" : "View all upcoming events")
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

    private var isJoinable: Bool {
        self.isLive || MeetingUpcomingEventsPolicy.isJoinable(self.event, at: self.now)
    }

    private var swatch: Color {
        guard let color = self.event.calendarColor else { return self.theme.palette.secondaryText }
        return Color(.sRGB, red: color.red, green: color.green, blue: color.blue)
    }

    var body: some View {
        HStack(spacing: self.theme.metrics.spacing.md) {
            Group {
                if self.event.isTentative {
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(self.swatch, style: StrokeStyle(lineWidth: 1.5, dash: [2.5, 2]))
                } else {
                    RoundedRectangle(cornerRadius: 3).fill(self.swatch)
                }
            }
            .frame(width: 12, height: 12)
            .accessibilityHidden(true)

            Text(self.event.title)
                .font(self.theme.typography.body)
                .foregroundStyle(self.theme.palette.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)

            Spacer(minLength: self.theme.metrics.spacing.md)

            if self.isJoinable {
                Button("Join", action: self.onJoin)
                    .buttonStyle(.plain)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .disabled(!self.isEnabled)
                    .help("Open the call link")
                Button(action: self.onTranscribe) {
                    Text(self.isStarting ? "Starting…" : "Transcribe")
                        .padding(.horizontal, self.theme.metrics.spacing.sm)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .disabled(!self.isEnabled)
                .help(self.isLive ? "Record this call" : "Open the call and record it")
            } else {
                Text(MeetingUpcomingEventsPolicy.timeLabel(for: self.event, at: self.now))
                    .font(self.theme.typography.body)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .font(self.theme.typography.body)
        .padding(.horizontal, self.theme.metrics.spacing.md)
        .padding(.vertical, self.theme.metrics.spacing.sm)
        .background {
            if self.isJoinable {
                RoundedRectangle(cornerRadius: 10).fill(self.theme.palette.secondaryText.opacity(0.08))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(self.accessibilityLabel)
    }

    private var accessibilityLabel: String {
        let tentative = self.event.isTentative ? ", not yet accepted" : ""
        return self.isJoinable
            ? "\(self.event.title)\(tentative), \(self.now < self.event.start ? "starting soon" : "happening now")"
            : "\(self.event.title)\(tentative), \(MeetingUpcomingEventsPolicy.timeLabel(for: self.event, at: self.now))"
    }
}

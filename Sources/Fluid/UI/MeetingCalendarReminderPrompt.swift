import AppKit
import Combine
import SwiftUI

/// Floating reminder for an upcoming calendar call, in the same surface and position as the
/// "Record this meeting?" prompt. It stays until the user acts or the late-join window passes.
@MainActor
final class MeetingCalendarReminderController: ObservableObject {
    static let shared = MeetingCalendarReminderController()

    static let panelSize = NSSize(width: 392, height: 120)

    @Published private(set) var reminder: MeetingCalendarReminder?
    @Published private(set) var isStarting = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var now = Date()

    private var panel: MeetingFloatingCaptionsPanel?
    private var clockTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?

    private init() {}

    func present(_ reminder: MeetingCalendarReminder) {
        self.reminder = reminder
        self.isStarting = false
        self.errorMessage = nil
        self.now = Date()
        let panel = self.panelOrCreate()
        let screen = OverlayScreenResolver.screenForCurrentPointer() ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.setFrame(MeetingDetectionPromptController.defaultFrame(panelSize: Self.panelSize, visibleFrame: visible), display: false)
        }
        panel.orderFrontRegardless()
        AccessibilityNotification.Announcement("\(reminder.title). Open the meeting, or open and transcribe it.").post()
        self.clockTask?.cancel()
        self.clockTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard let self, let reminder = self.reminder else { return }
                self.now = Date()
                let expiry = reminder.start.addingTimeInterval(MeetingCalendarReminderPolicy.lateJoinWindow)
                if !self.isStarting, self.now >= min(expiry, reminder.end) {
                    DebugLogger.shared.info("reminder-expired", source: "MeetingCalendarReminders")
                    self.hide()
                    return
                }
            }
        }
    }

    func openTapped() {
        guard let reminder, !self.isStarting else { return }
        NSWorkspace.shared.open(reminder.conferenceURL)
        DebugLogger.shared.info("reminder-open", source: "MeetingCalendarReminders")
        self.hide()
    }

    func openAndTranscribeTapped() {
        guard let reminder, !self.isStarting else { return }
        self.isStarting = true
        self.errorMessage = nil
        DebugLogger.shared.info("reminder-open-and-transcribe", source: "MeetingCalendarReminders")
        self.startTask = Task { @MainActor [weak self] in
            do {
                try await AppServices.shared.openCalendarMeetingAndRecord(reminder)
                guard let self, self.reminder?.id == reminder.id else { return }
                self.hide()
            } catch is CancellationError {
                return
            } catch {
                DebugLogger.shared.warning("reminder-start-failed error=\(error)", source: "MeetingCalendarReminders")
                guard let self, self.reminder?.id == reminder.id else { return }
                self.isStarting = false
                self.errorMessage = MeetingDetectionPromptController.startErrorMessage(
                    from: error,
                    appDisplayName: reminder.serviceName ?? "The meeting app"
                )
            }
        }
    }

    func dismissTapped() {
        guard !self.isStarting else { return }
        DebugLogger.shared.info("reminder-dismissed", source: "MeetingCalendarReminders")
        self.hide()
    }

    /// A recording started some other way covers this meeting, so the reminder is no longer needed.
    func dismissIfIdle() {
        guard self.reminder != nil, !self.isStarting else { return }
        self.hide()
    }

    private func hide() {
        self.clockTask?.cancel()
        self.clockTask = nil
        self.startTask = nil
        self.isStarting = false
        self.errorMessage = nil
        self.panel?.orderOut(nil)
        self.reminder = nil
    }

    private func panelOrCreate() -> MeetingFloatingCaptionsPanel {
        if let panel { return panel }
        let content = AnyView(
            MeetingOverlayThemed {
                MeetingCalendarReminderContent(controller: self)
            }
        )
        let panel = MeetingFloatingPanelFactory.make(size: Self.panelSize, resizable: false, content: content)
        self.panel = panel
        return panel
    }
}

private struct MeetingCalendarReminderContent: View {
    @ObservedObject var controller: MeetingCalendarReminderController

    @Environment(\.theme) private var theme
    @Environment(\.meetingOverlayAppearance) private var overlayAppearance

    private var subtitle: String {
        guard let reminder = self.controller.reminder else { return "" }
        let start = MeetingCalendarReminderPolicy.startDescription(start: reminder.start, now: self.controller.now)
        return reminder.serviceName.map { "\(start) · \($0)" } ?? start
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "calendar")
                    .font(.fluidSystem(size: 18, weight: .semibold))
                    .foregroundStyle(self.theme.palette.accent)
                    .frame(width: 34, height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(self.theme.palette.accent.opacity(0.12))
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(self.controller.reminder?.title ?? "")
                        .font(self.theme.typography.bodyStrong)
                        .foregroundStyle(self.theme.palette.primaryText)
                        .lineLimit(1)
                    Text(self.subtitle)
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    self.controller.dismissTapped()
                } label: {
                    Image(systemName: "xmark")
                        .font(.fluidSystem(size: 10, weight: .bold))
                        .foregroundStyle(self.theme.palette.secondaryText)
                        .frame(width: 22, height: 22)
                        .background(self.theme.palette.primaryText.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(self.controller.isStarting)
                .help("Dismiss")
                .accessibilityLabel("Dismiss meeting reminder")
            }

            HStack(spacing: 8) {
                if let errorMessage = self.controller.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.warning)
                        .lineLimit(1)
                } else if self.controller.isStarting {
                    Label("Starting…", systemImage: "waveform")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                }

                Spacer(minLength: 8)

                Button("Open") {
                    self.controller.openTapped()
                }
                .fluidButton(.compact, size: .small)
                .disabled(self.controller.isStarting)

                Button {
                    self.controller.openAndTranscribeTapped()
                } label: {
                    Label("Open & Transcribe", systemImage: "record.circle")
                }
                .fluidButton(.accent, size: .small)
                .disabled(self.controller.isStarting)
            }
        }
        .padding(14)
        .frame(
            width: MeetingCalendarReminderController.panelSize.width,
            height: MeetingCalendarReminderController.panelSize.height,
            alignment: .top
        )
        .bottomOverlaySurface(self.overlayAppearance, cornerRadius: 16, castsShadow: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(self.controller.reminder?.title ?? "Meeting"). \(self.subtitle). Open, or open and transcribe.")
    }
}

import SwiftUI

struct MeetingSummaryView: View {
    var session: MeetingSession? = nil
    var asrService: ASRService? = nil
    var isQuiescent = true
    @Environment(\.theme) private var theme
    @StateObject private var controller = MeetingSummaryController()
    @State private var confirmDeletion = false
    @State private var kind = MeetingSummaryKind.executive

    private var refreshID: String {
        "\(self.session?.id.uuidString ?? "home")-\(self.session?.updatedAt.timeIntervalSince1970 ?? 0)-\(self.kind.rawValue)"
    }

    private var hint: String {
        guard let engine = self.controller.engine else {
            return "Meeting summaries need an AI provider. Choose one in AI Providers."
        }
        if self.session == nil, self.controller.installed {
            return "Open a completed meeting to summarize its transcript."
        }
        if case let .cloud(route) = engine {
            return "Summaries, decisions, and action items, written by \(route.providerName)."
        }
        return "Summaries, decisions, and action items, generated on your Mac."
    }

    private var isCloud: Bool {
        if case .cloud = self.controller.engine {
            return true
        }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.lg) {
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
                Text("Your meeting, summed up.")
                    .font(.system(.title3, design: .serif).weight(.medium))
                    .foregroundStyle(self.theme.palette.primaryText)
                    .accessibilityAddTraits(.isHeader)
                Text(self.hint)
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.theme.palette.secondaryText)
                if self.controller.engine == nil, !self.controller.checking {
                    Button("Open AI Providers") { AppNavigationRouter.shared.request(.aiEnhancements) }
                        .buttonStyle(.link)
                        .font(self.theme.typography.bodySmall)
                        .accessibilityIdentifier("meeting-summary-open-ai-providers")
                }
            }
            if self.controller.engine != nil {
                HStack(spacing: self.theme.metrics.spacing.sm) {
                    if self.controller.installed {
                        Picker("Summary type", selection: self.$kind) {
                            ForEach(MeetingSummaryKind.allCases) { kind in Text(kind.title).tag(kind) }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fluidDropdownStyle()
                        .fixedSize()
                        .disabled(self.controller.busy)
                    }
                    self.actions
                }
                if self.controller.downloading {
                    Text(PrivateAIModelDownloadProgressText.detailText(for: self.controller.progress))
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                }
                if let error = self.controller.error {
                    Text(error).font(self.theme.typography.bodySmall).foregroundStyle(self.theme.palette.warning)
                        .textSelection(.enabled)
                }
                if !self.controller.output.isEmpty {
                    CommandMarkdownContent(text: self.controller.output)
                }
            }
            switch self.controller.engine {
            case let .cloud(route):
                HStack(spacing: self.theme.metrics.spacing.sm) {
                    Label("\(route.providerName) · \(route.model) · Sends the transcript to this provider", systemImage: "cloud")
                        .foregroundStyle(self.theme.palette.tertiaryText)
                    Button("Change") { AppNavigationRouter.shared.request(.aiEnhancements) }
                        .buttonStyle(.link)
                        .help("Choose the default text provider in AI Providers")
                        .accessibilityIdentifier("meeting-summary-change-provider")
                }
                .font(self.theme.typography.caption)
            case .onDevice:
                Label("On-device · English · Frees its memory when done", systemImage: "lock")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.tertiaryText)
            case nil:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, self.theme.metrics.spacing.md)
        .task(id: self.refreshID) { await self.controller.refresh(session: self.session, kind: self.kind) }
        .onDisappear { self.controller.cancel() }
        .alert("Delete summary model?", isPresented: self.$confirmDeletion) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let asrService {
                    self.controller.deleteModel(asr: asrService)
                }
            }
        } message: {
            Text("Remove the 1.45 GB download from this Mac. Your meetings and saved summaries stay. You can download it again anytime.")
        }
    }

    private var actions: some View {
        FluidGlassControlGroup {
            HStack(spacing: self.theme.metrics.spacing.sm) {
                if self.controller.checking {
                    ProgressView().controlSize(.small)
                } else if self.controller.downloading {
                    Button {} label: {
                        VStack(spacing: 4) {
                            Text(PrivateAIModelDownloadProgressText.buttonTitle(for: self.controller.progress))
                            ProgressView(value: self.controller.progress?.fractionCompleted)
                                .progressViewStyle(.linear)
                                .frame(width: 160)
                                .controlSize(.mini)
                        }
                    }
                    .fluidGlassAction()
                    .disabled(true)
                    Button("Cancel") { self.controller.cancel() }.fluidGlassAction()
                } else if self.controller.deleting {
                    ProgressView().controlSize(.small)
                    Text("Deleting download…").font(self.theme.typography.bodySmall)
                } else if !self.controller.installed {
                    Button("Download · 1.45 GB", systemImage: "arrow.down.circle") { self.controller.download() }
                        .fluidGlassAction(prominent: true)
                        .disabled(!self.isQuiescent)
                } else if self.controller.generating {
                    ProgressView().controlSize(.small)
                    Text("Summarizing…").font(self.theme.typography.bodySmall)
                    Button("Cancel") { self.controller.cancel() }.fluidGlassAction()
                } else {
                    Button("Summarize", systemImage: "sparkles") {
                        if let session {
                            self.controller.summarize(session: session, kind: self.kind, asr: self.asrService)
                        }
                    }
                    .fluidGlassAction(prominent: true)
                    .disabled(self.session?.transcriptSegments.isEmpty != false || (!self.isCloud && self.asrService == nil) || !self.isQuiescent)
                }
                if !self.isCloud {
                    self.modelMenu
                }
                if !self.controller.output.isEmpty {
                    Button("Copy", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(self.controller.output, forType: .string)
                    }
                    .fluidGlassAction()
                    .disabled(self.controller.generating)
                }
            }
        }
    }

    private var modelMenu: some View {
        Menu {
            Button("Delete model", systemImage: "trash", role: .destructive) {
                self.confirmDeletion = true
            }
            .disabled(!self.controller.installed || self.controller.busy || self.controller.checking || !self.isQuiescent || self.asrService == nil)
        } label: { Image(systemName: "ellipsis") }
            .menuIndicator(.hidden)
            .fluidGlassAction(circular: true)
            .accessibilityLabel("Meeting summary actions")
            .disabled(self.controller.busy)
    }
}

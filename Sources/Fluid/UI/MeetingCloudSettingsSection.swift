import SwiftUI

struct MeetingCloudSettingsSection: View {
    let onOpenVoiceEngine: () -> Void
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.theme) private var theme

    private var usesCloud: Bool { self.settings.meetingTranscriptionBackendID == .openRouterNemotron }

    var body: some View {
        FluidManagementGroup(title: "Completed meeting transcripts") {
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
                Picker("Transcription", selection: Binding(
                    get: { self.usesCloud },
                    set: { self.settings.meetingTranscriptionBackendID = $0 ? .openRouterNemotron : .parakeetNemotron }
                )) {
                    Text("Local").tag(false)
                    Text("OpenRouter").tag(true)
                }
                .pickerStyle(.segmented)

                if self.usesCloud {
                    Picker("Meeting model", selection: self.$settings.meetingCloudModelID) {
                        ForEach(CloudTranscriptionModel.catalog.filter(\.supportsWordTimings), id: \.id) { model in
                            Text(model.name).tag(model.id)
                        }
                    }
                    Picker("Transcript language", selection: self.$settings.meetingCloudLanguageCode) {
                        ForEach(MeetingCloudLanguage.choices, id: \.code) { language in
                            Text(language.name).tag(language.code)
                        }
                    }
                    Text("Recorded audio is sent to OpenRouter. Speaker detection stays on this Mac. Charges apply to audio duration.")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                    Button(self.settings.openRouterTranscriptionAPIKey.isEmpty
                        ? "Add OpenRouter key in Voice Engine" : "Manage OpenRouter key in Voice Engine", action: self.onOpenVoiceEngine)
                        .meetingGlassAction()
                } else {
                    Text("Parakeet transcribes English on this Mac.")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                }
                Text("Live captions remain local and English-only. Changes apply when the next transcription starts.")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
            }
        }
    }
}

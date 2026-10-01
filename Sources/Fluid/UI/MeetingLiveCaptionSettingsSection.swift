import SwiftUI

/// Chooses where live captions come from: the on-device English model, or a provider added under
/// Voice Engine > Live cloud. The completed transcript is configured separately.
struct MeetingLiveCaptionSettingsSection: View {
    let onOpenVoiceEngine: () -> Void
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.theme) private var theme

    var body: some View {
        FluidManagementGroup(title: "Live captions") {
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
                Picker("Live captions", selection: self.$settings.meetingLiveCaptionProvider) {
                    Text("On this Mac (English)").tag(LiveTranscriptionProviderID?.none)
                    ForEach(self.choices) { provider in
                        Text("\(Self.name(of: provider)) · Live cloud").tag(Optional(provider))
                    }
                    if let selected = self.settings.meetingLiveCaptionProvider, !self.choices.contains(selected) {
                        Text("\(Self.name(of: selected)) (key required)").tag(Optional(selected))
                    }
                }
                .accessibilityIdentifier("meeting-live-caption-source")

                Text(self.detail)
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if self.choices.isEmpty || self.selectedNeedsKey {
                    Button("Open Voice Engine", action: self.onOpenVoiceEngine)
                        .meetingGlassAction()
                }
            }
        }
    }

    private var choices: [LiveTranscriptionProviderID] { self.settings.meetingLiveCaptionProviderChoices }

    private var selectedNeedsKey: Bool {
        self.settings.meetingLiveCaptionProvider.map { !self.choices.contains($0) } ?? false
    }

    private var detail: String {
        guard let provider = self.settings.meetingLiveCaptionProvider else {
            let upsell = self.choices.isEmpty
                ? " To caption other languages, add a provider and its API key under Voice Engine > Live cloud."
                : ""
            return "Captions run on this Mac and support English only.\(upsell) Changes apply when the next recording starts."
        }
        let name = Self.name(of: provider)
        if self.selectedNeedsKey {
            return "\(name) has no saved API key, so captions stay off until you add one under Voice Engine > Live cloud."
        }
        let model = LiveTranscriptionCatalog.info(for: provider).models
            .first { $0.id == LiveTranscriptionPreferences(defaults: .standard).modelID(for: provider) }?.name ?? ""
        return [
            "While you record, meeting audio streams to \(name) (\(model)) with your key.",
            "Online calls stream your microphone and the call audio separately, and \(name) bills each stream for the whole recording.",
            "Captions use \(self.languageDescription(for: provider)).",
            "Speaker detection and the completed transcript are unaffected. Changes apply when the next recording starts.",
        ].joined(separator: " ")
    }

    /// Mirrors `SettingsStore.meetingLiveCaptionSource`: a language the provider does not list is
    /// detected automatically when the provider can.
    private func languageDescription(for provider: LiveTranscriptionProviderID) -> String {
        let info = LiveTranscriptionCatalog.info(for: provider)
        let code = self.settings.meetingLiveCaptionLanguageCode
        guard code != MeetingCloudLanguage.automatic else {
            return info.detectsLanguageAutomatically ? "automatic language detection" : "your Primary language"
        }
        let name = Locale.current.localizedString(forLanguageCode: code) ?? code
        guard info.supports(languageCode: code) || !info.detectsLanguageAutomatically else {
            return "automatic language detection, because \(info.name) does not list \(name)"
        }
        return name
    }

    private static func name(of provider: LiveTranscriptionProviderID) -> String {
        LiveTranscriptionCatalog.info(for: provider).name
    }
}

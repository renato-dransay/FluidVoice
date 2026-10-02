import SwiftUI

/// Primary and Secondary dictation languages, shared by Cloud and Live cloud.
struct DictationLanguageControls: View {
    @ObservedObject var settings: SettingsStore
    let caption: String
    /// An engine-specific note under the pickers; empty shows none.
    var footnote = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Dictation language", systemImage: "globe")
                .font(.callout)
            Text(self.caption)
                .font(.caption).foregroundStyle(.secondary)
            self.languageHintPicker(
                "Primary language",
                selection: Binding(
                    get: { self.settings.cloudTranscriptionPrimaryLanguageCode ?? "none" },
                    set: { self.settings.cloudTranscriptionPrimaryLanguageCode = $0 == "none" ? nil : $0 }
                )
            )
            .accessibilityIdentifier("cloud-primary-language")
            self.languageHintPicker(
                "Secondary language",
                selection: Binding(
                    get: { self.settings.cloudTranscriptionSecondaryLanguageCode ?? "none" },
                    set: { self.settings.cloudTranscriptionSecondaryLanguageCode = $0 == "none" ? nil : $0 }
                ),
                excluding: self.settings.cloudTranscriptionPrimaryLanguageCode
            )
            .disabled(self.settings.cloudTranscriptionPrimaryLanguageCode == nil)
            .accessibilityIdentifier("cloud-secondary-language")
            ForEach(self.unlistedLanguageWarnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if !self.footnote.isEmpty {
                Text(self.footnote)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Warnings for Primary or Secondary languages the active live provider does not list.
    private var unlistedLanguageWarnings: [String] {
        [self.settings.cloudTranscriptionPrimaryLanguageCode, self.settings.cloudTranscriptionSecondaryLanguageCode]
            .compactMap { $0 }
            .compactMap { code in
                guard let provider = self.settings.liveProviderLackingLanguage(code) else { return nil }
                return Self.unlistedLanguageWarning(provider: provider, languageCode: code)
            }
    }

    static func unlistedLanguageWarning(provider: String, languageCode: String) -> String {
        let language = VoiceEngineLanguageCatalog.whisperLanguage(forCode: languageCode)?.displayName ?? languageCode
        return "\(provider) doesn't list \(language). Dictation in \(language) may come back in another language."
    }

    private func languageHintPicker(_ title: String, selection: Binding<String>, excluding excludedCode: String? = nil) -> some View {
        Picker(title, selection: selection) {
            Text("None (optional)").tag("none")
            ForEach(VoiceEngineLanguageCatalog.whisperLanguages.filter { $0.id.count == 2 && $0.id != excludedCode }) { language in
                Text(language.displayName).tag(language.id)
            }
        }
    }
}

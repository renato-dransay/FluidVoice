import SwiftUI

/// The one API key field for the Add sheet, the Manage sheet and onboarding. It edits a draft only;
/// the owner saves it (on Add, on Done, before Verify). Emptying the field removes nothing: only
/// `Remove key` does.
struct ProviderAPIKeyField: View {
    @Environment(\.theme) private var theme
    @Binding var text: String
    let hasSavedKey: Bool
    var isOptional = false
    var link: (title: String, url: URL)?
    /// Shows `Remove key` while a key is saved.
    var removeKey: (() -> Void)?
    var isRemovalDisabled = false
    var removalHelp = ""
    var onFocus: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(self.isOptional ? "API key · Optional" : "API key").font(self.theme.typography.bodyStrong)
            SecureField(self.hasSavedKey ? "Replace saved API key" : "Enter API key", text: self.$text)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .accessibilityLabel("API key")
                .onTapGesture { self.onFocus?() }
            if self.hasSavedKey {
                HStack(spacing: 12) {
                    Label("Key saved in macOS Keychain", systemImage: "lock.fill")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                    if let removeKey = self.removeKey {
                        Button("Remove key", role: .destructive, action: removeKey)
                            .buttonStyle(.link)
                            .disabled(self.isRemovalDisabled)
                            .help(self.removalHelp)
                    }
                }
            }
            if let link = self.link {
                Link(destination: link.url) {
                    Label(link.title, systemImage: "arrow.up.right").font(self.theme.typography.caption)
                }
            }
        }
    }
}

/// Re-renders only its content when a recording starts or stops, so a settings page does not
/// follow every change the recognizer publishes.
struct RecordingStateReader<Content: View>: View {
    @ObservedObject var asr: ASRService
    @ViewBuilder let content: (_ isRecording: Bool) -> Content

    @MainActor
    init(asr: ASRService? = nil, @ViewBuilder content: @escaping (_ isRecording: Bool) -> Content) {
        self.asr = asr ?? AppServices.shared.asr
        self.content = content
    }

    var body: some View {
        self.content(self.asr.isRunning)
    }
}

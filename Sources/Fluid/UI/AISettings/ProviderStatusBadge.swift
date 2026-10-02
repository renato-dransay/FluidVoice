import SwiftUI

/// The one status a provider shows on its AI Providers row and connection line.
enum ProviderStatus: CaseIterable, Equatable {
    case apiKeyMissing
    case chooseModel
    case notVerified
    case verifying
    case verified
    case verificationFailed

    var text: String {
        switch self {
        case .apiKeyMissing: "API key missing"
        case .chooseModel: "Choose a model"
        case .notVerified: "Not verified"
        case .verifying: "Verifying…"
        case .verified: "Verified"
        case .verificationFailed: "Verification failed"
        }
    }

    /// Nil while verifying: the badge shows a progress indicator instead.
    var systemImage: String? {
        switch self {
        case .apiKeyMissing, .chooseModel: "exclamationmark.circle"
        case .notVerified: "circle.dashed"
        case .verifying: nil
        case .verified: "checkmark.circle.fill"
        case .verificationFailed: "exclamationmark.circle.fill"
        }
    }

    /// A text provider's status, from `DictationDefaultProvider.setupIssue` (nil means verified).
    static func text(setupIssue: String?, isVerifying: Bool) -> ProviderStatus {
        if isVerifying { return .verifying }
        guard let setupIssue else { return .verified }
        return Self.allCases.first { $0.text == setupIssue } ?? .notVerified
    }

    /// A speech status: the key and the speech check only; there is no model to choose here.
    static func speech(hasAPIKey: Bool, isVerifying: Bool, isVerified: Bool, verificationFailed: Bool) -> ProviderStatus {
        if !hasAPIKey { return .apiKeyMissing }
        if isVerifying { return .verifying }
        if verificationFailed { return .verificationFailed }
        return isVerified ? .verified : .notVerified
    }
}

/// Icon plus text, for AI Providers rows and the Cloud tab connection line.
struct ProviderStatusBadge: View {
    @Environment(\.theme) private var theme
    let status: ProviderStatus

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage = self.status.systemImage {
                Image(systemName: systemImage)
            } else {
                ProgressView().controlSize(.mini)
            }
            Text(self.status.text)
        }
        .font(self.theme.typography.caption)
        .foregroundStyle(self.color)
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch self.status {
        case .apiKeyMissing, .verificationFailed: .red
        case .chooseModel: .orange
        case .notVerified: self.theme.palette.secondaryText
        case .verifying: self.theme.palette.accent
        case .verified: Color.fluidGreen
        }
    }
}

/// The outcome of a save, removal or check shown in a provider sheet: a value, not a shared string.
enum ProviderActionResult: Equatable {
    case success(String)
    case failure(String)
}

struct ProviderActionResultLabel: View {
    @Environment(\.theme) private var theme
    let result: ProviderActionResult

    var body: some View {
        switch self.result {
        case let .success(message):
            Label(message, systemImage: ProviderStatus.verified.systemImage ?? "checkmark.circle.fill")
                .font(self.theme.typography.caption)
                .foregroundStyle(Color.fluidGreen)
        case let .failure(message):
            Label(message, systemImage: ProviderStatus.verificationFailed.systemImage ?? "exclamationmark.circle.fill")
                .font(self.theme.typography.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

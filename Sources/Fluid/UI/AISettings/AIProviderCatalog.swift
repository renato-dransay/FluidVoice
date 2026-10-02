import Foundation

extension ProviderCapability {
    /// The tag on an AI Providers row and the words on an Add sheet tile.
    var title: String {
        switch self {
        case .text: "Text"
        case .cloudTranscription: "Cloud transcription"
        case .liveTranscription: "Live"
        }
    }

    /// Tags read Text, Cloud transcription, Live, in that order.
    static func ordered(_ capabilities: Set<ProviderCapability>) -> [ProviderCapability] {
        self.allCases.filter(capabilities.contains)
    }
}

/// The segmented filter above the AI Providers list, shown once the list has more than six rows.
enum AIProviderListFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case text = "Text"
    case transcription = "Transcription"
    case live = "Live"

    static let rowCountBeforeFilter = 6

    var id: String { self.rawValue }

    static func isShown(rowCount: Int) -> Bool {
        rowCount > self.rowCountBeforeFilter
    }

    /// `Transcription` matches Cloud transcription.
    func matches(_ capabilities: Set<ProviderCapability>) -> Bool {
        switch self {
        case .all: true
        case .text: capabilities.contains(.text)
        case .transcription: capabilities.contains(.cloudTranscription)
        case .live: capabilities.contains(.liveTranscription)
        }
    }
}

/// What the AI Providers page shows for a provider, decided from the registry alone so the page's
/// rules are testable without the app's settings.
enum AIProviderCatalog {
    static let localProviderIDs: Set<String> = ["ollama", "lmstudio"]

    /// A custom provider (not in the registry) has Text only.
    static func capabilities(for providerID: String) -> Set<ProviderCapability> {
        ProviderRegistry.descriptor(for: providerID)?.capabilities ?? [.text]
    }

    /// A registry provider without Text. It is connected by its key alone and is never a text provider.
    static func isSpeechOnly(_ providerID: String) -> Bool {
        guard let descriptor = ProviderRegistry.descriptor(for: providerID) else { return false }
        return !descriptor.capabilities.contains(.text)
    }

    /// Custom providers and local servers take an optional key.
    static func requiresAPIKey(_ providerID: String) -> Bool {
        ProviderRegistry.descriptor(for: providerID)?.requiresAPIKey ?? false
    }

    static func name(for providerID: String) -> String? {
        ProviderRegistry.descriptor(for: providerID)?.name
    }

    /// The speech-only providers with a saved key: the rows AI Providers adds to its text providers.
    static func speechOnlyProviders(withKeys apiKeys: [String: String]) -> [ProviderDescriptor] {
        ProviderRegistry.all.filter { descriptor in
            let key = apiKeys[descriptor.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return self.isSpeechOnly(descriptor.id) && !key.isEmpty
        }
    }

    /// The second line of an Add sheet tile.
    static func capabilitySummary(for providerID: String) -> String {
        if self.localProviderIDs.contains(providerID) { return "Local connection" }
        return ProviderCapability.ordered(self.capabilities(for: providerID)).map(\.title).joined(separator: " · ")
    }

    /// The Add sheet grid: every registry provider not connected yet, limited to one capability when given.
    static func addableProviders(capability: ProviderCapability?, connectedProviderIDs: Set<String>) -> [ProviderDescriptor] {
        ProviderRegistry.all.filter { descriptor in
            !connectedProviderIDs.contains(descriptor.id)
                && (capability.map { descriptor.capabilities.contains($0) } ?? true)
        }
    }

    /// A capability-filtered grid offers Custom Provider only for Text.
    static func offersCustomProvider(for capability: ProviderCapability?) -> Bool {
        capability == nil || capability == .text
    }

    /// The link below the key field: "Setup guide" where the provider's website entry is a setup guide
    /// (Ollama, LM Studio), "Get an API key" everywhere else.
    static func keyLink(for providerID: String) -> (title: String, url: URL)? {
        if let website = ModelRepository.providerWebsiteURL(for: providerID), let url = URL(string: website.url) {
            return (website.label == "Setup Guide" ? "Setup guide" : "Get an API key", url)
        }
        guard let url = ProviderRegistry.descriptor(for: providerID)?.keyURL else { return nil }
        return ("Get an API key", url)
    }
}

import Foundation

/// The screen a provider setup was opened from, so it can offer the way back.
enum ProviderSetupOrigin: Equatable {
    case voiceEngine(tab: SpeechExecutionSource)
    case fluidMeet
    case cleanupStyles
    case commandMode
    case fileTranscription
}

enum AppNavigationDestination: Equatable {
    case aiEnhancements
    case history
    case dictationShortcuts
    case meetingTranscription
    /// AI Providers, on the given provider.
    case aiProvider(id: String, origin: ProviderSetupOrigin?)
    /// AI Providers, adding a provider, optionally limited to one capability.
    case addProvider(capability: ProviderCapability?, origin: ProviderSetupOrigin?)
    /// Voice Engine, browsing the given tab, or the active engine's tab when nil.
    case voiceEngine(tab: SpeechExecutionSource?)

    /// The app page the destination opens, or nil for a destination inside Settings.
    var sidebarItem: SidebarItem? {
        switch self {
        case .aiEnhancements, .aiProvider, .addProvider: .aiEnhancements
        case .history: .history
        case .dictationShortcuts: nil
        case .meetingTranscription: .meetingTranscription
        case .voiceEngine: .voiceEngine
        }
    }
}

/// Pending navigation requests. A requested Voice Engine tab is kept apart from the destination
/// because the page consumes it when it appears, after the app has switched pages.
struct AppNavigationRequests: Equatable {
    private var pendingDestination: AppNavigationDestination?
    private var pendingVoiceEngineTab: SpeechExecutionSource?

    mutating func request(_ destination: AppNavigationDestination) {
        self.pendingDestination = destination
        // A later request to another page drops a tab nobody browsed.
        if case let .voiceEngine(tab) = destination {
            self.pendingVoiceEngineTab = tab
        } else {
            self.pendingVoiceEngineTab = nil
        }
    }

    mutating func consumeDestination() -> AppNavigationDestination? {
        defer { self.pendingDestination = nil }
        return self.pendingDestination
    }

    mutating func consumeVoiceEngineTab() -> SpeechExecutionSource? {
        defer { self.pendingVoiceEngineTab = nil }
        return self.pendingVoiceEngineTab
    }
}

@MainActor
final class AppNavigationRouter {
    static let shared = AppNavigationRouter()

    private var requests = AppNavigationRequests()

    private init() {}

    func request(_ destination: AppNavigationDestination) {
        self.requests.request(destination)
        NotificationCenter.default.post(name: .appNavigationRequested, object: nil)
    }

    func consumePendingDestination() -> AppNavigationDestination? {
        self.requests.consumeDestination()
    }

    /// The Voice Engine tab a request asked for, once; the page browses it instead of the active engine's tab.
    func consumeRequestedVoiceEngineTab() -> SpeechExecutionSource? {
        self.requests.consumeVoiceEngineTab()
    }
}

extension Notification.Name {
    static let appNavigationRequested = Notification.Name("AppNavigationRequested")
    static let dictationPromptShortcutsChanged = Notification.Name("DictationPromptShortcutsChanged")
    static let newPromptShortcutRecorded = Notification.Name("NewPromptShortcutRecorded")
}

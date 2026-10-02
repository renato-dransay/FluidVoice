import Foundation

/// The screen a provider setup was opened from, so it can offer the way back.
enum ProviderSetupOrigin: Equatable {
    case voiceEngine(tab: SpeechExecutionSource)
    case fluidMeet
    case cleanupStyles
    case commandMode
    case fileTranscription

    /// The words after "Back to" on the provider sheets.
    var title: String {
        switch self {
        case .voiceEngine: "Voice Engine"
        case .fluidMeet: "FluidMeet"
        case .cleanupStyles: "Cleanup Styles"
        case .commandMode: "Command Mode"
        case .fileTranscription: "File Transcription"
        }
    }

    /// Where `Back to …` goes: the screen the setup was opened from, on the same Voice Engine tab.
    var returnDestination: AppNavigationDestination {
        switch self {
        case let .voiceEngine(tab): .voiceEngine(tab: tab)
        case .fluidMeet: .meetingTranscription
        case .cleanupStyles: .cleanupStyles
        case .commandMode: .commandMode
        case .fileTranscription: .fileTranscription
        }
    }

    /// Where `Back to …` goes after `providerID` was set up or managed. Back on the Cloud tab, that
    /// provider is the one shown, not the stored Cloud provider.
    func returnDestination(providerID: String?) -> AppNavigationDestination {
        if case .voiceEngine(tab: .cloud) = self, let providerID, !providerID.isEmpty {
            return .voiceEngine(tab: .cloud, cloudProviderID: providerID)
        }
        return self.returnDestination
    }
}

enum AppNavigationDestination: Equatable {
    case aiEnhancements
    case history
    case dictationShortcuts
    case meetingTranscription
    case cleanupStyles
    case commandMode
    case fileTranscription
    /// AI Providers, on the given provider.
    case aiProvider(id: String, origin: ProviderSetupOrigin?)
    /// AI Providers, adding a provider, optionally limited to one capability.
    case addProvider(capability: ProviderCapability?, origin: ProviderSetupOrigin?)
    /// Voice Engine, browsing the given tab, or the active engine's tab when nil. On the Cloud tab,
    /// `cloudProviderID` is the provider shown when one is given.
    case voiceEngine(tab: SpeechExecutionSource?, cloudProviderID: String? = nil)

    /// The app page the destination opens, or nil for a destination inside Settings.
    var sidebarItem: SidebarItem? {
        switch self {
        case .aiEnhancements, .aiProvider, .addProvider: .aiEnhancements
        case .history: .history
        case .dictationShortcuts: nil
        case .meetingTranscription: .meetingTranscription
        case .cleanupStyles: .cleanupStyles
        case .commandMode: .commandMode
        case .fileTranscription: .fileTranscription
        case .voiceEngine: .voiceEngine
        }
    }
}

/// The sheet AI Providers opens for a provider request (NAV-2, NAV-3).
enum ProviderSheetRoute: Equatable {
    /// The Manage sheet of a connected provider.
    case manage(providerID: String, origin: ProviderSetupOrigin?)
    /// The Add sheet: on one provider's connection form when `providerID` is set, else on the grid,
    /// limited to one capability when one is given.
    case add(capability: ProviderCapability?, providerID: String?, origin: ProviderSetupOrigin?)

    static func route(for destination: AppNavigationDestination, connectedProviderIDs: Set<String>) -> ProviderSheetRoute? {
        switch destination {
        case let .aiProvider(id, origin):
            if connectedProviderIDs.contains(id) { return .manage(providerID: id, origin: origin) }
            return .add(capability: nil, providerID: id, origin: origin)
        case let .addProvider(capability, origin):
            return .add(capability: capability, providerID: nil, origin: origin)
        default:
            return nil
        }
    }
}

/// Pending navigation requests. A requested Voice Engine tab and a provider request are kept apart
/// from the destination because the page consumes them when it appears, after the app has switched pages.
struct AppNavigationRequests: Equatable {
    private var pendingDestination: AppNavigationDestination?
    private var pendingVoiceEngineTab: SpeechExecutionSource?
    private var pendingCloudProviderID: String?
    private var pendingProviderSetup: AppNavigationDestination?

    mutating func request(_ destination: AppNavigationDestination) {
        self.pendingDestination = destination
        // A later request to another page drops a tab or a provider request nobody read.
        self.pendingVoiceEngineTab = nil
        self.pendingCloudProviderID = nil
        self.pendingProviderSetup = nil
        switch destination {
        case let .voiceEngine(tab, cloudProviderID):
            self.pendingVoiceEngineTab = tab
            self.pendingCloudProviderID = cloudProviderID
        case .aiProvider, .addProvider:
            self.pendingProviderSetup = destination
        default:
            break
        }
    }

    /// The provider request (`.aiProvider` or `.addProvider`) AI Providers has not opened yet, once.
    mutating func consumeProviderSetup() -> AppNavigationDestination? {
        defer { self.pendingProviderSetup = nil }
        return self.pendingProviderSetup
    }

    mutating func consumeDestination() -> AppNavigationDestination? {
        defer { self.pendingDestination = nil }
        return self.pendingDestination
    }

    mutating func consumeVoiceEngineTab() -> SpeechExecutionSource? {
        defer { self.pendingVoiceEngineTab = nil }
        return self.pendingVoiceEngineTab
    }

    mutating func consumeCloudProviderID() -> String? {
        defer { self.pendingCloudProviderID = nil }
        return self.pendingCloudProviderID
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

    /// The Cloud provider a request asked the Cloud tab to show, once.
    func consumeRequestedCloudProviderID() -> String? {
        self.requests.consumeCloudProviderID()
    }

    /// The provider request AI Providers should open as a sheet, once.
    func consumeRequestedProviderSetup() -> AppNavigationDestination? {
        self.requests.consumeProviderSetup()
    }
}

extension Notification.Name {
    static let appNavigationRequested = Notification.Name("AppNavigationRequested")
    static let dictationPromptShortcutsChanged = Notification.Name("DictationPromptShortcutsChanged")
    static let newPromptShortcutRecorded = Notification.Name("NewPromptShortcutRecorded")
}

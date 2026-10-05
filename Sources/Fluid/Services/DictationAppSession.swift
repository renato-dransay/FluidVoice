import AppKit
import Combine
import Foundation

/// Remembers the last widget cleanup choice for each app, including after a restart.
final class DictationAppSession: @unchecked Sendable {
    static let shared = DictationAppSession()
    private let lock = NSLock()
    private var state = ForegroundAppOverride<SettingsStore.DictationPromptSelection>()
    private var didLoadChoices = false
    private var observer: NSObjectProtocol?
    private var mainWindowObserver: NSObjectProtocol?
    var appID: String? { self.lock.withLock { self.state.appID } }

    @MainActor
    func start() {
        self.loadChoicesIfNeeded()
        guard self.observer == nil else { return }
        self.activate(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        self.observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let appID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated { self?.activate(appID) }
        }
        self.mainWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow, !(window is NSPanel) else { return }
            MainActor.assumeIsolated { self?.activate(Bundle.main.bundleIdentifier, isMainWindow: true) }
        }
    }

    @MainActor
    func activate(_ appID: String?, isMainWindow: Bool? = nil) {
        // Our nonactivating overlay/popover must not end the target app's visit.
        let mainWindowFocused = isMainWindow ?? (NSApp.keyWindow != nil && !(NSApp.keyWindow is NSPanel))
        if appID == Bundle.main.bundleIdentifier, !mainWindowFocused { return }
        let changed = self.lock.withLock { self.state.activate(appID) }
        if changed { SettingsStore.shared.objectWillChange.send() }
    }

    @MainActor
    func select(_ selection: SettingsStore.DictationPromptSelection, slot: SettingsStore.DictationShortcutSlot, appID: String?) {
        guard let appID else { return }
        self.loadChoicesIfNeeded()
        let stored = self.lock.withLock { self.state.select(selection, slot: slot.rawValue, appID: appID) }
        if stored {
            SettingsStore.shared.setWidgetDictationPromptChoice(selection, slot: slot, appBundleID: appID)
        }
        SettingsStore.shared.objectWillChange.send()
    }

    func choice(for slot: SettingsStore.DictationShortcutSlot, appID: String?) -> SettingsStore.DictationPromptSelection? {
        self.loadChoicesIfNeeded()
        let selection = self.lock.withLock { self.state.choice(slot: slot.rawValue, appID: appID) }
        guard let selection else { return nil }
        guard case let .profile(id) = selection, !self.dictationProfileExists(id) else { return selection }
        self.lock.withLock { self.state.removeChoice(slot: slot.rawValue, appID: appID) }
        SettingsStore.shared.removeWidgetDictationPromptChoice(slot: slot, appBundleID: appID)
        return nil
    }

    /// Drops the in-memory map so the next read reloads persisted widget choices.
    func discardInMemoryChoices() {
        self.lock.withLock {
            self.state.removeAllChoices()
            self.didLoadChoices = false
        }
    }

    func dropLoadedWidgetChoices(appBundleID: String) {
        self.lock.withLock { self.state.removeChoices(appID: appBundleID) }
    }

    func dropLoadedWidgetChoices(profileIDs: Set<String>) {
        guard !profileIDs.isEmpty else { return }
        self.lock.withLock {
            self.state.removeChoices { selection in
                guard case let .profile(id) = selection else { return false }
                return profileIDs.contains(id)
            }
        }
    }

    private func loadChoicesIfNeeded() {
        self.lock.withLock {
            guard !self.didLoadChoices else { return }
            self.didLoadChoices = true
            self.state.mergeAbsentChoices(SettingsStore.shared.widgetDictationPromptChoices)
        }
    }

    private func dictationProfileExists(_ id: String) -> Bool {
        SettingsStore.shared.dictationPromptProfiles.contains { $0.id == id && $0.mode.normalized == .dictate }
    }
}

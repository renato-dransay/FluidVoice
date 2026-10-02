import AppKit
import SwiftUI

/// macOS drops a sheet presented while another sheet is still attached or closing. A sheet opened by a
/// navigation request (often sent from a sheet that is closing) waits here until no sheet is shown, then
/// checks that it really appeared.
enum SheetPresentationGate {
    /// True while any window shows a sheet, including one still animating closed.
    static func isAnySheetShown() -> Bool {
        NSApp.windows.contains { window in
            window.attachedSheet != nil || (window.isSheet && window.isVisible)
        }
    }

    /// Waits until `isSheetShown` has been false for `settle`, or until `timeout`. Returns false on timeout.
    static func waitUntilNoSheet(
        isSheetShown: @MainActor () -> Bool = Self.isAnySheetShown,
        pollInterval: Duration = .milliseconds(50),
        settle: Duration = .milliseconds(100),
        timeout: Duration = .seconds(2)
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var clearSince: ContinuousClock.Instant?
        while clock.now < deadline {
            if Task.isCancelled { return false }
            if isSheetShown() {
                clearSince = nil
            } else if let since = clearSince {
                if since.duration(to: clock.now) >= settle { return true }
            } else {
                clearSince = clock.now
            }
            try? await Task.sleep(for: pollInterval)
        }
        return false
    }

    /// The window identifier `SheetWindowMarker` gives the provider sheets of AI Providers, so a routed
    /// presentation is confirmed by its own sheet and never by another one.
    static let providerSheetIdentifier = NSUserInterfaceItemIdentifier("fluid-provider-setup-sheet")

    /// True while a visible sheet window carries `identifier`.
    static func isSheetShown(identifiedBy identifier: NSUserInterfaceItemIdentifier) -> Bool {
        NSApp.windows.contains { window in
            window.isSheet && window.isVisible && window.identifier == identifier
        }
    }

    /// What `present` did with a routed sheet request.
    enum Outcome: Equatable {
        case shown
        /// Another sheet stayed up past the timeout, or the request lapsed: nothing was presented.
        case dropped
        /// Presented, but macOS never showed it, on every attempt; the state was reset each time.
        case notShown
    }

    /// Presents a sheet once no sheet is shown, then waits for that sheet itself to appear. A wait that
    /// times out presents nothing (the request is dropped, never shown later over another sheet). A
    /// presentation macOS dropped is reset and tried again, up to `attempts` times.
    /// - Parameters:
    ///   - waitUntilClear: `waitUntilNoSheet`; false on timeout or cancellation.
    ///   - canPresent: false when the request lapsed meanwhile (another page, a sheet already open).
    ///   - waitForOwnSheet: `waitForSheet` checking for this sheet's marker.
    static func present(
        attempts: Int = 2,
        waitUntilClear: () async -> Bool,
        canPresent: () -> Bool,
        present: () -> Void,
        waitForOwnSheet: () async -> Bool,
        reset: () -> Void
    ) async -> Outcome {
        for _ in 0 ..< attempts {
            guard await waitUntilClear(), canPresent() else { return .dropped }
            present()
            if await waitForOwnSheet() { return .shown }
            reset()
        }
        return .notShown
    }

    /// Waits for a just-presented sheet to show. False when none appeared within `timeout`: the
    /// presentation was dropped and the state that asked for it must be reset.
    static func waitForSheet(
        isSheetShown: @MainActor () -> Bool = Self.isAnySheetShown,
        pollInterval: Duration = .milliseconds(50),
        timeout: Duration = .seconds(1)
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if isSheetShown() { return true }
            if Task.isCancelled { return false }
            try? await Task.sleep(for: pollInterval)
        }
        return isSheetShown()
    }
}

/// Marks the sheet window its content is shown in with `identifier`, so `SheetPresentationGate` can tell
/// that sheet from any other sheet the app shows.
struct SheetWindowMarker: NSViewRepresentable {
    let identifier: NSUserInterfaceItemIdentifier

    func makeNSView(context: Context) -> MarkerView {
        MarkerView(identifier: self.identifier)
    }

    func updateNSView(_ nsView: MarkerView, context: Context) {
        nsView.markWindow()
    }

    final class MarkerView: NSView {
        private let windowIdentifier: NSUserInterfaceItemIdentifier

        init(identifier: NSUserInterfaceItemIdentifier) {
            self.windowIdentifier = identifier
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            self.markWindow()
        }

        func markWindow() {
            guard let window = self.window, window.isSheet else { return }
            window.identifier = self.windowIdentifier
        }
    }
}

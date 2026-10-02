import AppKit

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

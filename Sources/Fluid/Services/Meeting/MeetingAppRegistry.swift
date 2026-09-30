import Foundation

/// Detection tier for a registry app. Tier 1 (native) is default-on; Tier 2 (browser) is an
/// opt-in sub-toggle because it reads the frontmost tab's URL.
nonisolated enum MeetingDetectionTier: Sendable, Equatable {
    case nativeTier1
    case browserTier2
}

/// Static, data-driven table of the apps the auto-detector watches. Every ambiguity resolves to
/// "not in the registry" — Slack, Discord, FaceTime and generic browsers-without-a-known-meeting-URL
/// are deliberately absent (see Phase A plan: dropped from v1).
nonisolated enum MeetingAppRegistry {
    /// Bundle identifiers for native meeting apps (Tier 1). Includes legacy Teams alongside the
    /// current "new Teams" bundle since both ship in the wild.
    static let nativeBundleIdentifiers: Set<String> = [
        "us.zoom.xos",
        "com.microsoft.teams2",
        "com.microsoft.teams",
        "com.cisco.webexmeetingsapp",
        "Cisco-Systems.Spark",
    ]

    /// Bundle identifiers for browsers eligible for Tier 2 URL reading. Google Meet's "app" is a
    /// Chrome/Edge/Vivaldi PWA, not a separate bundle — it is matched via `pwaHostByPrefix` instead.
    static let browserBundleIdentifiers: Set<String> = [
        "com.google.Chrome",
        "com.apple.Safari",
        "company.thebrowser.Browser",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "com.vivaldi.Vivaldi",
    ]

    /// Installed web apps (PWAs) run in an app shim whose bundle ID starts with one of these
    /// prefixes; the value is the host browser that renders the page and its audio. Chromium
    /// records the same mapping in each shim's Info.plist as `CrBundleIdentifier`. The trailing
    /// dot keeps unrelated bundles such as `com.vivaldi.Vivaldi.application` from matching.
    /// Firefox has no comparable PWA mechanism and is excluded from the registry entirely (its
    /// AX tree must be force-enabled by the user, so it fails closed anyway).
    static let pwaHostByPrefix: [String: String] = [
        "com.google.Chrome.app.": "com.google.Chrome",
        "com.microsoft.edgemac.app.": "com.microsoft.edgemac",
        "com.vivaldi.Vivaldi.app.": "com.vivaldi.Vivaldi",
    ]

    static func tier(forBundleIdentifier bundleIdentifier: String) -> MeetingDetectionTier? {
        if self.nativeBundleIdentifiers.contains(bundleIdentifier) {
            return .nativeTier1
        }
        if self.browserBundleIdentifiers.contains(bundleIdentifier) {
            return .browserTier2
        }
        if self.hostBrowserBundleIdentifier(forPWABundleIdentifier: bundleIdentifier) != nil {
            return .browserTier2
        }
        return nil
    }

    /// The browser that hosts an installed web app, or nil when the bundle is not a known PWA shim.
    static func hostBrowserBundleIdentifier(forPWABundleIdentifier bundleIdentifier: String) -> String? {
        self.pwaHostByPrefix.first { bundleIdentifier.hasPrefix($0.key) && bundleIdentifier.count > $0.key.count }?.value
    }

    static func isNativeMeetingApp(bundleIdentifier: String) -> Bool {
        self.tier(forBundleIdentifier: bundleIdentifier) == .nativeTier1
    }

    static func isBrowserApp(bundleIdentifier: String) -> Bool {
        self.tier(forBundleIdentifier: bundleIdentifier) == .browserTier2
    }

    private static let zoomMeetingTitles: Set<String> = [
        // en
        "Zoom", "Zoom Meeting", "Zoom Webinar",
        // es
        "Reunión de Zoom", "Seminario web de Zoom",
        // fr
        "Réunion Zoom", "Webinaire Zoom",
        // de
        "Zoom-Meeting", "Zoom-Webinar",
        // pt
        "Reunião do Zoom", "Webinar do Zoom",
        // ja
        "Zoom ミーティング", "Zoom ウェビナー",
    ]

    private static let zoomNonMeetingWindowTitles: Set<String> = [
        "", "Zoom Workplace", "Zoom Client Healthcheck",
    ]

    static func isZoomMeetingWindowTitle(_ title: String) -> Bool {
        guard !self.zoomNonMeetingWindowTitles.contains(title) else { return false }
        return self.zoomMeetingTitles.contains(title)
    }
}

/// Pure hostname+path matching for Tier 2 in-call URLs. Homepage/landing/post-call URLs never
/// match — a parked meeting tab must not, by itself, ever produce a prompt.
nonisolated enum MeetingInCallURLMatcher {
    static func isInCallURL(host: String, path: String) -> Bool {
        let host = host.lowercased()
        switch true {
        case host == "meet.google.com":
            return self.matchesGoogleMeetPath(path)
        case host.hasSuffix(".zoom.us") || host == "zoom.us":
            return self.matchesZoomPath(path)
        case host == "teams.microsoft.com" || host == "teams.live.com":
            return self.matchesTeamsPath(path)
        case host == "whereby.com" || host == "www.whereby.com":
            return self.matchesRoomPath(path, excluding: Self.wherebyReservedPaths)
        case host == "meet.jit.si":
            return self.matchesRoomPath(path, excluding: Self.jitsiReservedPaths)
        default:
            return false
        }
    }

    /// `/xxx-yyyy-zzz` — a lowercase-letter room code, three groups separated by hyphens.
    private static func matchesGoogleMeetPath(_ path: String) -> Bool {
        let segment = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let parts = segment.split(separator: "-")
        guard parts.count == 3 else { return false }
        let lengths = parts.map(\.count)
        guard lengths == [3, 4, 3] else { return false }
        return parts.allSatisfy { $0.allSatisfy(\.isLowercaseASCIILetter) }
    }

    private static func matchesZoomPath(_ path: String) -> Bool {
        path.hasPrefix("/j/") || path.hasPrefix("/wc/")
    }

    private static func matchesTeamsPath(_ path: String) -> Bool {
        let lowered = path.lowercased()
        return lowered.contains("meetup-join") || lowered.contains("prejoin") || lowered.contains("pre-join")
    }

    private static let wherebyReservedPaths: Set<String> = ["", "login", "signup", "pricing", "help", "download", "about"]
    private static let jitsiReservedPaths: Set<String> = ["", "login", "signup", "pricing", "help", "static"]

    private static func matchesRoomPath(_ path: String, excluding reserved: Set<String>) -> Bool {
        let segment = path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        guard !segment.isEmpty, !segment.contains("/") else { return false }
        return !reserved.contains(segment)
    }
}

/// Accessibility-free browser evidence: Google Meet titles its tab and web-app window
/// "Meet – abc-defg-hij", and browsers may append their own name ("… - Vivaldi"). Only Google Meet
/// is matched. Zoom and Teams web titles are generic, so those stay URL-only and fail closed.
nonisolated enum MeetingInCallTitleMatcher {
    private static let separators: Set<Substring> = ["–", "-", "—"]

    /// Returns the canonical in-call URL for a Meet room title, so title and tab-URL evidence
    /// for the same room share one episode key. Titles are never logged.
    static func inCallURL(fromWindowTitle title: String) -> BrowserTabURL? {
        let parts = title.split(whereSeparator: \.isWhitespace)
        guard parts.count >= 3, parts[0] == "Meet", self.separators.contains(parts[1]) else { return nil }
        let url = BrowserTabURL(host: "meet.google.com", path: "/\(parts[2])")
        return MeetingInCallURLMatcher.isInCallURL(host: url.host, path: url.path) ? url : nil
    }
}

private extension Character {
    var isLowercaseASCIILetter: Bool {
        ("a"..."z").contains(self)
    }
}

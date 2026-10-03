import Foundation

/// Opens the connection to a host while the user is still speaking, so the request after the recording
/// does not pay DNS, TCP and TLS. One instance per URL session owner; any failure is ignored, because the
/// real request reports its own errors and this call must never delay or block a recording.
nonisolated final class ConnectionWarmer: @unchecked Sendable {
    enum Outcome: String, Sendable {
        case sent
        case skipped
        case failed
    }

    /// How long a connection is treated as open after a request to its host succeeded.
    static let window: TimeInterval = 60
    static let requestTimeout: TimeInterval = 5

    private let lock = NSLock()
    private var lastSuccess: [String: TimeInterval] = [:]
    private var inFlight: Set<String> = []

    /// The scheme, host and port of a URL, with the path `/`.
    static func origin(of url: URL) -> URL? {
        guard let scheme = url.scheme, let host = url.host else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = url.port
        components.path = "/"
        return components.url
    }

    /// Sends one `HEAD` to the origin of `url`, without credentials or body. Any HTTP status counts as an
    /// open connection. Skipped while the origin is warm or a warm-up for it is still in flight.
    func warm(origin url: URL, on session: URLSession, now: TimeInterval = ProcessInfo.processInfo.systemUptime) async -> Outcome {
        guard let origin = Self.origin(of: url) else { return .skipped }
        let key = origin.absoluteString
        let shouldSend = self.lock.withLock {
            guard !self.inFlight.contains(key), !self.isWarm(key, now: now) else { return false }
            self.inFlight.insert(key)
            return true
        }
        guard shouldSend else { return .skipped }
        defer { self.lock.withLock { _ = self.inFlight.remove(key) } }

        var request = URLRequest(url: origin)
        request.httpMethod = "HEAD"
        request.timeoutInterval = Self.requestTimeout
        do {
            _ = try await session.data(for: request)
            self.lock.withLock { self.lastSuccess[key] = now }
            return .sent
        } catch {
            return .failed
        }
    }

    /// Records that a real request to this URL's host succeeded, so the next warm-up within the window is skipped.
    func markSuccess(_ url: URL?, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard let url, let origin = Self.origin(of: url) else { return }
        self.lock.withLock { self.lastSuccess[origin.absoluteString] = now }
    }

    private func isWarm(_ key: String, now: TimeInterval) -> Bool {
        self.lastSuccess[key].map { now - $0 < Self.window } ?? false
    }
}

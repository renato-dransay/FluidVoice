import Foundation

/// A message socket. The session talks to providers only through this, so tests script it.
nonisolated protocol LiveTranscriptionTransport: AnyObject, Sendable {
    func open(_ request: URLRequest) async throws
    func send(_ message: LiveTransportMessage) async throws
    func receive() async throws -> LiveTransportMessage
    func close()
}

/// Why a socket ended. `reason` may contain server text: map it, never log it.
nonisolated struct LiveTransportClosed: Error, Equatable, Sendable {
    let closeCode: Int
    let reason: String?
    let upgradeStatus: Int?
}

final nonisolated class URLSessionWebSocketTransport: NSObject, LiveTranscriptionTransport, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var openContinuation: CheckedContinuation<Void, Error>?
    private var isClosed = false

    func open(_ request: URLRequest) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        // A dictation stream lasts minutes; the HTTP-style resource timeout must not end it.
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 6 * 60 * 60
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 4 * 1024 * 1024
        // A socket closed before it opened (a replaced or cancelled connection) never connects.
        let wasClosed = self.lock.withLock { () -> Bool in
            guard !self.isClosed else { return true }
            self.session = session
            self.task = task
            return false
        }
        if wasClosed {
            session.invalidateAndCancel()
            throw LiveTransportClosed(closeCode: 0, reason: nil, upgradeStatus: nil)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // A close that lands here cancelled the task before its delegate had a continuation to resume.
            let closed = self.lock.withLock { () -> Bool in
                if !self.isClosed { self.openContinuation = continuation }
                return self.isClosed
            }
            if closed {
                continuation.resume(throwing: LiveTransportClosed(closeCode: 0, reason: nil, upgradeStatus: nil))
            } else {
                task.resume()
            }
        }
    }

    func send(_ message: LiveTransportMessage) async throws {
        guard let task = self.lock.withLock({ self.task }) else { throw LiveTransportClosed(closeCode: 0, reason: nil, upgradeStatus: nil) }
        switch message {
        case .text(let text): try await task.send(.string(text))
        case .data(let data): try await task.send(.data(data))
        }
    }

    func receive() async throws -> LiveTransportMessage {
        guard let task = self.lock.withLock({ self.task }) else { throw LiveTransportClosed(closeCode: 0, reason: nil, upgradeStatus: nil) }
        do {
            switch try await task.receive() {
            case .string(let text): return .text(text)
            case .data(let data): return .data(data)
            @unknown default: return .text("")
            }
        } catch {
            throw Self.closed(task)
        }
    }

    /// Cancels the socket and invalidates its URL session, which otherwise keeps this delegate alive.
    func close() {
        let (task, session) = self.lock.withLock { () -> (URLSessionWebSocketTask?, URLSession?) in
            self.isClosed = true
            return (self.task, self.session)
        }
        task?.cancel(with: .normalClosure, reason: nil)
        session?.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        self.resumeOpen(with: nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let webSocketTask = task as? URLSessionWebSocketTask else { return }
        self.resumeOpen(with: Self.closed(webSocketTask))
    }

    private func resumeOpen(with error: Error?) {
        let continuation = self.lock.withLock { () -> CheckedContinuation<Void, Error>? in
            defer { self.openContinuation = nil }
            return self.openContinuation
        }
        if let error { continuation?.resume(throwing: error) } else { continuation?.resume() }
    }

    /// `URLSessionWebSocketTask.CloseCode` covers only the standard codes. A provider code such as
    /// 3007 or 4001 arrives as `.invalid` (0) with the number unavailable, so adapters also read the
    /// provider's error frame, which every wave 1 provider sends before closing.
    private static func closed(_ task: URLSessionWebSocketTask) -> LiveTransportClosed {
        LiveTransportClosed(
            closeCode: task.closeCode.rawValue,
            reason: task.closeReason.flatMap { String(bytes: $0, encoding: .utf8) },
            upgradeStatus: (task.response as? HTTPURLResponse)?.statusCode
        )
    }
}

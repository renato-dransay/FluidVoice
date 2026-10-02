#if canImport(CloudTranscriptionHarness)
@testable import CloudTranscriptionHarness
#else
@testable import FluidVoice_Debug
#endif
import Foundation
import XCTest

/// Answers stubbed job-vendor requests by method and path, such as `POST /v2/jobs/`, and records every
/// request. Each route's responses are used in turn and the last one repeats; a status of 0 never answers,
/// so the request hangs until it is cancelled. A request without a route gets 404.
final class CloudVendorStub: @unchecked Sendable {
    typealias Response = (status: Int, body: String)

    private let lock = NSLock()
    private var routes: [String: [Response]]
    let recorder = CloudRequestRecorder()

    init(_ routes: [String: [Response]]) {
        self.routes = routes
    }

    func install() {
        CloudURLProtocol.install { request in
            self.recorder.append(request)
            let response = self.next(for: Self.route(of: request))
            return (response.status, [:], Data(response.body.utf8))
        }
    }

    /// Every request so far as `METHOD /path`.
    var calls: [String] { self.recorder.requests.map(Self.route) }

    func requests(_ route: String) -> [URLRequest] {
        self.recorder.requests.filter { Self.route(of: $0) == route }
    }

    static func route(of request: URLRequest) -> String {
        let path = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.path } ?? ""
        return "\(request.httpMethod ?? "GET") \(path)"
    }

    private func next(for route: String) -> Response {
        self.lock.withLock {
            guard var responses = self.routes[route], let first = responses.first else { return (404, "") }
            if responses.count > 1 {
                responses.removeFirst()
                self.routes[route] = responses
            }
            return first
        }
    }

    /// Waits until a request for `route` has been sent, for tests that cancel a hanging request.
    func waitForRequest(_ route: String, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while self.requests(route).isEmpty {
            guard Date() < deadline else {
                XCTFail("No request for \(route)")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

/// A job poller on a fake clock: every wait returns at once and advances the clock.
final class CloudTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: TimeInterval = 0
    private var recorded: [TimeInterval] = []
    var now: TimeInterval { self.lock.withLock { self.current } }
    var sleeps: [TimeInterval] { self.lock.withLock { self.recorded } }

    var poller: CloudJobPoller {
        CloudJobPoller(now: { self.now }, sleep: { self.advance($0) })
    }

    func advance(_ seconds: TimeInterval) {
        self.lock.withLock {
            self.recorded.append(seconds)
            self.current += seconds
        }
    }
}

enum CloudJobVendorAssert {
    /// Runs a transcription that must fail, returning its error.
    static func failure(_ body: () async throws -> CloudTranscriptionResult, file: StaticString = #filePath, line: UInt = #line) async -> Error? {
        do {
            _ = try await body()
            XCTFail("The transcription must fail", file: file, line: line)
            return nil
        } catch {
            return error
        }
    }

    /// The JSON body of a request as a dictionary.
    static func json(_ request: URLRequest?) throws -> [String: Any] {
        let body = try XCTUnwrap(request?.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    /// A message for the error that names the provider and carries no server text or key.
    static func assertSafeMessage(_ error: Error?, providerName: String, secrets: [String], file: StaticString = #filePath, line: UInt = #line) {
        guard let error else { return }
        let message = CloudTranscriptionError.message(for: error, providerName: providerName)
        XCTAssertTrue(message.contains(providerName), message, file: file, line: line)
        for secret in secrets {
            XCTAssertFalse(message.contains(secret), message, file: file, line: line)
        }
    }
}

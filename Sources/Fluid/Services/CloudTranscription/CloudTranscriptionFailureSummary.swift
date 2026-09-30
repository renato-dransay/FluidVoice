import Foundation

/// One log line for a failed cloud request. It names the failure kind and the model and nothing
/// else: error descriptions and provider bodies can carry transcript text or credentials, so
/// only the case name, the transport code or the error's type is ever written.
nonisolated enum CloudTranscriptionFailureSummary {
    static func line(for error: Error, modelID: String?) -> String {
        let kind: String
        switch error {
        case let cloudError as CloudTranscriptionError:
            kind = String(describing: cloudError)
        case is CancellationError:
            kind = "cancelled"
        case let urlError as URLError:
            kind = "URLError.\(urlError.code.rawValue)"
        default:
            kind = String(describing: type(of: error))
        }
        return "Cloud transcription failed: \(kind); model=\(modelID ?? "unknown"). No transcript or request payload logged."
    }
}

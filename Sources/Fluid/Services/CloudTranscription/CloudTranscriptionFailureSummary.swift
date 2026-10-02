import Foundation

/// One log line for a failed cloud request. It names the failure kind and the model and nothing
/// else: error descriptions and provider bodies can carry transcript text or credentials, so
/// only the case name, the transport code or the error's type is ever written.
nonisolated enum CloudTranscriptionFailureSummary {
    static func kind(of error: Error) -> String {
        switch error {
        case let cloudError as CloudTranscriptionError:
            return String(describing: cloudError)
        case is CancellationError:
            return "cancelled"
        case let urlError as URLError:
            return "URLError.\(urlError.code.rawValue)"
        default:
            return String(describing: type(of: error))
        }
    }

    static func line(for error: Error, modelID: String?, providerID: String? = nil) -> String {
        let provider = providerID.map { "provider=\($0) " } ?? ""
        return "Cloud transcription failed: \(self.kind(of: error)); \(provider)model=\(modelID ?? "unknown"). No transcript or request payload logged."
    }
}

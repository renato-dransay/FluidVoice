import CryptoKit
import Foundation

/// The text verification record (`verifiedProviderFingerprints`, VER-1): per provider key, a hash of the
/// server and key a text check passed with. A provider stays verified while both are unchanged, whatever
/// model is chosen. It is separate from the speech record and never written by a speech check.
enum TextVerificationRecord {
    /// Nil for an empty server: such a provider can never be verified. The key may be empty (local servers).
    static func fingerprint(baseURL: String, apiKey: String) -> String? {
        let trimmedBase = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBase.isEmpty else { return nil }
        let input = "\(trimmedBase)|\(trimmedKey)"
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The record after a text check passed with this server and key; unchanged when the server is empty.
    static func recording(
        _ fingerprints: [String: String],
        providerKey: String,
        baseURL: String,
        apiKey: String
    ) -> [String: String] {
        guard let fingerprint = self.fingerprint(baseURL: baseURL, apiKey: apiKey) else { return fingerprints }
        var updated = fingerprints
        updated[providerKey] = fingerprint
        return updated
    }

    /// True when the record holds a passed check for exactly this server and key.
    static func isVerified(_ fingerprints: [String: String], providerKey: String, baseURL: String, apiKey: String) -> Bool {
        guard let stored = fingerprints[providerKey] else { return false }
        return self.fingerprint(baseURL: baseURL, apiKey: apiKey) == stored
    }
}

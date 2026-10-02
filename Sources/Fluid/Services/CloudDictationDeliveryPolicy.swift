import Foundation

/// Raw speech alone authorizes actions; an already styled response never needs a second AI pass.
enum CloudDictationDeliveryPolicy {
    struct Decision {
        let text: String
        let transcript: String
        let shouldSend: Bool
        let sendsExistingDraft: Bool
        let requiresSeparateCleanup: Bool
    }

    /// Only a Cleanup Style needs the audio chat model. With cleanup Off the transcript is the
    /// result, so the recording goes to the speech model on the transcription endpoint.
    static func usesCombinedRequest(isDictation: Bool, cloudStylesActive: Bool, styleEnabled: Bool) -> Bool {
        isDictation && cloudStylesActive && styleEnabled
    }

    static func resolve(
        transcript: String,
        combinedText: String?,
        cleanupConfigured: Bool,
        spokenSendPhrase: String,
        spokenSendEnabled: Bool,
        wasArmed: Bool
    ) -> Decision {
        let parsed = SpokenSendParser.parseArmed(
            transcript, phrase: spokenSendPhrase, enabled: spokenSendEnabled, wasArmed: wasArmed
        )
        let sendsExistingDraft = parsed.shouldSend && parsed.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let text: String
        if sendsExistingDraft {
            text = ""
        } else if let combinedText {
            // A style must not introduce an action, but a recognized terminal command must not be typed.
            text = parsed.shouldSend
                ? SpokenSendParser.parseArmed(combinedText, phrase: spokenSendPhrase, enabled: true, wasArmed: wasArmed).text
                : combinedText
        } else {
            text = parsed.text
        }
        return Decision(
            text: text,
            transcript: parsed.text,
            shouldSend: parsed.shouldSend,
            sendsExistingDraft: sendsExistingDraft,
            requiresSeparateCleanup: combinedText == nil && cleanupConfigured && !sendsExistingDraft
        )
    }
}

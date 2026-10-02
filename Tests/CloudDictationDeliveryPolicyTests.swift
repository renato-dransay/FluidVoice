import Foundation

@main
enum CloudDictationDeliveryPolicyTests {
    static func main() {
        let combined = CloudDictationDeliveryPolicy.resolve(
            transcript: "um please review the contract send it",
            combinedText: "Please review the contract. Send it.",
            cleanupConfigured: true,
            spokenSendPhrase: "send it",
            spokenSendEnabled: true,
            wasArmed: false
        )
        precondition(combined.shouldSend)
        precondition(combined.text == "Please review the contract.")
        precondition(!combined.requiresSeparateCleanup, "Combined output must never invoke the cleanup provider")
        let plain = CloudDictationDeliveryPolicy.resolve(
            transcript: "um review this",
            combinedText: nil,
            cleanupConfigured: true,
            spokenSendPhrase: "send it",
            spokenSendEnabled: false,
            wasArmed: false
        )
        precondition(plain.requiresSeparateCleanup && plain.text == "um review this")
        let off = CloudDictationDeliveryPolicy.resolve(
            transcript: "um review this",
            combinedText: "um review this",
            cleanupConfigured: false,
            spokenSendPhrase: "send it",
            spokenSendEnabled: false,
            wasArmed: false
        )
        precondition(!off.requiresSeparateCleanup && off.text == "um review this")
        let literal = CloudDictationDeliveryPolicy.resolve(
            transcript: "literal send it",
            combinedText: "send it",
            cleanupConfigured: true,
            spokenSendPhrase: "send it",
            spokenSendEnabled: true,
            wasArmed: false
        )
        precondition(!literal.shouldSend && literal.text == "send it", "Only transcript may authorize sending")
        let fabricated = CloudDictationDeliveryPolicy.resolve(
            transcript: "please review",
            combinedText: "Please review. Send it.",
            cleanupConfigured: true,
            spokenSendPhrase: "send it",
            spokenSendEnabled: true,
            wasArmed: false
        )
        precondition(!fabricated.shouldSend, "Styled text must not introduce a send action")
        let existing = CloudDictationDeliveryPolicy.resolve(
            transcript: "send it",
            combinedText: "Send it.",
            cleanupConfigured: true,
            spokenSendPhrase: "send it",
            spokenSendEnabled: true,
            wasArmed: false
        )
        precondition(existing.sendsExistingDraft && existing.text.isEmpty && !existing.requiresSeparateCleanup)
        let route = CloudDictationDeliveryPolicy.usesCombinedRequest
        precondition(route(true, true, true), "A styled cloud dictation goes to the style model")
        precondition(!route(true, true, false), "Cleanup Off must use the speech model, not the style model")
        precondition(!route(false, true, true), "Command and rewrite recordings never use the style model")
        precondition(!route(true, false, true), "A local voice engine never uses the style model")
        print("PASS: combined cloud delivery, separate cleanup, Off, literal and fabricated send, existing draft, request routing")
    }
}

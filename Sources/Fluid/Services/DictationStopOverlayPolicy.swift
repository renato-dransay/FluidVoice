import Foundation

/// Decides whether the dictation overlay may disappear at the stop hotkey.
///
/// A local final pass returns within a few hundred milliseconds, so a plain
/// dictation can hide the overlay before the paste and feel instant. Every
/// other case, including cloud transcription, has seconds of work ahead and
/// keeps the overlay in its "Transcribing" state until delivery.
enum DictationStopOverlayPolicy {
    struct Input {
        var isNormalRoute: Bool
        var isRewrite: Bool
        var isCommand: Bool
        var isPromptTestActive: Bool
        var usesAIOnStop: Bool
        var spokenSendEnabled: Bool
        var usesCloudTranscription: Bool
    }

    static func shouldHideOverlayOnStop(_ input: Input) -> Bool {
        input.isNormalRoute
            && !input.isRewrite
            && !input.isCommand
            && !input.isPromptTestActive
            && !input.usesAIOnStop
            && !input.spokenSendEnabled
            && !input.usesCloudTranscription
    }
}

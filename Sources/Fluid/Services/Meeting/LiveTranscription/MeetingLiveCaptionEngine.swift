import CoreMedia
import Foundation

nonisolated enum MeetingLiveCaptionHandlers {
    /// Track, turn id, text, turn start and the end of the audio it covers so far.
    typealias Partial = @Sendable (MeetingAudioTrackKind, UUID, String, CMTime, CMTime) -> Void
    /// Track, the turn id its partials used, text, start and end.
    typealias Utterance = @Sendable (MeetingAudioTrackKind, UUID, String, CMTime, CMTime) -> Void
    typealias Degraded = @Sendable (MeetingAudioTrackKind, String) -> Void
    typealias Ready = @Sendable (MeetingAudioTrackKind) -> Void
}

/// Live captions for one capture track, from the on-device model or a streaming provider.
/// `offer` is called synchronously from the capture tee and must never block.
nonisolated protocol MeetingLiveCaptionEngine: Sendable {
    func configure(
        onPartial: @escaping MeetingLiveCaptionHandlers.Partial,
        onUtterance: @escaping MeetingLiveCaptionHandlers.Utterance,
        onDegraded: @escaping MeetingLiveCaptionHandlers.Degraded,
        onReady: @escaping MeetingLiveCaptionHandlers.Ready
    ) async
    func start() async
    /// Terminal: releases models or connections, and no handler runs afterwards.
    func stop() async
    func offer(_ sample: MeetingLiveSampleCopy.Sample)
}

/// Where one recording's live captions come from, decided when the recording starts.
nonisolated enum MeetingLiveCaptionSource: Equatable, Sendable {
    /// The on-device English model.
    case onDevice
    /// A Live cloud provider, with the key saved for it in Voice Engine.
    case cloud(LiveTranscriptionConfiguration, apiKey: String)
    /// A provider was chosen but cannot run; captions stay off and say why.
    case unavailable(reason: String)

    /// The provider that receives meeting audio, or nil when captions stay on this Mac.
    var cloudProvider: LiveTranscriptionProviderID? {
        if case .cloud(let configuration, _) = self { return configuration.provider }
        return nil
    }
}

import Foundation

/// The text AI provider that summarizes a meeting when no on-device summary model is available.
nonisolated struct MeetingCloudSummaryRoute: Equatable, Sendable {
    let providerKey: String
    let providerName: String
    let baseURL: String
    let model: String
    let apiKey: String

    /// Saved summaries record this identity. Every cloud identity shares the `cloud:` prefix, so
    /// switching models keeps earlier summaries visible.
    var savedModelID: String {
        "cloud:\(self.providerKey):\(self.model)"
    }

    static let savedModelIDPrefix = "cloud:"
}

enum MeetingCloudSummaryRouteResolver {
    static let openRouterProviderID = "openrouter"

    /// Uses the default text provider chosen in AI Providers, with the key text features read
    /// (`getAPIKey`). When that provider is missing, is Fluid Intelligence or has no key, falls back to
    /// OpenRouter with its speech key (`speechAPIKey(for: "openrouter")`, the key Voice Engine sends),
    /// which authorizes OpenRouter's chat endpoint as well. While OpenRouter is the Cloud voice engine,
    /// AI Providers hides the OpenRouter text model, so a selected OpenRouter provider uses the Voice
    /// Engine style model, which the user picked and which their OpenRouter account is known to serve.
    ///
    /// `keyAwaitsTextVerification` is true when the key migration copied the provider's text key from its
    /// Voice Engine entry (a live key) and it has been neither text-verified nor saved again since. Before
    /// the update that provider had no text key and summaries fell back to OpenRouter, so they still do.
    /// OpenRouter is exempt: its summary already used the Voice Engine key before the update.
    static func resolve(
        provider: DictationProviderRoute,
        isLocalEndpoint: Bool,
        usesVoiceEngine: Bool,
        keyAwaitsTextVerification: Bool = false,
        providerName: String,
        openRouterSpeechKey: String,
        openRouterModel: String?,
        openRouterBaseURL: String
    ) -> MeetingCloudSummaryRoute? {
        let model = provider.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        var apiKey = provider.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let voiceKey = openRouterSpeechKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if apiKey.isEmpty, provider.providerID == self.openRouterProviderID {
            apiKey = voiceKey
        }
        let defersToVoiceEngine = usesVoiceEngine && provider.providerID == self.openRouterProviderID
        let keyIsUnconfirmed = keyAwaitsTextVerification && provider.providerID != self.openRouterProviderID
        if !defersToVoiceEngine, !keyIsUnconfirmed, !provider.providerID.isEmpty, !provider.usesPrivateAI, !model.isEmpty, !baseURL.isEmpty,
           isLocalEndpoint || !apiKey.isEmpty
        {
            return MeetingCloudSummaryRoute(
                providerKey: provider.providerKey,
                providerName: providerName,
                baseURL: baseURL,
                model: model,
                apiKey: apiKey
            )
        }
        let fallbackModel = openRouterModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !voiceKey.isEmpty, !fallbackModel.isEmpty else { return nil }
        return MeetingCloudSummaryRoute(
            providerKey: self.openRouterProviderID,
            providerName: "OpenRouter",
            baseURL: openRouterBaseURL,
            model: fallbackModel,
            apiKey: voiceKey
        )
    }

    static func resolve(settings: SettingsStore = .shared) -> MeetingCloudSummaryRoute? {
        let provider = DictationProviderRoute.resolve(settings: settings)
        let repository = ModelRepository.shared
        return self.resolve(
            provider: provider,
            isLocalEndpoint: repository.isLocalEndpoint(provider.baseURL),
            usesVoiceEngine: settings.usesCombinedCloudDictation,
            keyAwaitsTextVerification: ProviderKeyMigration.filledTextProviders(in: .standard).contains(provider.providerKey)
                && !settings.isCommandModeProviderVerified(provider.providerID),
            providerName: settings.savedProviders.first(where: { $0.id == provider.providerID })?.name
                ?? repository.displayName(for: provider.providerID),
            openRouterSpeechKey: settings.speechAPIKey(for: self.openRouterProviderID),
            // The Voice Engine dictation model is an OpenRouter chat model that also accepts text.
            openRouterModel: settings.cloudDictationModelID,
            openRouterBaseURL: repository.defaultBaseURL(for: self.openRouterProviderID)
        )
    }
}

nonisolated enum MeetingCloudSummaryPrompt {
    /// Cloud models accept far longer input than the on-device model; this bounds request size
    /// to roughly 100k tokens of transcript.
    static let maximumTranscriptBytes = 400_000

    static func systemPrompt(for kind: MeetingSummaryKind) -> String {
        """
        You summarize meeting transcripts. The user message holds a header with the title, date, \
        time, duration and participants, a line of dashes, then the transcript with one speaker \
        turn per line in the form **Speaker**: text. The transcript comes from automatic speech \
        recognition, so it can contain misheard words, missing words and unlabeled speakers.

        Rules:
        - Use only information in the transcript. Never invent names, dates, numbers, owners or decisions. When something is unclear, say so briefly.
        - Write in the language most of the meeting was held in.
        - Refer to people by the names or speaker labels the transcript uses.
        - Respond in Markdown without a surrounding code block, preamble or closing remarks.
        - If the transcript holds too little content for the request, say so in one sentence.

        Task: \(self.task(for: kind))
        """
    }

    static func messages(transcript: String, kind: MeetingSummaryKind) -> [[String: Any]] {
        [
            ["role": "system", "content": self.systemPrompt(for: kind)],
            ["role": "user", "content": transcript],
        ]
    }

    private static func task(for kind: MeetingSummaryKind) -> String {
        switch kind {
        case .executive:
            "Write an executive summary: one short paragraph of three to five sentences on the purpose and outcome of the meeting, followed by at most five bullets with the most important points, decisions and next steps."
        case .detailed:
            "Write a detailed summary with one ## heading per major topic, in the order discussed. "
                + "Under each heading, cover what was said, the positions people took, conclusions and open questions. "
                + "End with a ## Next steps section when any were mentioned."
        case .actions:
            "List every action item as a Markdown task list (- [ ] item), in order of first mention. "
                + "For each, give the task, the owner when the transcript names one (otherwise write \"owner unassigned\") "
                + "and the due date when one was mentioned. If there are no action items, say so."
        case .decisions:
            "List the key decisions as bullets. For each, give the decision, who made or agreed to it when clear, "
                + "and the reasoning given. Then add an ## Open questions section listing what was raised but left undecided. "
                + "If no decisions were made, say so."
        case .participants:
            "For each participant, write a ## heading with their name or speaker label, followed by bullets on their part "
                + "in the discussion, their main contributions and positions, and anything they committed to. "
                + "Do not guess job titles the transcript does not state."
        case .topics:
            "List the topics discussed as a numbered list, in the order they came up. For each, give a short bold title followed by one or two sentences on what was said and where it landed."
        }
    }
}

nonisolated enum MeetingCloudSummaryError: LocalizedError, Equatable {
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .emptyResponse: "The AI provider returned an empty summary. Try again or choose another model in AI Providers."
        }
    }
}

nonisolated enum MeetingCloudSummaryService {
    /// Long meetings can take minutes to summarize; the shared client caps a request at 60 seconds.
    static let sharedClient: LLMClient = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 600
        return LLMClient(session: URLSession(configuration: configuration))
    }()

    static func summarize(
        transcript: String,
        kind: MeetingSummaryKind,
        route: MeetingCloudSummaryRoute,
        extraParameters: [String: Any],
        sendsTemperature: Bool,
        client: LLMClient = MeetingCloudSummaryService.sharedClient,
        onContentChunk: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        var config = LLMClient.Config(
            messages: MeetingCloudSummaryPrompt.messages(transcript: transcript, kind: kind),
            model: route.model,
            baseURL: route.baseURL,
            apiKey: route.apiKey,
            streaming: true,
            temperature: sendsTemperature ? 0.2 : nil,
            extraParameters: extraParameters
        )
        config.timeoutSeconds = 120
        config.onContentChunk = onContentChunk
        let response = try await client.call(config)
        let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw MeetingCloudSummaryError.emptyResponse }
        return text
    }
}

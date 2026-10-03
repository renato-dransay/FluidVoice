import Foundation

/// What a text request is for. Only a dictation's Cleanup Style may carry the speed options below;
/// Command Mode, Edit, meeting summaries and the Local API keep their requests as they are.
nonisolated enum TextRequestPurpose: Sendable {
    case dictationCleanup
    case general
}

/// The request options one text request carries: its reasoning parameter and, for a cleanup on a model
/// that supports it, a predicted output. Every call site asks `resolve` instead of building them itself.
nonisolated struct TextRequestOptions: Equatable, Sendable {
    struct Reasoning: Equatable, Sendable {
        let name: String
        let value: Value
    }

    enum Value: Equatable, Sendable {
        case string(String)
        case bool(Bool)
    }

    /// What the user saved in the Reasoning editor for one model.
    enum Saved: Equatable, Sendable {
        case nothing
        case off
        case on(Reasoning)
    }

    struct Input: Sendable {
        let purpose: TextRequestPurpose
        let baseURL: String
        let model: String
        let transcript: String?
        let saved: Saved
        let lowReasoningEnabled: Bool
        let predictedOutputsEnabled: Bool
        let suppressed: Bool
    }

    /// The reasoning parameter to send, or nil when none is sent.
    let reasoning: Reasoning?
    /// The predicted text for OpenAI's Predicted Outputs, or nil.
    let prediction: String?

    var extraParameters: [String: Any] {
        guard let reasoning else { return [:] }
        switch reasoning.value {
        case let .string(value): return [reasoning.name: value]
        case let .bool(value): return [reasoning.name: value]
        }
    }

    /// A one-line description for the benchmark log, without spaces so the log parser keeps it whole.
    var reasoningLogValue: String {
        guard let reasoning else { return "unset" }
        let value = switch reasoning.value {
        case let .string(value): value
        case let .bool(value): String(value)
        }
        return "\(reasoning.name):\(value)".replacingOccurrences(of: " ", with: "_")
    }

    static func resolve(_ input: Input) -> TextRequestOptions {
        let general: Reasoning? = switch input.saved {
        case let .on(reasoning): reasoning
        case .off: nil
        case .nothing: self.builtInDefault(forModel: input.model)
        }
        let isCleanup = input.purpose == .dictationCleanup && !input.suppressed
        var reasoning = general
        if isCleanup, input.lowReasoningEnabled, input.saved == .nothing,
           let lower = self.cleanupReasoning(baseURL: input.baseURL, model: input.model)
        {
            reasoning = lower
        }
        let prediction = isCleanup && input.predictedOutputsEnabled
            ? self.prediction(baseURL: input.baseURL, model: input.model, transcript: input.transcript)
            : nil
        return TextRequestOptions(reasoning: reasoning, prediction: prediction)
    }

    // MARK: - Built-in default

    /// The reasoning parameter sent for a model when nothing is saved for it. It matches the raw lowercased
    /// ID, so `openai/o3` falls to the `openai/` rule and gets `low`, as it always has.
    static func builtInDefault(forModel model: String) -> Reasoning? {
        let modelLower = model.lowercased()
        if modelLower.hasPrefix("gpt-5") || modelLower.contains("gpt-5.") {
            return Reasoning(name: "reasoning_effort", value: .string("low"))
        }
        if modelLower.hasPrefix("o1") || modelLower.hasPrefix("o3") || modelLower.hasPrefix("o4") {
            return Reasoning(name: "reasoning_effort", value: .string("medium"))
        }
        if modelLower.contains("gpt-oss") || modelLower.hasPrefix("openai/") {
            return Reasoning(name: "reasoning_effort", value: .string("low"))
        }
        if modelLower.contains("deepseek"), modelLower.contains("reasoner") {
            return Reasoning(name: "enable_thinking", value: .bool(true))
        }
        return nil
    }

    /// The saved name and value as the Reasoning editor stores them; `enable_thinking` is a Boolean.
    static func reasoning(name: String, value: String) -> Reasoning {
        name == "enable_thinking"
            ? Reasoning(name: name, value: .bool(value == "true"))
            : Reasoning(name: name, value: .string(value))
    }

    // MARK: - Model matching

    /// The model ID lowercased, without a provider or path prefix (`openai/o3`, `models/gemini-2.5-flash`).
    static func bareModelID(_ model: String) -> String {
        let modelLower = model.lowercased()
        guard let slash = modelLower.firstIndex(of: "/") else { return modelLower }
        return String(modelLower[modelLower.index(after: slash)...])
    }

    private static func host(of baseURL: String) -> String? {
        URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased()
    }

    /// The lowest reasoning effort each vendor documents for a model, applied to Cleanup Styles only, and
    /// only on the vendor's own server: OpenRouter, AssemblyAI's gateway and custom servers may not forward it.
    /// EVIDENCE: https://ai.google.dev/gemini-api/docs/openai (checked 2026-10-03): `none` turns thinking off
    /// for Gemini 2.5 except 2.5 Pro; Gemini 2.5 Pro and Gemini 3 cannot turn it off. Gemini 3 Flash models get
    /// `minimal`, their lowest level; the Pro models get `low`, which the page maps to 3.1 Pro's lowest level.
    /// EVIDENCE: https://console.groq.com/docs/reasoning (checked 2026-10-03): Qwen accepts `none`.
    /// EVIDENCE: https://developers.openai.com/api/docs/guides/reasoning (checked 2026-10-03): an unsupported
    /// value returns HTTP 400, so OpenAI rows stay on values every listed model accepts.
    static func cleanupReasoning(baseURL: String, model: String) -> Reasoning? {
        guard let host = self.host(of: baseURL) else { return nil }
        let id = self.bareModelID(model)
        let effort: String? = switch host {
        case "generativelanguage.googleapis.com":
            if id.hasPrefix("gemini-2.5-flash") {
                "none"
            } else if id.hasPrefix("gemini-2.5-pro") || (id.hasPrefix("gemini-3") && id.contains("pro")) {
                "low"
            } else if id.hasPrefix("gemini-3") {
                "minimal"
            } else {
                nil
            }
        case "api.groq.com":
            id.hasPrefix("qwen") ? "none" : nil
        case "api.openai.com":
            id.hasPrefix("o1") || id.hasPrefix("o3") || id.hasPrefix("o4") ? "low" : nil
        default:
            nil
        }
        return effort.map { Reasoning(name: "reasoning_effort", value: .string($0)) }
    }

    /// OpenAI's Predicted Outputs, on the Chat Completions models that support it.
    /// EVIDENCE: https://developers.openai.com/api/docs/guides/predicted-outputs (checked 2026-10-03).
    static let predictedOutputModels: Set<String> = ["gpt-4o", "gpt-4o-mini", "gpt-4.1", "gpt-4.1-mini", "gpt-4.1-nano"]

    private static func prediction(baseURL: String, model: String, transcript: String?) -> String? {
        guard let transcript, !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              self.host(of: baseURL) == "api.openai.com",
              !LLMClient.shouldUseResponsesAPI(baseURL: baseURL, model: model)
        else { return nil }
        let undated = model.replacingOccurrences(of: #"-\d{4}-\d{2}-\d{2}$"#, with: "", options: .regularExpression)
        return self.predictedOutputModels.contains(undated) ? transcript : nil
    }
}

/// Hidden keys that turn each dictation speed-up on or off, so the owner can compare both on one build.
/// Read on every decision, never cached, so `defaults write` takes effect on the next dictation.
nonisolated enum DictationSpeedComparison {
    static let textWarmUpKey = "DictationSpeedTextWarmUp"
    static let speechWarmUpKey = "DictationSpeedSpeechWarmUp"
    static let lowReasoningKey = "DictationSpeedLowReasoning"
    static let predictedOutputsKey = "DictationSpeedPredictedOutputs"

    static var textWarmUp: Bool { self.flag(self.textWarmUpKey, default: true) }
    static var speechWarmUp: Bool { self.flag(self.speechWarmUpKey, default: true) }
    static var lowReasoning: Bool { self.flag(self.lowReasoningKey, default: true) }
    static var predictedOutputs: Bool { self.flag(self.predictedOutputsKey, default: false) }

    private static func flag(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? value
    }
}

@MainActor
extension TextRequestOptions {
    /// Models that rejected their optimisation in this launch, as "<providerKey>:<model>". Not stored: a
    /// vendor may start accepting the parameter, and one extra request per launch is cheap.
    private static var suppressedPairs: Set<String> = []

    static func pair(providerKey: String, model: String) -> String {
        "\(providerKey):\(model)"
    }

    static func suppress(_ pair: String) {
        self.suppressedPairs.insert(pair)
    }

    static func isSuppressed(_ pair: String) -> Bool {
        self.suppressedPairs.contains(pair)
    }

    static func resetSuppressionForTesting() {
        self.suppressedPairs.removeAll()
    }

    /// The options for a request and the same request without any optimisation, read from the settings.
    static func resolve(
        purpose: TextRequestPurpose,
        providerKey: String,
        baseURL: String,
        model: String,
        transcript: String?,
        settings: SettingsStore = .shared
    ) -> (options: TextRequestOptions, plain: TextRequestOptions) {
        let input = Input(
            purpose: purpose,
            baseURL: baseURL,
            model: model,
            transcript: transcript,
            saved: settings.savedReasoning(forModel: model, provider: providerKey),
            lowReasoningEnabled: DictationSpeedComparison.lowReasoning,
            predictedOutputsEnabled: DictationSpeedComparison.predictedOutputs,
            suppressed: self.isSuppressed(self.pair(providerKey: providerKey, model: model))
        )
        let plain = Input(
            purpose: input.purpose,
            baseURL: input.baseURL,
            model: input.model,
            transcript: input.transcript,
            saved: input.saved,
            lowReasoningEnabled: input.lowReasoningEnabled,
            predictedOutputsEnabled: input.predictedOutputsEnabled,
            suppressed: true
        )
        return (self.resolve(input), self.resolve(plain))
    }
}

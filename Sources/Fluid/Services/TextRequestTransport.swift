import Foundation

/// Sends a dictation text request with its options, and owns the two repeats that may follow a failure:
/// the request without its speed options after a rejection, and the request without streaming.
enum TextRequestTransport {
    typealias Send = (LLMClient.Config) async throws -> LLMClient.Response

    /// - Parameters:
    ///   - options: what `TextRequestOptions.resolve` chose for this request.
    ///   - plain: the same request without any optimisation. Equal to `options` when there is none.
    ///   - pair: the provider key and model, as `TextRequestOptions.pair` writes it.
    static func send(
        _ config: LLMClient.Config,
        options: TextRequestOptions,
        plain: TextRequestOptions,
        pair: String,
        using send: Send = { try await LLMClient.shared.call($0) }
    ) async throws -> LLMClient.Response {
        let optimised = options != plain
        self.bench(
            config,
            "ai_request_options",
            "reasoning=\(options.reasoningLogValue) prediction=\(options.prediction != nil) "
                + "optimised=\(optimised) lowReasoning=\(self.onOff(DictationSpeedComparison.lowReasoning)) "
                + "predicted=\(self.onOff(DictationSpeedComparison.predictedOutputs)) "
                + "warmUp=\(self.onOff(DictationSpeedComparison.textWarmUp))"
        )
        let plainConfig = config.applying(plain)
        var lastError: Error
        do {
            return try await send(config.applying(options))
        } catch {
            lastError = error
        }

        // A 400 on a request with an optimisation is what a vendor returns for a parameter it does not take.
        // The pair is suppressed only once a plain request has succeeded, so a 400 with another cause
        // (a model that is gone, an oversized prompt) leaves the optimisation in place.
        var rejectedOptimisation = false
        if optimised, case LLMError.httpError(400, _) = lastError {
            rejectedOptimisation = true
            self.bench(config, "ai_optimisation_rejected", "status=400")
            do {
                let response = try await send(plainConfig)
                TextRequestOptions.suppress(pair)
                return response
            } catch {
                lastError = error
            }
        }

        guard config.streaming else { throw lastError }
        guard DictationStreamingFallbackPolicy.shouldRetryWithoutStreaming(after: lastError) else {
            DebugLogger.shared.benchmark("APP_BENCH", message: "ai_streaming_fallback_skipped reason=transport_or_cancel", source: "AppBenchmark")
            throw lastError
        }
        DebugLogger.shared.benchmark("APP_BENCH", message: "ai_streaming_fallback_start", source: "AppBenchmark")
        DebugLogger.shared.warning(
            "Streaming dictation post-processing failed; retrying without streaming: \(lastError.localizedDescription)",
            source: "ContentView"
        )
        let response = try await send(plainConfig.withoutStreaming())
        if rejectedOptimisation { TextRequestOptions.suppress(pair) }
        return response
    }

    private static func onOff(_ value: Bool) -> String {
        value ? "on" : "off"
    }

    /// Writes an APP_BENCH marker: its name first, then the pipeline ID when the request has one.
    private static func bench(_ config: LLMClient.Config, _ name: String, _ fields: String = "") {
        let parts = [name, config.benchmarkID.map { "id=\($0)" }, fields.isEmpty ? nil : fields].compactMap(\.self)
        DebugLogger.shared.benchmark("APP_BENCH", message: parts.joined(separator: " "), source: "AppBenchmark")
    }
}

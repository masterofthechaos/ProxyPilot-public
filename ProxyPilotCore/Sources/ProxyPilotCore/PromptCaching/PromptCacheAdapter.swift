import Foundation

public enum PromptCacheAdapter {
    /// Applies provider-appropriate cache hints to an outbound request.
    /// Returns the (possibly mutated) body + any additional headers.
    /// Phase A: observe-only mode always returns passThrough.
    /// Phase B will add computeCacheHints mutations.
    public static func mutate(
        path: String,
        headers: [(String, String)],
        body: Data,
        provider: UpstreamProvider,
        model: String?,
        sessionID: String,
        configuration: PromptCachingConfiguration
    ) -> PromptCacheMutation {
        guard configuration.isEnabled, configuration.mode != .off else {
            return .passThrough(body: body, headers: headers)
        }

        let capabilities = provider.promptCacheCapabilities

        if let reason = capabilities.unsafeForMutationReason {
            return PromptCacheMutation(
                body: body,
                headers: headers,
                applied: false,
                strategy: "blocked",
                notes: [reason]
            )
        }

        // Phase A: observe-only — never mutate
        guard configuration.mode != .observeOnly else {
            return .passThrough(body: body, headers: headers)
        }

        guard configuration.mode == .computeCacheHints else {
            return .passThrough(body: body, headers: headers)
        }

        if path.contains("/messages"), capabilities.supportsAnthropicCacheControl {
            return mutateAnthropicCacheControl(body: body, headers: headers)
        }

        if provider == .zAI, configuration.canonicalizeJSONForCache {
            return canonicalizeJSON(body: body, headers: headers)
        }

        if provider == .xAI, path.contains("/chat/completions") {
            let cacheKey = PromptCacheSessionKey.bucketed(
                provider: provider.rawValue,
                model: normalizedModel(model, body: body),
                sessionID: sessionID,
                route: path
            )
            return mutateXAIChatHeaders(body: body, headers: headers, cacheKey: cacheKey)
        }

        guard capabilities.supportsPromptCacheKey else {
            return PromptCacheMutation(
                body: body,
                headers: headers,
                applied: false,
                strategy: "unsupported",
                notes: ["Provider does not accept prompt_cache_key hints."]
            )
        }

        let cacheKey = PromptCacheSessionKey.bucketed(
            provider: provider.rawValue,
            model: normalizedModel(model, body: body),
            sessionID: sessionID,
            route: path
        )
        return mutatePromptCacheKey(body: body, headers: headers, cacheKey: cacheKey)
    }

    private static func mutatePromptCacheKey(
        body: Data,
        headers: [(String, String)],
        cacheKey: String
    ) -> PromptCacheMutation {
        guard var request = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return PromptCacheMutation(
                body: body,
                headers: headers,
                applied: false,
                strategy: "invalid_json",
                notes: ["Prompt cache key was not applied because the request body was not a JSON object."]
            )
        }

        if let existing = request["prompt_cache_key"] as? String,
           !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return PromptCacheMutation(
                body: body,
                headers: headers,
                applied: false,
                strategy: "existing_prompt_cache_key",
                notes: ["Existing prompt_cache_key preserved."]
            )
        }

        request["prompt_cache_key"] = cacheKey
        guard let mutatedBody = try? JSONSerialization.data(withJSONObject: request) else {
            return .passThrough(body: body, headers: headers)
        }

        return PromptCacheMutation(
            body: mutatedBody,
            headers: headers,
            applied: true,
            strategy: "prompt_cache_key"
        )
    }

    private static func mutateAnthropicCacheControl(
        body: Data,
        headers: [(String, String)]
    ) -> PromptCacheMutation {
        guard var request = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return PromptCacheMutation(
                body: body,
                headers: headers,
                applied: false,
                strategy: "invalid_json",
                notes: ["Anthropic cache_control was not applied because the request body was not a JSON object."]
            )
        }

        if request["cache_control"] != nil {
            return PromptCacheMutation(
                body: body,
                headers: headers,
                applied: false,
                strategy: "existing_anthropic_cache_control",
                notes: ["Existing Anthropic cache_control preserved."]
            )
        }

        request["cache_control"] = ["type": "ephemeral"]
        guard let mutatedBody = try? JSONSerialization.data(withJSONObject: request, options: [.sortedKeys]) else {
            return .passThrough(body: body, headers: headers)
        }

        return PromptCacheMutation(
            body: mutatedBody,
            headers: headers,
            applied: true,
            strategy: "anthropic_cache_control"
        )
    }

    private static func canonicalizeJSON(
        body: Data,
        headers: [(String, String)]
    ) -> PromptCacheMutation {
        guard let object = try? JSONSerialization.jsonObject(with: body),
              JSONSerialization.isValidJSONObject(object),
              let canonicalBody = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return PromptCacheMutation(
                body: body,
                headers: headers,
                applied: false,
                strategy: "invalid_json",
                notes: ["JSON canonicalization was not applied because the request body was not valid JSON."]
            )
        }

        guard canonicalBody != body else {
            return PromptCacheMutation(
                body: body,
                headers: headers,
                applied: false,
                strategy: "json_already_canonical"
            )
        }

        return PromptCacheMutation(
            body: canonicalBody,
            headers: headers,
            applied: true,
            strategy: "json_canonicalization"
        )
    }

    private static func mutateXAIChatHeaders(
        body: Data,
        headers: [(String, String)],
        cacheKey: String
    ) -> PromptCacheMutation {
        if headers.contains(where: { $0.0.lowercased() == "x-grok-conv-id" && !$0.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return PromptCacheMutation(
                body: body,
                headers: headers,
                applied: false,
                strategy: "existing_x-grok-conv-id",
                notes: ["Existing x-grok-conv-id preserved."]
            )
        }

        return PromptCacheMutation(
            body: body,
            headers: headers + [("x-grok-conv-id", cacheKey)],
            applied: true,
            strategy: "x-grok-conv-id"
        )
    }

    private static func normalizedModel(_ model: String?, body: Data) -> String {
        if let model = model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty {
            return model
        }
        if let request = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let bodyModel = request["model"] as? String {
            let trimmed = bodyModel.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return "unknown"
    }
}

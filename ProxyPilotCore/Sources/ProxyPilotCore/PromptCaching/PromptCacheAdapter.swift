import Foundation

public enum PromptCacheAdapter {
    /// Applies provider-appropriate cache hints to an outbound request.
    /// Returns the (possibly mutated) body + any additional headers.
    /// Off and observe-only preserve caller bytes and hints.
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
            return PromptCacheMutation(body: body, headers: headers, applied: false, strategy: "off")
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
            return PromptCacheMutation(body: body, headers: headers, applied: false, strategy: "observe_only")
        }

        guard configuration.mode == .computeCacheHints else {
            return .passThrough(body: body, headers: headers)
        }

        if provider == .openRouter,
           path.hasSuffix("/chat/completions") || path.hasSuffix("/messages") {
            return mutateOpenRouter(body: body, headers: headers, model: model, sessionID: sessionID, path: path)
        }

        if path.hasSuffix("/chat/completions"),
           provider == .ollama || provider == .lmStudio,
           let mutation = removeLeadingAnthropicBillingHeader(body: body, headers: headers) {
            return mutation
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

    private static func mutateOpenRouter(
        body: Data, headers: [(String, String)], model: String?, sessionID: String, path: String
    ) -> PromptCacheMutation {
        guard var request = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return PromptCacheMutation(body: body, headers: headers, applied: false, strategy: "invalid_json")
        }
        var strategies: [String] = []
        // OpenRouter gives body session_id precedence over x-session-id. Keep
        // either caller override, including invalid values for upstream validation.
        if request["session_id"] == nil && !headers.contains(where: { $0.0.lowercased() == "x-session-id" }) {
            request["session_id"] = "pp_" + PromptCacheSessionKey.make(
                provider: UpstreamProvider.openRouter.rawValue,
                model: request["model"] as? String ?? normalizedModel(model, body: body),
                sessionID: sessionID,
                route: path
            )
            strategies.append("openrouter_session_affinity")
        }
        let resolvedModel = (request["model"] as? String ?? normalizedModel(model, body: body)).lowercased()
        if resolvedModel.hasPrefix("anthropic/"), !containsCacheControl(request) {
            // Supported OpenRouter Anthropic automatic caching; default five
            // minute lifetime. Never add breakpoints beside caller-owned policy.
            request["cache_control"] = ["type": "ephemeral"]
            strategies.append("anthropic_auto_cache_control")
        }
        guard !strategies.isEmpty else {
            return PromptCacheMutation(body: body, headers: headers, applied: false, strategy: "existing_openrouter_cache_hints")
        }
        guard let mutated = try? JSONSerialization.data(withJSONObject: request, options: [.sortedKeys]) else {
            return .passThrough(body: body, headers: headers)
        }
        return PromptCacheMutation(body: mutated, headers: headers, applied: true, strategy: strategies.joined(separator: "+"))
    }

    private static func containsCacheControl(_ value: Any) -> Bool {
        if let object = value as? [String: Any] {
            return object["cache_control"] != nil || object.values.contains(where: containsCacheControl)
        }
        return (value as? [Any])?.contains(where: containsCacheControl) ?? false
    }

    private static func removeLeadingAnthropicBillingHeader(
        body: Data,
        headers: [(String, String)]
    ) -> PromptCacheMutation? {
        let prefix = "x-anthropic-billing-header:"
        guard var request = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              var messages = request["messages"] as? [[String: Any]],
              !messages.isEmpty,
              messages[0]["role"] as? String == "system",
              let content = messages[0]["content"] as? String,
              content.hasPrefix(prefix) else {
            return nil
        }

        if let newline = content.range(of: "\n") {
            messages[0]["content"] = String(content[newline.upperBound...])
        } else {
            messages[0]["content"] = ""
        }
        request["messages"] = messages

        guard let mutatedBody = try? JSONSerialization.data(withJSONObject: request, options: [.sortedKeys]) else {
            return nil
        }

        return PromptCacheMutation(
            body: mutatedBody,
            headers: headers,
            applied: true,
            strategy: "local_anthropic_billing_header_removed"
        )
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

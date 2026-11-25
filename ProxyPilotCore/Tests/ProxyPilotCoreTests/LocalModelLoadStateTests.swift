import Testing
import Foundation
@testable import ProxyPilotCore

/// Responses captured from LM Studio 0.4.28 `GET /api/v0/models` on
/// 2026-11-24, before and after loading the model with a 40,192 context.
@Suite("Local model load state")
struct LocalModelLoadStateTests {
    private let notLoaded = #"{"data":[{"id":"prism-ml/bonsai-27b","object":"model","type":"vlm","publisher":"prism-ml","arch":"qwen35","compatibility_type":"gguf","quantization":"Q1_0","state":"not-loaded","max_context_length":262144,"capabilities":["tool_use"]}],"object":"list"}"#
    private let loaded = #"{"data":[{"id":"prism-ml/bonsai-27b","object":"model","type":"vlm","publisher":"prism-ml","arch":"qwen35","compatibility_type":"gguf","quantization":"Q1_0","state":"loaded","max_context_length":262144,"loaded_context_length":40192,"capabilities":["tool_use"]}],"object":"list"}"#

    @Test func notLoadedModelIsReportedWithItsMaximum() {
        let state = LMStudioModelState.parse(Data(notLoaded.utf8))["prism-ml/bonsai-27b"]
        #expect(state == LocalModelLoadState(modelID: "prism-ml/bonsai-27b", isLoaded: false, maxContextLength: 262144))
        let text = state?.summary(providerTitle: "LM Studio") ?? ""
        #expect(text.hasPrefix("Not loaded in LM Studio."))
        #expect(text.contains("default context length"))
    }

    @Test func loadedModelReportsItsContext() {
        let state = LMStudioModelState.parse(Data(loaded.utf8))["prism-ml/bonsai-27b"]
        #expect(state == LocalModelLoadState(modelID: "prism-ml/bonsai-27b", isLoaded: true,
                                             loadedContextLength: 40192, maxContextLength: 262144))
        #expect(state?.summary(providerTitle: "LM Studio")
            == "Loaded with a 40,192-token context (model maximum 262,144).")
    }

    @Test func unknownOrMalformedAnswersAreAbsentNotUnloaded() {
        #expect(LMStudioModelState.parse(Data("not json".utf8)).isEmpty)
        #expect(LMStudioModelState.parse(Data(#"{"data":[{"id":"m","state":"loading"},{"state":"loaded"},{"id":"n"}]}"#.utf8)).isEmpty)
        #expect(LMStudioModelState.parse(Data(#"{"object":"list"}"#.utf8)).isEmpty)
    }

    @Test func loadStateURLKeepsTheOriginAndReplacesThePath() {
        #expect(LMStudioModelState.modelsURL(apiBase: "http://localhost:1234/v1")?.absoluteString
            == "http://localhost:1234/api/v0/models")
        #expect(LMStudioModelState.modelsURL(apiBase: "http://192.168.1.20:4321/v1/?x=1")?.absoluteString
            == "http://192.168.1.20:4321/api/v0/models")
        #expect(LMStudioModelState.modelsURL(apiBase: "localhost") == nil)
    }
}

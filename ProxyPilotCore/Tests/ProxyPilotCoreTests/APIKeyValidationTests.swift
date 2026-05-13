import ProxyPilotCore
import Testing

@Test func zAIKeysShorterThanTwentyCharactersAreRejected() {
    let result = APIKeyValidator.validate("short-zai-key", for: .zAI)

    #expect(result == .failure(
        code: "E046",
        message: "Z.ai API keys must be at least 20 characters long."
    ))
}

@Test func zAIKeysAtLeastTwentyCharactersAreAccepted() {
    let result = APIKeyValidator.validate("12345678901234567890", for: .zAI)

    #expect(result == .success)
}

@Test func nonZAIProviderKeepsExistingLengthBehavior() {
    let result = APIKeyValidator.validate("short-key", for: .openAI)

    #expect(result == .success)
}

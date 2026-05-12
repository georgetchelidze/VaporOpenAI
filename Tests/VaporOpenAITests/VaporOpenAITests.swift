import Testing
@testable import VaporOpenAI

@Test func responsesModelsExposeLatestGPT55Family() async throws {
    #expect(OpenAI.Responses.Model.gpt5_5.rawValue == "gpt-5.5")
    #expect(OpenAI.Responses.Model.gpt5_5Pro.rawValue == "gpt-5.5-pro")
}

@Test func responsesModelAllowsCustomStrings() async throws {
    let model = OpenAI.Responses.Model("custom-model-id")
    #expect(model.rawValue == "custom-model-id")
    #expect(model.tokenPricing == nil)
}

@Test func responsesModelAllowsCustomPricing() async throws {
    let model = OpenAI.Responses.Model(
        "custom-model-id",
        tokenPricing: .init(input: 1.00, cachedInput: 0.10, output: 5.00)
    )

    let pricing = try #require(model.tokenPricing)
    let cost = pricing.estimateCostUSD(
        promptTokens: 1_000_000,
        cachedPromptTokens: 500_000,
        completionTokens: 1_000_000
    )

    #expect(model.rawValue == "custom-model-id")
    #expect(cost == 5.55)
}

@Test func responsesGPT55PricingIsConfigured() async throws {
    let pricing = try #require(OpenAI.Responses.Model.gpt5_5.tokenPricing)
    let cost = pricing.estimateCostUSD(
        promptTokens: 1_000_000,
        cachedPromptTokens: 500_000,
        completionTokens: 1_000_000
    )

    #expect(cost == 32.75)
}

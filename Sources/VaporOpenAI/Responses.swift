import Foundation
import JSONValue
import Vapor

extension OpenAI {
    // MARK: - Responses

    public enum Responses {
        // MARK: Models & basic enums

        /// Token pricing configuration for a model (USD per 1,000,000 tokens).
        ///
        /// Includes "cached input" pricing (for prompt tokens served from cache).
        public struct TokenPricing: Sendable {
            /// USD cost per 1,000,000 input (prompt) tokens (non-cached).
            public let input: Decimal
            /// USD cost per 1,000,000 cached input (prompt) tokens.
            public let cachedInput: Decimal
            /// USD cost per 1,000,000 output (completion) tokens.
            public let output: Decimal

            public init(
                input: Decimal,
                cachedInput: Decimal,
                output: Decimal
            ) {
                self.input = input
                self.cachedInput = cachedInput
                self.output = output
            }

            public func estimateCostUSD(
                promptTokens: Int,
                cachedPromptTokens: Int,
                completionTokens: Int
            ) -> Decimal {
                let prompt = max(0, promptTokens)
                let cached = min(max(0, cachedPromptTokens), prompt)
                let nonCached = prompt - cached
                let completion = max(0, completionTokens)

                let per1M = Decimal(1_000_000)
                let nonCachedPromptCost = (Decimal(nonCached) / per1M) * input
                let cachedPromptCost = (Decimal(cached) / per1M) * cachedInput
                let completionCost = (Decimal(completion) / per1M) * output
                return nonCachedPromptCost + cachedPromptCost + completionCost
            }
        }

        /// Supported default models for the Responses API.
        public enum Model: String, Sendable {
            case gpt5_4 = "gpt-5.4"
            case gpt5_4Mini = "gpt-5.4-mini"
            case gpt5_4Nano = "gpt-5.4-nano"
            case gpt5 = "gpt-5"
            case gpt5Mini = "gpt-5-mini"
            case gpt5Nano = "gpt-5-nano"

            /// Hardcoded token pricing (USD per 1,000,000 tokens).
            ///
            /// Source (provided): GPT-5 family pricing table:
            /// - gpt-5.4: input $2.50, cached input $0.25, output $15.00
            /// - gpt-5.4-mini: input $0.75, cached input $0.075, output $4.50
            /// - gpt-5.4-nano: input $0.20, cached input $0.02, output $1.25
            /// - gpt-5: input $1.25, cached input $0.125, output $10.00
            /// - gpt-5-mini: input $0.25, cached input $0.025, output $2.00
            /// - gpt-5-nano: input $0.05, cached input $0.005, output $0.40
            public var tokenPricing: TokenPricing {
                switch self {
                case .gpt5_4:
                    return TokenPricing(input: 2.50, cachedInput: 0.25, output: 15.00)
                case .gpt5_4Mini:
                    return TokenPricing(input: 0.75, cachedInput: 0.075, output: 4.50)
                case .gpt5_4Nano:
                    return TokenPricing(input: 0.20, cachedInput: 0.02, output: 1.25)
                case .gpt5:
                    return TokenPricing(input: 1.25, cachedInput: 0.125, output: 10.00)
                case .gpt5Mini:
                    return TokenPricing(input: 0.25, cachedInput: 0.025, output: 2.00)
                case .gpt5Nano:
                    return TokenPricing(input: 0.05, cachedInput: 0.005, output: 0.40)
                }
            }
        }
        /// Controls how much internal "thinking" the model does.
        public enum ReasoningEffort: String, Codable, Sendable {
            case none
            case low
            case medium
            case high
        }

        /// Controls how verbose the model's natural language output is.
        public enum Verbosity: String, Codable, Sendable {
            case low
            case medium
            case high
        }

        /// Controls whether the model should produce a reasoning summary,
        /// and at what level of detail.
        public enum ReasoningSummary: Codable, Sendable {
            case detailed
            case auto
            case null

            public init(from decoder: any Decoder) throws {
                let container = try decoder.singleValueContainer()
                if container.decodeNil() {
                    self = .null
                    return
                }
                let raw = try container.decode(String.self)
                switch raw {
                case "detailed":
                    self = .detailed
                case "auto":
                    self = .auto
                default:
                    throw DecodingError.dataCorruptedError(
                        in: container,
                        debugDescription: "Invalid ReasoningSummary value: \(raw)"
                    )
                }
            }

            public func encode(to encoder: any Encoder) throws {
                var container = encoder.singleValueContainer()
                switch self {
                case .detailed:
                    try container.encode("detailed")
                case .auto:
                    try container.encode("auto")
                case .null:
                    try container.encodeNil()
                }
            }
        }

        /// High-level text output format for the Responses API.
        public enum TextFormatType: Sendable {
            /// Plain text output (`{ "type": "text" }`).
            case text
            /// JSON Schema output (`{ "type": "json_schema", "name": ..., "schema": ..., "strict": ... }`).
            case jsonSchema(name: String, strict: Bool, schema: JSONValue)
        }

        // MARK: Tools

        /// Supported tools for the Responses API.
        ///
        /// For now we only expose web search, but this enum gives us a clean
        /// place to add other tools later (file_search, code_interpreter, etc.).
        public enum Tool: Sendable {
            case webSearch(WebSearchConfig)

            /// Convenience constructor so callers can write:
            /// `.webSearch(allowedDomains: ["openai.com"])`
            public static func webSearch(
                allowedDomains: [String]? = nil,
                externalWebAccess: Bool? = nil,
                searchContextSize: WebSearchContextSize? = nil,
                userLocation: WebSearchUserLocation? = nil
            ) -> Tool {
                .webSearch(
                    WebSearchConfig(
                        allowedDomains: allowedDomains,
                        externalWebAccess: externalWebAccess,
                        searchContextSize: searchContextSize,
                        userLocation: userLocation
                    )
                )
            }
        }

        public enum WebSearchContextSize: String, Codable, Sendable {
            case low
            case medium
            case high
        }

        public struct WebSearchUserLocation: Codable, Sendable {
            public let type: String
            public let city: String?
            public let country: String?
            public let region: String?
            public let timezone: String?

            public init(
                city: String? = nil,
                country: String? = nil,
                region: String? = nil,
                timezone: String? = nil
            ) {
                self.type = "approximate"
                self.city = city
                self.country = country
                self.region = region
                self.timezone = timezone
            }
        }

        /// Configuration for the `web_search` tool.
        public struct WebSearchConfig: Sendable {
            /// Optional allow-list of domains (up to the platform limit, currently 100).
            /// Example values: `"openai.com"`, `"pubmed.ncbi.nlm.nih.gov"`.
            public var allowedDomains: [String]?

            /// Whether the tool may hit live external sites (`true`) or only cached/indexed
            /// results (`false`). If `nil`, the platform default is used.
            public var externalWebAccess: Bool?

            /// Guidance for how much context budget to spend on the web search.
            /// Higher values generally produce broader retrieval.
            public var searchContextSize: WebSearchContextSize?

            /// Optional approximate user location to bias geographically-sensitive queries.
            public var userLocation: WebSearchUserLocation?

            public init(
                allowedDomains: [String]? = nil,
                externalWebAccess: Bool? = nil,
                searchContextSize: WebSearchContextSize? = nil,
                userLocation: WebSearchUserLocation? = nil
            ) {
                self.allowedDomains = allowedDomains
                self.externalWebAccess = externalWebAccess
                self.searchContextSize = searchContextSize
                self.userLocation = userLocation
            }
        }

        // MARK: Request/response envelopes

        private struct RequestBody: Content {
            let model: String
            let input: String
            let instructions: String?
            let max_output_tokens: Int?
            let reasoning: Reasoning?
            let text: TextConfig?
            let tools: [ToolPayload]?
            let include: [String]?
        }

        private struct Reasoning: Content {
            let effort: ReasoningEffort?
            let summary: ReasoningSummary?
        }

        private struct TextConfig: Content {
            let format: JSONValue?
            let verbosity: Verbosity?
        }

        /// Wire-format for the `tools` array.
        private struct ToolPayload: Content {
            struct Filters: Content {
                let allowed_domains: [String]?
            }

            let type: String
            let filters: Filters?
            let external_web_access: Bool?
            let search_context_size: String?
            let user_location: WebSearchUserLocation?
        }

        private struct ResponseEnvelope: Decodable {
            struct ContentPart: Decodable {
                let type: String
                let text: String?
            }

            struct OutputItem: Decodable {
                let type: String
                let content: [ContentPart]?
            }

            /// Usage fields vary slightly by API/SDK shape, so we decode a superset:
            /// - ChatCompletions-like: prompt_tokens / completion_tokens / total_tokens
            /// - Responses-like: input_tokens / output_tokens / total_tokens
            /// - Cached input tokens (when provided): *_tokens_details.cached_tokens
            struct Usage: Decodable {
                struct TokenDetails: Decodable {
                    let cached_tokens: Int?
                }

                let prompt_tokens: Int?
                let completion_tokens: Int?
                let total_tokens: Int?

                let input_tokens: Int?
                let output_tokens: Int?

                let prompt_tokens_details: TokenDetails?
                let input_tokens_details: TokenDetails?

                var promptTokens: Int { prompt_tokens ?? input_tokens ?? 0 }
                var completionTokens: Int { completion_tokens ?? output_tokens ?? 0 }
                var totalTokens: Int { total_tokens ?? (promptTokens + completionTokens) }

                var cachedPromptTokens: Int {
                    prompt_tokens_details?.cached_tokens
                        ?? input_tokens_details?.cached_tokens
                        ?? 0
                }
            }

            let output: [OutputItem]
            let usage: Usage?
        }

        /// Public usage/cost summary returned to callers for tracking run cost.
        public struct UsageSummary: Sendable {
            public let model: Model
            public let promptTokens: Int
            public let cachedPromptTokens: Int
            public let completionTokens: Int
            public let totalTokens: Int
            public let estimatedCostUSD: Double

            public init(
                model: Model,
                promptTokens: Int,
                cachedPromptTokens: Int,
                completionTokens: Int,
                totalTokens: Int,
                estimatedCostUSD: Double
            ) {
                self.model = model
                self.promptTokens = promptTokens
                self.cachedPromptTokens = cachedPromptTokens
                self.completionTokens = completionTokens
                self.totalTokens = totalTokens
                self.estimatedCostUSD = estimatedCostUSD
            }
        }

        private static func makeUsageSummary(
            model: Model,
            usage: ResponseEnvelope.Usage
        ) -> UsageSummary {
            let promptTokens = usage.promptTokens
            let completionTokens = usage.completionTokens
            let cachedPromptTokens = usage.cachedPromptTokens

            let pricing = model.tokenPricing
            let estimatedDecimal = pricing.estimateCostUSD(
                promptTokens: promptTokens,
                cachedPromptTokens: cachedPromptTokens,
                completionTokens: completionTokens
            )
            let estimatedCostUSD = NSDecimalNumber(decimal: estimatedDecimal).doubleValue

            return UsageSummary(
                model: model,
                promptTokens: promptTokens,
                cachedPromptTokens: cachedPromptTokens,
                completionTokens: completionTokens,
                totalTokens: usage.totalTokens,
                estimatedCostUSD: estimatedCostUSD
            )
        }

        /// Calls OpenAI's /v1/responses endpoint with a simple text input and
        /// returns the first text chunk (or the raw body if parsing fails).
        public static func create(
            model: Model = .gpt5,
            instructions: String? = nil,
            input: String,
            textFormat: TextFormatType? = nil,
            maxOutputTokens: Int? = nil,
            reasoningEffort: ReasoningEffort? = nil,
            reasoningSummary: ReasoningSummary? = nil,
            verbosity: Verbosity? = nil,
            tools: [Tool]? = nil,
            include: [String]? = nil,
            on app: Application
        ) async throws -> String {
            let (text, _) = try await createWithUsage(
                model: model,
                instructions: instructions,
                input: input,
                textFormat: textFormat,
                maxOutputTokens: maxOutputTokens,
                reasoningEffort: reasoningEffort,
                reasoningSummary: reasoningSummary,
                verbosity: verbosity,
                tools: tools,
                include: include,
                on: app
            )
            return text
        }

        /// Variant of `create(...)` that returns a costed usage summary (when available)
        /// so callers (jobs/workflows) can persist spend to `KWR.Run.totalCost`.
        public static func createWithUsage(
            model: Model = .gpt5,
            instructions: String? = nil,
            input: String,
            textFormat: TextFormatType? = nil,
            maxOutputTokens: Int? = nil,
            reasoningEffort: ReasoningEffort? = nil,
            reasoningSummary: ReasoningSummary? = nil,
            verbosity: Verbosity? = nil,
            tools: [Tool]? = nil,
            include: [String]? = nil,
            on app: Application
        ) async throws -> (text: String, usage: UsageSummary?) {
            guard !input.isEmpty else {
                return ("", nil)
            }

            // Choose model: explicit parameter wins; otherwise use a fixed default.
            let modelName = model.rawValue

            let textConfig = makeTextConfig(format: textFormat, verbosity: verbosity)
            let toolPayloads = makeToolPayloads(from: tools)

            let limits = resolveResponsesLimits(for: model)
            let response = try await app.openAIResponsesLimiter.withPermit(
                model: model, limits: limits
            ) {
                try await OpenAI.post("responses", on: app) { req in
                    let body = RequestBody(
                        model: modelName,
                        input: input,
                        instructions: instructions,
                        max_output_tokens: maxOutputTokens,
                        reasoning: Reasoning(effort: reasoningEffort, summary: reasoningSummary),
                        text: textConfig,
                        tools: toolPayloads,
                        include: include
                    )
                    try req.content.encode(body)
                }
            }

            try OpenAI.requireOK(response, context: "OpenAI responses error")

            let data = response.body.flatMap { Data(buffer: $0) } ?? Data()
            let envelope = try JSONDecoder().decode(ResponseEnvelope.self, from: data)

            let summary: UsageSummary?
            if let usage = envelope.usage {
                let computed = makeUsageSummary(model: model, usage: usage)

                app.logger.info(
                    "OpenAI Responses usage: model=\(modelName) prompt_tokens=\(computed.promptTokens) cached_prompt_tokens=\(computed.cachedPromptTokens) completion_tokens=\(computed.completionTokens) total_tokens=\(computed.totalTokens) estimated_cost_usd=\(computed.estimatedCostUSD)"
                )
                summary = computed
            } else {
                summary = nil
            }

            for item in envelope.output {
                guard item.type == "message",
                    let parts = item.content
                else { continue }

                if let first = parts.first(where: { $0.type == "output_text" || $0.type == "text" }
                ),
                    let value = first.text
                {
                    return (value, summary)
                }
            }

            return (String(data: data, encoding: .utf8) ?? "", summary)
        }

        private static func makeTextConfig(
            format: TextFormatType?,
            verbosity: Verbosity?
        ) -> TextConfig? {
            if format == nil && verbosity == nil {
                return nil
            }

            let formatJSON: JSONValue?
            switch format {
            case .none:
                formatJSON = nil
            case .text?:
                formatJSON = .object([
                    "type": .string("text")
                ])
            case .jsonSchema(let name, let strict, let schema)?:
                formatJSON = .object([
                    "type": .string("json_schema"),
                    "name": .string(name),
                    "schema": schema,
                    "strict": .bool(strict),
                ])
            }

            return TextConfig(format: formatJSON, verbosity: verbosity)
        }

        /// Convert high-level tool configuration into the JSON wire format expected
        /// by the Responses API.
        private static func makeToolPayloads(from tools: [Tool]?) -> [ToolPayload]? {
            guard let tools, !tools.isEmpty else {
                return nil
            }

            var payloads: [ToolPayload] = []
            payloads.reserveCapacity(tools.count)

            for tool in tools {
                switch tool {
                case .webSearch(let config):
                    let filters: ToolPayload.Filters?
                    if let allowed = config.allowedDomains, !allowed.isEmpty {
                        filters = ToolPayload.Filters(allowed_domains: allowed)
                    } else {
                        filters = nil
                    }

                    let payload = ToolPayload(
                        type: "web_search",
                        filters: filters,
                        external_web_access: config.externalWebAccess,
                        search_context_size: config.searchContextSize?.rawValue,
                        user_location: config.userLocation
                    )
                    payloads.append(payload)
                }
            }

            return payloads.isEmpty ? nil : payloads
        }

        /// Helper for callers that still want a pre-wrapped format object.
        public static func wrapSchemaFormat(_ schema: JSONValue) -> JSONValue {
            if case .object(let obj) = schema, obj["type"] != nil {
                return schema
            }

            return .object([
                "type": .string("json_schema"),
                "schema": schema,
            ])
        }
    }
}

// MARK: - Vapor integration

extension Application {
    private struct OpenAIResponsesLimiterKey: StorageKey {
        typealias Value = OpenAI.ResponsesLimiter
    }

    fileprivate var openAIResponsesLimiter: OpenAI.ResponsesLimiter {
        if let existing = storage[OpenAIResponsesLimiterKey.self] {
            return existing
        }
        let created = OpenAI.ResponsesLimiter()
        storage[OpenAIResponsesLimiterKey.self] = created
        return created
    }
}

// MARK: - Configuration

private func resolveResponsesLimits(for model: OpenAI.Responses.Model)
    -> OpenAI.ResponsesLimiter.Limits
{
    // Defaults are intentionally conservative to prevent bursty behavior when
    // multiple background jobs share the same OpenAI key.
    let defaultMaxInFlight = 12
    let maxInFlight = envInt(
        "OPENAI_RESPONSES_MAX_IN_FLIGHT_\(model.envKey)",
        fallback: envInt("OPENAI_RESPONSES_MAX_IN_FLIGHT", fallback: defaultMaxInFlight)
    )

    let defaultMinIntervalMs = (model == .gpt5Mini || model == .gpt5_4Mini) ? 120 : 0
    let minIntervalMs = envInt(
        "OPENAI_RESPONSES_MIN_INTERVAL_MS_\(model.envKey)",
        fallback: envInt("OPENAI_RESPONSES_MIN_INTERVAL_MS", fallback: defaultMinIntervalMs)
    )

    return OpenAI.ResponsesLimiter.Limits(
        maxInFlight: max(1, maxInFlight),
        minStartIntervalNs: UInt64(max(0, minIntervalMs)) * 1_000_000
    )
}

private func envInt(_ key: String, fallback: Int) -> Int {
    guard let raw = Environment.get(key), !raw.isEmpty else { return fallback }
    return Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? fallback
}

extension OpenAI.Responses.Model {
    fileprivate var envKey: String {
        switch self {
        case .gpt5_4: return "GPT5_4"
        case .gpt5_4Mini: return "GPT5_4_MINI"
        case .gpt5_4Nano: return "GPT5_4_NANO"
        case .gpt5: return "GPT5"
        case .gpt5Mini: return "GPT5_MINI"
        case .gpt5Nano: return "GPT5_NANO"
        }
    }
}

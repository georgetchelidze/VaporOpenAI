import Foundation
import Vapor

extension OpenAI {
        public enum Images {
        public enum Model: String, Sendable {
            case gptImage2 = "gpt-image-2"
            case gptImage15 = "gpt-image-1.5"
            case gptImage1 = "gpt-image-1"
            case gptImage1Mini = "gpt-image-1-mini"
        }

        public enum Size: String, Content, Sendable {
            case auto
            case square = "1024x1024"
            case portrait = "1024x1536"
            case landscape = "1536x1024"
        }

        public enum Quality: String, Content, Sendable {
            case auto
            case low
            case medium
            case high
        }

        public enum Background: String, Content, Sendable {
            case auto
            case transparent
            case opaque
        }

        public enum OutputFormat: String, Content, Sendable {
            case png
            case webp
            case jpeg
        }

        public struct UsageSummary: Sendable {
            public let inputTokens: Int?
            public let outputTokens: Int?
            public let totalTokens: Int?
            public let estimatedCostUSD: Double?

            public init(
                inputTokens: Int?,
                outputTokens: Int?,
                totalTokens: Int?,
                estimatedCostUSD: Double?
            ) {
                self.inputTokens = inputTokens
                self.outputTokens = outputTokens
                self.totalTokens = totalTokens
                self.estimatedCostUSD = estimatedCostUSD
            }
        }

        private struct TokenPricing {
            let inputPer1M: Decimal
            let outputPer1M: Decimal
        }

        public struct Generation: Sendable {
            public let model: Model
            public let imageData: Data
            public let revisedPrompt: String?
            public let usage: UsageSummary?

            public init(
                model: Model,
                imageData: Data,
                revisedPrompt: String?,
                usage: UsageSummary?
            ) {
                self.model = model
                self.imageData = imageData
                self.revisedPrompt = revisedPrompt
                self.usage = usage
            }
        }

        private struct RequestBody: Content {
            let model: String
            let prompt: String
            let size: String?
            let quality: String?
            let background: String?
            let output_format: String?
            let n: Int
        }

        private struct ResponseEnvelope: Decodable {
            struct Item: Decodable {
                let b64_json: String?
                let revised_prompt: String?
                let url: String?
            }

            struct Usage: Decodable {
                let input_tokens: Int?
                let output_tokens: Int?
                let total_tokens: Int?
            }

            let data: [Item]
            let usage: Usage?
        }

        public static func generate(
            model: Model = .gptImage15,
            prompt: String,
            size: Size = .square,
            quality: Quality = .medium,
            background: Background = .transparent,
            outputFormat: OutputFormat = .png,
            on app: Application
        ) async throws -> Generation {
            let response = try await OpenAI.post("images/generations", on: app) { req in
                try req.content.encode(
                    RequestBody(
                        model: model.rawValue,
                        prompt: prompt,
                        size: size.rawValue,
                        quality: quality.rawValue,
                        background: background.rawValue,
                        output_format: outputFormat.rawValue,
                        n: 1
                    )
                )
            }

            try OpenAI.requireOK(response, context: "OpenAI image generation failed")

            let rawData = response.body.flatMap { Data(buffer: $0) } ?? Data()
            let envelope = try JSONDecoder().decode(ResponseEnvelope.self, from: rawData)

            guard let first = envelope.data.first else {
                throw Abort(
                    .internalServerError, reason: "OpenAI image generation returned no image data")
            }

            let imageData: Data
            if let b64 = first.b64_json,
                let decoded = Data(base64Encoded: b64, options: .ignoreUnknownCharacters),
                !decoded.isEmpty
            {
                imageData = decoded
            } else if let url = first.url, let parsed = URL(string: url) {
                let downloadResponse = try await app.client.get(URI(string: parsed.absoluteString))
                guard downloadResponse.status == .ok,
                    let body = downloadResponse.body,
                    !body.readableBytesView.isEmpty
                else {
                    throw Abort(.internalServerError, reason: "OpenAI image URL download failed")
                }
                imageData = Data(buffer: body)
            } else {
                throw Abort(
                    .internalServerError,
                    reason: "OpenAI image generation response did not include b64_json or url")
            }

            let usage = envelope.usage.map {
                let pricing = resolveTokenPricing(for: model)
                let estimatedCost: Double?
                if let pricing,
                    let inputTokens = $0.input_tokens,
                    let outputTokens = $0.output_tokens
                {
                    let per1M = Decimal(1_000_000)
                    let inputCost = (Decimal(inputTokens) / per1M) * pricing.inputPer1M
                    let outputCost = (Decimal(outputTokens) / per1M) * pricing.outputPer1M
                    estimatedCost = NSDecimalNumber(decimal: inputCost + outputCost).doubleValue
                } else {
                    estimatedCost = nil
                }

                if let estimatedCost {
                    app.logger.info(
                        "OpenAI Images usage: model=\(model.rawValue) input_tokens=\($0.input_tokens ?? 0) output_tokens=\($0.output_tokens ?? 0) total_tokens=\($0.total_tokens ?? 0) estimated_cost_usd=\(estimatedCost)"
                    )
                } else {
                    app.logger.info(
                        "OpenAI Images usage: model=\(model.rawValue) input_tokens=\($0.input_tokens ?? 0) output_tokens=\($0.output_tokens ?? 0) total_tokens=\($0.total_tokens ?? 0) estimated_cost_usd=<unconfigured>"
                    )
                }
                return UsageSummary(
                    inputTokens: $0.input_tokens,
                    outputTokens: $0.output_tokens,
                    totalTokens: $0.total_tokens,
                    estimatedCostUSD: estimatedCost
                )
            }

            return Generation(
                model: model,
                imageData: imageData,
                revisedPrompt: first.revised_prompt,
                usage: usage
            )
        }

        private static func resolveTokenPricing(for model: Model) -> TokenPricing? {
            switch model {
            case .gptImage2:
                return nil
            case .gptImage15:
                // USD per 1,000,000 image tokens.
                return TokenPricing(inputPer1M: 8, outputPer1M: 32)
            case .gptImage1, .gptImage1Mini:
                return nil
            }
        }
    }
}

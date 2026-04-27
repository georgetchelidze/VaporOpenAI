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
            case square2K = "2048x2048"
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
            public let textInputTokens: Int?
            public let imageInputTokens: Int?
            public let outputTokens: Int?
            public let textOutputTokens: Int?
            public let imageOutputTokens: Int?
            public let totalTokens: Int?
            public let estimatedCostUSD: Double?

            public init(
                inputTokens: Int?,
                textInputTokens: Int? = nil,
                imageInputTokens: Int? = nil,
                outputTokens: Int?,
                textOutputTokens: Int? = nil,
                imageOutputTokens: Int? = nil,
                totalTokens: Int?,
                estimatedCostUSD: Double?
            ) {
                self.inputTokens = inputTokens
                self.textInputTokens = textInputTokens
                self.imageInputTokens = imageInputTokens
                self.outputTokens = outputTokens
                self.textOutputTokens = textOutputTokens
                self.imageOutputTokens = imageOutputTokens
                self.totalTokens = totalTokens
                self.estimatedCostUSD = estimatedCostUSD
            }
        }

        private struct TokenPricing {
            let textInputPer1M: Decimal
            let imageInputPer1M: Decimal
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
                struct TokenDetails: Decodable {
                    let text_tokens: Int?
                    let image_tokens: Int?
                }

                let input_tokens: Int?
                let input_tokens_details: TokenDetails?
                let output_tokens: Int?
                let output_tokens_details: TokenDetails?
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

            let imageData = try await decodeImageData(
                from: first,
                app: app,
                emptyReason: "OpenAI image generation response did not include b64_json or url",
                downloadReason: "OpenAI image URL download failed"
            )

            return Generation(
                model: model,
                imageData: imageData,
                revisedPrompt: first.revised_prompt,
                usage: usageSummary(from: envelope.usage, model: model, app: app)
            )
        }

        public static func edit(
            model: Model = .gptImage2,
            prompt: String,
            imageData: Data,
            imageFilename: String = "image.png",
            imageMimeType: String = "image/png",
            maskData: Data? = nil,
            maskFilename: String = "mask.png",
            maskMimeType: String = "image/png",
            size: Size = .square,
            quality: Quality = .high,
            outputFormat: OutputFormat = .png,
            on app: Application
        ) async throws -> Generation {
            guard !imageData.isEmpty else {
                throw Abort(.badRequest, reason: "OpenAI image edit error: image data is empty")
            }

            let boundary = "Boundary-\(UUID().uuidString)"
            let body = makeEditMultipartBody(
                boundary: boundary,
                fields: [
                    "model": model.rawValue,
                    "prompt": prompt,
                    "size": size.rawValue,
                    "quality": quality.rawValue,
                    "output_format": outputFormat.rawValue,
                ],
                imageData: imageData,
                imageFilename: imageFilename,
                imageMimeType: imageMimeType,
                maskData: maskData,
                maskFilename: maskFilename,
                maskMimeType: maskMimeType
            )

            let response = try await OpenAI.post("images/edits", on: app) { req in
                req.headers.remove(name: .contentType)
                req.headers.add(
                    name: .contentType, value: "multipart/form-data; boundary=\(boundary)")
                req.body = .init(data: body)
            }

            try OpenAI.requireOK(response, context: "OpenAI image edit error")

            let rawData = response.body.flatMap { Data(buffer: $0) } ?? Data()
            let envelope = try JSONDecoder().decode(ResponseEnvelope.self, from: rawData)

            guard let first = envelope.data.first else {
                throw Abort(
                    .internalServerError, reason: "OpenAI image edit returned no image data")
            }

            let imageData = try await decodeImageData(
                from: first,
                app: app,
                emptyReason: "OpenAI image edit response did not include b64_json or url",
                downloadReason: "OpenAI image edit URL download failed"
            )

            return Generation(
                model: model,
                imageData: imageData,
                revisedPrompt: first.revised_prompt,
                usage: usageSummary(from: envelope.usage, model: model, app: app)
            )
        }

        private static func resolveTokenPricing(for model: Model) -> TokenPricing? {
            switch model {
            case .gptImage2:
                // Source: https://openai.com/api/pricing/ (GPT-image-2, April 2026).
                return TokenPricing(textInputPer1M: 5, imageInputPer1M: 8, outputPer1M: 30)
            case .gptImage15:
                // USD per 1,000,000 image tokens.
                return TokenPricing(textInputPer1M: 8, imageInputPer1M: 8, outputPer1M: 32)
            case .gptImage1, .gptImage1Mini:
                return nil
            }
        }

        private static func decodeImageData(
            from item: ResponseEnvelope.Item,
            app: Application,
            emptyReason: String,
            downloadReason: String
        ) async throws -> Data {
            if let b64 = item.b64_json,
                let decoded = Data(base64Encoded: b64, options: .ignoreUnknownCharacters),
                !decoded.isEmpty
            {
                return decoded
            }

            if let url = item.url, let parsed = URL(string: url) {
                let downloadResponse = try await app.client.get(URI(string: parsed.absoluteString))
                guard downloadResponse.status == .ok,
                    let body = downloadResponse.body,
                    !body.readableBytesView.isEmpty
                else {
                    throw Abort(.internalServerError, reason: downloadReason)
                }
                return Data(buffer: body)
            }

            throw Abort(.internalServerError, reason: emptyReason)
        }

        private static func usageSummary(
            from usage: ResponseEnvelope.Usage?,
            model: Model,
            app: Application
        ) -> UsageSummary? {
            usage.map {
                let pricing = resolveTokenPricing(for: model)
                let estimatedCost: Double?
                if let pricing,
                    let inputTokens = $0.input_tokens,
                    let outputTokens = $0.output_tokens
                {
                    let per1M = Decimal(1_000_000)
                    let textInputTokens = $0.input_tokens_details?.text_tokens
                    let imageInputTokens = $0.input_tokens_details?.image_tokens
                    let detailedInputTokens = (textInputTokens ?? 0) + (imageInputTokens ?? 0)
                    let fallbackInputTokens = max(0, inputTokens - detailedInputTokens)
                    let inputCost =
                        (Decimal(textInputTokens ?? 0) / per1M) * pricing.textInputPer1M
                        + (Decimal(imageInputTokens ?? 0) / per1M) * pricing.imageInputPer1M
                        + (Decimal(fallbackInputTokens) / per1M) * pricing.imageInputPer1M
                    let outputCost =
                        (Decimal(outputTokens) / per1M) * pricing.outputPer1M
                    estimatedCost = NSDecimalNumber(decimal: inputCost + outputCost).doubleValue
                } else {
                    estimatedCost = nil
                }

                let detailLog =
                    "input_text_tokens=\($0.input_tokens_details?.text_tokens ?? 0) input_image_tokens=\($0.input_tokens_details?.image_tokens ?? 0) output_text_tokens=\($0.output_tokens_details?.text_tokens ?? 0) output_image_tokens=\($0.output_tokens_details?.image_tokens ?? 0)"
                if let estimatedCost {
                    app.logger.info(
                        "OpenAI Images usage: model=\(model.rawValue) input_tokens=\($0.input_tokens ?? 0) \(detailLog) output_tokens=\($0.output_tokens ?? 0) total_tokens=\($0.total_tokens ?? 0) estimated_cost_usd=\(estimatedCost)"
                    )
                } else {
                    app.logger.info(
                        "OpenAI Images usage: model=\(model.rawValue) input_tokens=\($0.input_tokens ?? 0) \(detailLog) output_tokens=\($0.output_tokens ?? 0) total_tokens=\($0.total_tokens ?? 0) estimated_cost_usd=<unconfigured>"
                    )
                }
                return UsageSummary(
                    inputTokens: $0.input_tokens,
                    textInputTokens: $0.input_tokens_details?.text_tokens,
                    imageInputTokens: $0.input_tokens_details?.image_tokens,
                    outputTokens: $0.output_tokens,
                    textOutputTokens: $0.output_tokens_details?.text_tokens,
                    imageOutputTokens: $0.output_tokens_details?.image_tokens,
                    totalTokens: $0.total_tokens,
                    estimatedCostUSD: estimatedCost
                )
            }
        }

        private static func makeEditMultipartBody(
            boundary: String,
            fields: [String: String],
            imageData: Data,
            imageFilename: String,
            imageMimeType: String,
            maskData: Data?,
            maskFilename: String,
            maskMimeType: String
        ) -> Data {
            var data = Data()

            for (name, value) in fields {
                data.appendString("--\(boundary)\r\n")
                data.appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
                data.appendString("\(value)\r\n")
            }

            appendMultipartFile(
                name: "image",
                filename: imageFilename,
                mimeType: imageMimeType,
                fileData: imageData,
                boundary: boundary,
                to: &data
            )

            if let maskData {
                appendMultipartFile(
                    name: "mask",
                    filename: maskFilename,
                    mimeType: maskMimeType,
                    fileData: maskData,
                    boundary: boundary,
                    to: &data
                )
            }

            data.appendString("--\(boundary)--\r\n")
            return data
        }

        private static func appendMultipartFile(
            name: String,
            filename: String,
            mimeType: String,
            fileData: Data,
            boundary: String,
            to data: inout Data
        ) {
            data.appendString("--\(boundary)\r\n")
            data.appendString(
                "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(escapeForMultipart(filename))\"\r\n"
            )
            data.appendString("Content-Type: \(mimeType)\r\n\r\n")
            data.append(fileData)
            data.appendString("\r\n")
        }

        private static func escapeForMultipart(_ value: String) -> String {
            value.replacingOccurrences(of: "\"", with: "\\\"")
        }
    }
}

extension Data {
    fileprivate mutating func appendString(_ value: String) {
        append(contentsOf: value.utf8)
    }
}

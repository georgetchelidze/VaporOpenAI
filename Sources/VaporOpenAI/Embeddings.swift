import Vapor

extension OpenAI {
    // MARK: - Embeddings

    public enum Embeddings {
        public enum EmbeddingModel: Sendable {
            case small
            case large

            var rawValue: String {
                switch self {
                case .small:
                    return "text-embedding-3-small"
                case .large:
                    return "text-embedding-3-large"
                }
            }

            var defaultDimensions: Int {
                switch self {
                case .small:
                    return 1536
                case .large:
                    return 3072
                }
            }
        }

        private struct RequestBody: Content {
            let model: String
            let input: [String]
            let dimensions: Int?
        }

        private struct Usage: Decodable {
            let prompt_tokens: Int?
        }

        private struct DataItem: Decodable {
            let embedding: [Double]
        }

        private struct ResponseBody: Decodable {
            let data: [DataItem]
            let usage: Usage?
        }

        /// Calls OpenAI's embeddings API and returns the embeddings and token usage.
        public static func create(
            texts: [String],
            model: EmbeddingModel = .small,
            dimensions: Int? = nil,
            on app: Application
        ) async throws -> ([[Double]], Int) {
            guard !texts.isEmpty else { return ([], 0) }
            try validateDimensions(dimensions, for: model)

            let response = try await OpenAI.post("embeddings", on: app) { req in
                try req.content.encode(
                    RequestBody(
                        model: model.rawValue,
                        input: texts,
                        dimensions: dimensions
                    )
                )
            }

            try OpenAI.requireOK(response, context: "OpenAI embeddings error")

            let body = try response.content.decode(ResponseBody.self)
            let vectors = body.data.map { $0.embedding }
            let tokens = body.usage?.prompt_tokens ?? 0
            return (vectors, tokens)
        }

        private static func validateDimensions(
            _ dimensions: Int?,
            for model: EmbeddingModel
        ) throws {
            guard let dimensions else { return }
            guard dimensions > 0 else {
                throw Abort(.badRequest, reason: "OpenAI embeddings error: dimensions must be > 0")
            }
            guard dimensions <= model.defaultDimensions else {
                throw Abort(
                    .badRequest,
                    reason:
                        "OpenAI embeddings error: dimensions \(dimensions) exceed max \(model.defaultDimensions) for \(model.rawValue)"
                )
            }
        }
    }
}

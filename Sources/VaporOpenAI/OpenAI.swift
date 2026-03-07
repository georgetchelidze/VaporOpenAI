import AsyncSemaphore
import Dispatch
import Foundation
import Vapor

/// Namespace for OpenAI-related helpers (Responses, Embeddings, etc.).
public enum OpenAI {
    // MARK: - Shared transport
    private struct RetryPolicy {
        let maxAttempts: Int
        let baseDelaySeconds: Double
        let maxDelaySeconds: Double
    }

    static func endpoint(_ path: String) -> URI {
        let normalized = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return URI(string: "https://api.openai.com/v1/\(normalized)")
    }

    static func requireAPIKey() throws -> String {
        guard let apiKey = Environment.get("OPENAI_API_KEY"), !apiKey.isEmpty else {
            throw Abort(.internalServerError, reason: "OPENAI_API_KEY not configured")
        }
        return apiKey
    }

    static func addCommonHeaders(to headers: inout HTTPHeaders, apiKey: String) {
        headers.bearerAuthorization = .init(token: apiKey)
        if let org = Environment.get("OPENAI_ORG"), !org.isEmpty {
            headers.add(name: "OpenAI-Organization", value: org)
        }
        if let project = Environment.get("OPENAI_PROJECT"), !project.isEmpty {
            headers.add(name: "OpenAI-Project", value: project)
        }
        if let residency = Environment.get("OPENAI_COMPUTE_RESIDENCY"), !residency.isEmpty {
            headers.add(name: "OpenAI-Compute-Residency", value: residency)
        }
    }

    static func post(
        _ path: String,
        on app: Application,
        beforeSend: @Sendable (inout ClientRequest) throws -> Void = { _ in }
    ) async throws -> ClientResponse {
        let apiKey = try requireAPIKey()
        let policy = resolveRetryPolicy()
        return try await performWithRetry(policy: policy, app: app) {
            try await app.client.post(endpoint(path)) { req in
                addCommonHeaders(to: &req.headers, apiKey: apiKey)
                try beforeSend(&req)
            }
        }
    }

    static func get(
        _ path: String,
        on app: Application,
        beforeSend: @Sendable (inout ClientRequest) throws -> Void = { _ in }
    ) async throws -> ClientResponse {
        try await get(endpoint(path), on: app, beforeSend: beforeSend)
    }

    static func get(
        _ url: URI,
        on app: Application,
        beforeSend: @Sendable (inout ClientRequest) throws -> Void = { _ in }
    ) async throws -> ClientResponse {
        let apiKey = try requireAPIKey()
        let policy = resolveRetryPolicy()
        return try await performWithRetry(policy: policy, app: app) {
            try await app.client.get(url) { req in
                addCommonHeaders(to: &req.headers, apiKey: apiKey)
                try beforeSend(&req)
            }
        }
    }

    static func delete(
        _ path: String,
        on app: Application,
        beforeSend: @Sendable (inout ClientRequest) throws -> Void = { _ in }
    ) async throws -> ClientResponse {
        let apiKey = try requireAPIKey()
        let policy = resolveRetryPolicy()
        return try await performWithRetry(policy: policy, app: app) {
            try await app.client.delete(endpoint(path)) { req in
                addCommonHeaders(to: &req.headers, apiKey: apiKey)
                try beforeSend(&req)
            }
        }
    }

    static func requireOK(_ response: ClientResponse, context: String) throws {
        guard response.status == .ok else {
            let body = response.body.flatMap { String(buffer: $0) } ?? ""
            throw Abort(
                response.status,
                reason: "\(context): \(response.status.code) \(body)"
            )
        }
    }

    private static func resolveRetryPolicy() -> RetryPolicy {
        let maxAttempts = max(1, Int(Environment.get("OPENAI_RETRY_MAX_ATTEMPTS") ?? "") ?? 4)
        let baseDelaySeconds = max(
            0.1, Double(Environment.get("OPENAI_RETRY_BASE_DELAY_SECONDS") ?? "") ?? 0.8)
        let maxDelaySeconds = max(
            baseDelaySeconds,
            Double(Environment.get("OPENAI_RETRY_MAX_DELAY_SECONDS") ?? "") ?? 8.0
        )
        return .init(
            maxAttempts: maxAttempts,
            baseDelaySeconds: baseDelaySeconds,
            maxDelaySeconds: maxDelaySeconds
        )
    }

    private static func isRetryableStatus(_ status: HTTPResponseStatus) -> Bool {
        switch status.code {
        case 408, 425, 429, 500, 502, 503, 504:
            return true
        default:
            return false
        }
    }

    private static func performWithRetry(
        policy: RetryPolicy,
        app: Application,
        operation: @Sendable () async throws -> ClientResponse
    ) async throws -> ClientResponse {
        let attempts = max(1, policy.maxAttempts)
        for attempt in 1...attempts {
            do {
                let response = try await operation()
                if isRetryableStatus(response.status), attempt < attempts, !Task.isCancelled {
                    let delay = backoffDelay(
                        attempt: attempt,
                        baseDelaySeconds: policy.baseDelaySeconds,
                        maxDelaySeconds: policy.maxDelaySeconds
                    )
                    let delayMs = Int((delay * 1000).rounded())
                    app.logger.warning(
                        "OpenAI transport retry: status=\(response.status.code) attempt=\(attempt + 1)/\(attempts) after=\(delayMs)ms"
                    )
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                return response
            } catch {
                if attempt == attempts || Task.isCancelled {
                    throw error
                }
                let delay = backoffDelay(
                    attempt: attempt,
                    baseDelaySeconds: policy.baseDelaySeconds,
                    maxDelaySeconds: policy.maxDelaySeconds
                )
                let delayMs = Int((delay * 1000).rounded())
                app.logger.warning(
                    "OpenAI transport retry: attempt=\(attempt + 1)/\(attempts) after=\(delayMs)ms error=\(error)"
                )
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }

        throw Abort(.internalServerError, reason: "OpenAI transport retry loop exhausted")
    }

    private static func backoffDelay(
        attempt: Int,
        baseDelaySeconds: Double,
        maxDelaySeconds: Double
    ) -> Double {
        let multiplier = Double(1 << max(0, attempt - 1))
        let exponential = baseDelaySeconds * multiplier
        let capped = min(maxDelaySeconds, exponential)
        let jitter = Double.random(in: 0...(capped * 0.25))
        return capped + jitter
    }

    // MARK: - Shared limiting

    /// Global, per-process limiter for OpenAI Responses API calls.
    ///
    /// Applies a per-model in-flight cap and an optional per-model minimum
    /// interval between request starts (to smooth bursts across concurrent jobs).
    public actor ResponsesLimiter {
        struct Limits: Sendable {
            let maxInFlight: Int
            let minStartIntervalNs: UInt64
        }

        private var semaphores: [Responses.Model: AsyncSemaphore] = [:]
        private var nextAllowedStartNs: [Responses.Model: UInt64] = [:]

        func withPermit<T: Sendable>(
            model: Responses.Model,
            limits: Limits,
            operation: @Sendable () async throws -> T
        ) async throws -> T {
            let semaphore = semaphoreFor(model: model, maxInFlight: limits.maxInFlight)
            try await semaphore.wait()
            do {
                if limits.minStartIntervalNs > 0 {
                    let now = DispatchTime.now().uptimeNanoseconds
                    let allowed = nextAllowedStartNs[model] ?? 0
                    if now < allowed {
                        try await Task.sleep(nanoseconds: allowed - now)
                    }
                    let start = max(now, allowed)
                    nextAllowedStartNs[model] = start + limits.minStartIntervalNs
                }

                let result = try await operation()
                semaphore.signal()
                return result
            } catch {
                semaphore.signal()
                throw error
            }
        }

        private func semaphoreFor(model: Responses.Model, maxInFlight: Int) -> AsyncSemaphore {
            if let existing = semaphores[model] {
                return existing
            }
            let created = AsyncSemaphore(value: max(1, maxInFlight))
            semaphores[model] = created
            return created
        }
    }
}

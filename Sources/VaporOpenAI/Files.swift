import Foundation
import Vapor

extension OpenAI {
    public enum Files {
        public enum ObjectType: String, Codable, Sendable {
            case file
        }

        public enum ListObjectType: String, Codable, Sendable {
            case list
        }

        public enum Purpose: String, Codable, Sendable {
            case assistants
            case assistantsOutput = "assistants_output"
            case batch
            case batchOutput = "batch_output"
            case fineTune = "fine-tune"
            case fineTuneResults = "fine-tune-results"
            case vision
            case userData = "user_data"
            case evals
        }

        public enum Status: String, Codable, Sendable {
            case uploaded
            case processed
            case error
        }

        public enum Order: String, Codable, Sendable {
            case asc
            case desc
        }

        public struct ExpiresAfter: Content, Sendable {
            public enum Anchor: String, Codable, Sendable {
                case createdAt = "created_at"
            }

            public let anchor: Anchor
            public let seconds: Int

            public init(anchor: Anchor = .createdAt, seconds: Int) {
                self.anchor = anchor
                self.seconds = seconds
            }
        }

        public struct FileObject: Content, Sendable {
            public let id: String
            public let object: ObjectType
            public let bytes: Int?
            public let created_at: Int?
            public let expires_at: Int?
            public let filename: String?
            public let purpose: Purpose?
            public let status: Status?
            public let status_details: String?
        }

        public struct ListResponse: Content, Sendable {
            public let object: ListObjectType
            public let data: [FileObject]
            public let first_id: String?
            public let last_id: String?
            public let has_more: Bool?
        }

        public struct DeleteResponse: Content, Sendable {
            public let id: String
            public let object: ObjectType
            public let deleted: Bool
        }

        public struct ListQuery: Sendable {
            public var after: String?
            public var limit: Int?
            public var order: Order?
            public var purpose: Purpose?

            public init(
                after: String? = nil,
                limit: Int? = nil,
                order: Order? = nil,
                purpose: Purpose? = nil
            ) {
                self.after = after
                self.limit = limit
                self.order = order
                self.purpose = purpose
            }
        }

        public static func create(
            fileURL: URL,
            purpose: Purpose,
            expiresAfter: ExpiresAfter? = nil,
            mimeType: String? = nil,
            on app: Application
        ) async throws -> FileObject {
            let data = try Data(contentsOf: fileURL)
            return try await create(
                fileData: data,
                filename: fileURL.lastPathComponent,
                purpose: purpose,
                expiresAfter: expiresAfter,
                mimeType: mimeType,
                on: app
            )
        }

        public static func create(
            fileData: Data,
            filename: String,
            purpose: Purpose,
            expiresAfter: ExpiresAfter? = nil,
            mimeType: String? = nil,
            on app: Application
        ) async throws -> FileObject {
            guard !fileData.isEmpty else {
                throw Abort(.badRequest, reason: "OpenAI files create error: file data is empty")
            }

            let boundary = "Boundary-\(UUID().uuidString)"
            let body = try makeMultipartBody(
                boundary: boundary,
                fileData: fileData,
                filename: filename,
                purpose: purpose,
                expiresAfter: expiresAfter,
                mimeType: mimeType ?? "application/octet-stream"
            )

            let response = try await OpenAI.post("files", on: app) { req in
                req.headers.remove(name: .contentType)
                req.headers.add(
                    name: .contentType, value: "multipart/form-data; boundary=\(boundary)")
                req.body = .init(data: body)
            }

            try OpenAI.requireOK(response, context: "OpenAI files create error")

            return try response.content.decode(FileObject.self)
        }

        public static func list(
            query: ListQuery = .init(),
            on app: Application
        ) async throws -> ListResponse {
            let url = makeFilesURI(query: query)

            let response = try await OpenAI.get(url, on: app)
            try OpenAI.requireOK(response, context: "OpenAI files list error")

            return try response.content.decode(ListResponse.self)
        }

        public static func retrieve(
            fileID: String,
            on app: Application
        ) async throws -> FileObject {
            let response = try await OpenAI.get("files/\(fileID)", on: app)
            try OpenAI.requireOK(response, context: "OpenAI files retrieve error")

            return try response.content.decode(FileObject.self)
        }

        public static func delete(
            fileID: String,
            on app: Application
        ) async throws -> DeleteResponse {
            let response = try await OpenAI.delete("files/\(fileID)", on: app)
            try OpenAI.requireOK(response, context: "OpenAI files delete error")

            return try response.content.decode(DeleteResponse.self)
        }

        public static func content(
            fileID: String,
            on app: Application
        ) async throws -> Data {
            let response = try await OpenAI.get("files/\(fileID)/content", on: app)
            try OpenAI.requireOK(response, context: "OpenAI files content error")

            return response.body.flatMap { Data(buffer: $0) } ?? Data()
        }

        public static func contentString(
            fileID: String,
            encoding: String.Encoding = .utf8,
            on app: Application
        ) async throws -> String {
            let data = try await content(fileID: fileID, on: app)
            return String(data: data, encoding: encoding) ?? ""
        }

        private static func makeFilesURI(query: ListQuery) -> URI {
            var components = URLComponents(string: "https://api.openai.com/v1/files")!
            var items: [URLQueryItem] = []

            if let after = query.after, !after.isEmpty {
                items.append(.init(name: "after", value: after))
            }
            if let limit = query.limit {
                items.append(.init(name: "limit", value: String(limit)))
            }
            if let order = query.order {
                items.append(.init(name: "order", value: order.rawValue))
            }
            if let purpose = query.purpose {
                items.append(.init(name: "purpose", value: purpose.rawValue))
            }

            if !items.isEmpty {
                components.queryItems = items
            }

            return URI(string: components.string ?? "https://api.openai.com/v1/files")
        }

        private static func makeMultipartBody(
            boundary: String,
            fileData: Data,
            filename: String,
            purpose: Purpose,
            expiresAfter: ExpiresAfter?,
            mimeType: String
        ) throws -> Data {
            var data = Data()

            data.appendString("--\(boundary)\r\n")
            data.appendString("Content-Disposition: form-data; name=\"purpose\"\r\n\r\n")
            data.appendString("\(purpose.rawValue)\r\n")

            if let expiresAfter {
                let encoded = try JSONEncoder().encode(expiresAfter)
                let json = String(data: encoded, encoding: .utf8) ?? "{}"

                data.appendString("--\(boundary)\r\n")
                data.appendString("Content-Disposition: form-data; name=\"expires_after\"\r\n")
                data.appendString("Content-Type: application/json\r\n\r\n")
                data.appendString("\(json)\r\n")
            }

            data.appendString("--\(boundary)\r\n")
            data.appendString(
                "Content-Disposition: form-data; name=\"file\"; filename=\"\(escapeForMultipart(filename))\"\r\n"
            )
            data.appendString("Content-Type: \(mimeType)\r\n\r\n")
            data.append(fileData)
            data.appendString("\r\n")
            data.appendString("--\(boundary)--\r\n")

            return data
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

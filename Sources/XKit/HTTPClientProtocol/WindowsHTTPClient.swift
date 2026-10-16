#if os(Windows)
import CWindowsWebSocket
import Dispatch
import Foundation
import Dependencies
import HTTPTypes
import OpenAPIRuntime

extension HTTPClientDependencyKey: DependencyKey {
    public static let liveValue: HTTPClientProtocol = WindowsHTTPClient()
}

struct WindowsHTTPFailure: LocalizedError {
    let code: UInt32
    var errorDescription: String? { "Windows HTTP operation failed (WinHTTP \(code))." }
}

final class WindowsHTTPSession: @unchecked Sendable {
    let handle: OpaquePointer

    init() throws {
        let environment = ProcessInfo.processInfo.environment
        let proxy = environment["XTL_HTTP_PROXY"] ?? ""
        let disabled: Int32 = environment["XTL_DISABLE_TLS_VALIDATION"] == "1" ? 1 : 0
        var error: UInt32 = 0
        let handle = appleRootCertificates.joined(separator: "\n").withCString { roots in
            proxy.withCString(encodedAs: UTF16.self) {
                xtool_http_client_create(roots, $0, disabled, &error)
            }
        }
        guard let handle else { throw WindowsHTTPFailure(code: error) }
        self.handle = handle
    }

    deinit { xtool_http_client_destroy(handle) }
}

private struct WindowsHTTPClient: HTTPClientProtocol, ClientTransport {
    private let session = Result { try WindowsHTTPSession() }

    var asOpenAPITransport: any ClientTransport { self }

    func withEphemeralClient<T>(perform: (any HTTPClientProtocol) async throws -> T) async throws -> T {
        try await perform(WindowsHTTPClient())
    }

    func makeWebSocket(url: URL) async throws -> any WebSocketSession {
        try await WindowsWebSocket.open(url: url, session: session.get())
    }

    func send(
        _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let relative = URLComponents(string: request.path ?? "") else { throw URLError(.badURL) }
        components.percentEncodedPath += relative.percentEncodedPath
        components.percentEncodedQuery = relative.percentEncodedQuery
        components.fragment = nil
        guard let url = components.url else { throw URLError(.badURL) }
        var combined: [HTTPField.Name: String] = [:]
        for field in request.headerFields {
            let value = field.withUnsafeBytesOfValue { String(decoding: $0.map(UInt16.init), as: UTF16.self) }
            if let previous = combined[field.name] {
                combined[field.name] = previous + (field.name == .cookie ? "; " : ", ") + value
            } else {
                combined[field.name] = value
            }
        }
        let headers = combined.map { "\($0.key.rawName): \($0.value)\r\n" }.joined()
        let bytes: Data
        if let body {
            bytes = try await Data(collecting: body, upTo: Int(UInt32.max))
        } else {
            bytes = Data()
        }
        let operation = try WindowsHTTPRequest(session: session.get())
        let response = try await operation.open(url: url, method: request.method.rawValue, headers: headers, body: bytes)
        let length: HTTPBody.Length
        if response.headerFields[.contentEncoding] == nil,
           let value = response.headerFields[.contentLength], let count = Int64(value), count >= 0 {
            length = .known(count)
        } else {
            length = .unknown
        }
        return (response, HTTPBody(WindowsHTTPBody(operation: operation), length: length, iterationBehavior: .single))
    }
}

private final class WindowsHTTPRequest: @unchecked Sendable {
    let handle: OpaquePointer
    let session: WindowsHTTPSession

    init(session: WindowsHTTPSession) throws {
        guard let handle = xtool_ws_create() else { throw WindowsHTTPFailure(code: 8) }
        self.handle = handle
        self.session = session
    }

    deinit { xtool_ws_destroy(handle) }

    private func perform<Value: Sendable>(
        _ operation: @escaping @Sendable (WindowsHTTPRequest) throws -> Value
    ) async throws -> Value {
        try await withTaskCancellationHandler {
            do {
                let value: Value = try await withCheckedThrowingContinuation { continuation in
                    DispatchQueue.global(qos: .utility).async {
                        continuation.resume(with: Result { try operation(self) })
                    }
                }
                try Task.checkCancellation()
                return value
            } catch {
                xtool_ws_abort(self.handle)
                try Task.checkCancellation()
                throw error
            }
        } onCancel: {
            xtool_ws_abort(self.handle)
        }
    }

    func open(url: URL, method: String, headers: String, body: Data) async throws -> HTTPResponse {
        try await perform { operation in
            var error: UInt32 = 0
            var status: UInt32 = 0
            let success = url.absoluteString.withCString(encodedAs: UTF16.self) { url in
                method.withCString(encodedAs: UTF16.self) { method in
                    headers.withCString(encodedAs: UTF16.self) { headers in
                        body.withUnsafeBytes { bytes in
                            xtool_http_open(operation.handle, operation.session.handle, url, method, headers,
                                            bytes.baseAddress, UInt32(bytes.count), &error, &status)
                        }
                    }
                }
            }
            guard success != 0 else { throw WindowsHTTPFailure(code: error) }
            var raw: UnsafeMutablePointer<UInt16>?
            guard xtool_http_headers(operation.handle, &raw, &error) != 0, let raw else {
                throw WindowsHTTPFailure(code: error)
            }
            defer { xtool_ws_release_data(raw) }
            var response = HTTPResponse(status: .init(code: Int(status)))
            for line in String(decodingCString: raw, as: UTF16.self).components(separatedBy: "\r\n").dropFirst() {
                guard let colon = line.firstIndex(of: ":"), let name = HTTPField.Name(String(line[..<colon])) else { continue }
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                let bytes = value.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) }
                response.headerFields.append(HTTPField(name: name, value: bytes))
            }
            return response
        }
    }

    func read() async throws -> ArraySlice<UInt8>? {
        try await perform { operation in
            var bytes = [UInt8](repeating: 0, count: 65536)
            var count: UInt32 = 0
            var error: UInt32 = 0
            let success = bytes.withUnsafeMutableBytes {
                xtool_http_read(operation.handle, $0.baseAddress, UInt32($0.count), &count, &error)
            }
            guard success != 0 else { throw WindowsHTTPFailure(code: error) }
            return count == 0 ? nil : bytes.prefix(Int(count))
        }
    }
}

private struct WindowsHTTPBody: AsyncSequence, Sendable {
    typealias Element = ArraySlice<UInt8>
    let operation: WindowsHTTPRequest

    struct AsyncIterator: AsyncIteratorProtocol {
        let operation: WindowsHTTPRequest
        mutating func next() async throws -> Element? { try await operation.read() }
    }

    func makeAsyncIterator() -> AsyncIterator { AsyncIterator(operation: operation) }
}
#endif

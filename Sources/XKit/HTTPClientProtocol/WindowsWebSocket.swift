#if os(Windows)
import CWindowsWebSocket
import Foundation

/// WinHTTP uses Windows certificate validation and native WebSocket framing.
/// Operations are asynchronous in WinHTTP; cancellation closes their handles
/// after the issuing call returns, and native callbacks retain pending buffers.
final class WindowsWebSocket: WebSocketSession, @unchecked Sendable {
    private struct Failure: LocalizedError {
        let code: UInt32
        var httpStatus: UInt32 = 0
        var errorDescription: String? {
            let status = httpStatus == 0 ? "" : ", HTTP \(httpStatus)"
            return "Windows WebSocket operation failed (WinHTTP \(code)\(status))."
        }
    }

    private let handle: OpaquePointer

    private init() throws {
        guard let handle = xtool_ws_create() else { throw Failure(code: 8) }
        self.handle = handle
    }

    deinit { xtool_ws_destroy(handle) }

    static func open(url: URL) async throws -> WindowsWebSocket {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), ["ws", "wss"].contains(scheme) else {
            throw URLError(.unsupportedURL)
        }
        components.scheme = scheme == "wss" ? "https" : "http"
        components.fragment = nil
        guard let endpoint = components.url?.absoluteString else { throw URLError(.badURL) }
        let socket = try WindowsWebSocket()
        try await socket.perform { socket in
            var error: UInt32 = 0
            var status: UInt32 = 0
            let result = endpoint.withCString(encodedAs: UTF16.self) {
                xtool_ws_connect(socket.handle, $0, &error, &status)
            }
            guard result != 0 else { throw Failure(code: error, httpStatus: status) }
        }
        return socket
    }

    private func perform<Value: Sendable>(
        _ operation: @escaping @Sendable (WindowsWebSocket) throws -> Value
    ) async throws -> Value {
        try await withTaskCancellationHandler {
            do {
                let value = try await Task.detached { try operation(self) }.value
                try Task.checkCancellation()
                return value
            } catch {
                try Task.checkCancellation()
                throw error
            }
        } onCancel: {
            xtool_ws_abort(self.handle)
        }
    }

    func send(_ message: WebSocketMessage) async throws {
        let data: Data
        let text: Int32
        switch message {
        case .data(let value): data = value; text = 0
        case .text(let value): data = Data(value.utf8); text = 1
        }
        guard let size = UInt32(exactly: data.count) else { throw Failure(code: 8) }
        try await perform { socket in
            var error: UInt32 = 0
            let result = data.withUnsafeBytes {
                xtool_ws_send(socket.handle, $0.baseAddress, size, text, &error)
            }
            guard result != 0 else { throw Failure(code: error) }
        }
    }

    func receive() async throws -> WebSocketMessage {
        try await perform { socket in
            var bytes: UnsafeMutableRawPointer?
            var count: UInt32 = 0
            var text: Int32 = 0
            var status: UInt32 = 0
            var error: UInt32 = 0
            let result = xtool_ws_receive(socket.handle, &bytes, &count, &text, &status, &error)
            defer { xtool_ws_release_data(bytes) }
            guard result != 0 else { throw Failure(code: error) }
            guard status == 0 else { throw Failure(code: status) }
            let data: Data
            if count == 0 {
                data = Data()
            } else {
                guard let bytes else { throw Failure(code: 13) }
                data = Data(bytes: bytes, count: Int(count))
            }
            if text != 0 {
                guard let value = String(data: data, encoding: .utf8) else { throw Failure(code: 13) }
                return .text(value)
            }
            return .data(data)
        }
    }

    func close() {
        _ = Task.detached { xtool_ws_shutdown(self.handle) }
    }
}
#endif

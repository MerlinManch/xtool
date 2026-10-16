#if os(Windows)
import Foundation
import Testing
import XKit

@Test(.enabled(if: ProcessInfo.processInfo.environment["XTOOL_HTTP_TEST_URL"] != nil), .timeLimit(.minutes(1)))
func windowsHTTPAndWebSocketTransport() async throws {
    let base = try #require(ProcessInfo.processInfo.environment["XTOOL_HTTP_TEST_URL"])
    let client = HTTPClientDependencyKey.liveValue
    let result = try await client.makeRequest(HTTPRequest(url: #require(URL(string: base))))
    #expect(result.response.status.code == 200)
    #expect(String(decoding: result.body, as: UTF8.self) == "native HTTP ü")
    let url = try #require(URL(string: base.replacingOccurrences(of: "http://", with: "ws://") + "/ws"))
    let socket = try await client.makeWebSocket(url: url)
    defer { socket.close() }
    let text = "Windows WebSocket ü 🔌"
    try await socket.send(.text(text))
    switch try await socket.receive() {
    case .text(let response): #expect(response == text)
    case .data: Issue.record("Expected a text frame")
    }
    let data = Data((0..<512).map { UInt8($0 % 256) })
    try await socket.send(.data(data))
    switch try await socket.receive() {
    case .data(let response): #expect(response == data)
    case .text: Issue.record("Expected a binary frame")
    }
    try await socket.send(.text(""))
    switch try await socket.receive() {
    case .text(let response): #expect(response.isEmpty)
    case .data: Issue.record("Expected an empty text frame")
    }
    try await socket.send(.data(Data()))
    switch try await socket.receive() {
    case .data(let response): #expect(response.isEmpty)
    case .text: Issue.record("Expected an empty binary frame")
    }
    let pending = Task { try await socket.receive() }
    pending.cancel()
    do {
        _ = try await pending.value
        Issue.record("Expected a cancelled receive to throw")
    } catch {
        #expect(error is CancellationError)
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["XTOOL_HTTP_TEST_URL"] != nil), .timeLimit(.minutes(1)))
func windowsFailedWebSocketHandshakeReturnsError() async throws {
    let base = try #require(ProcessInfo.processInfo.environment["XTOOL_HTTP_TEST_URL"])
    let url = try #require(URL(string: base.replacingOccurrences(of: "http://", with: "ws://") + "/failure"))
    do {
        _ = try await HTTPClientDependencyKey.liveValue.makeWebSocket(url: url)
        Issue.record("Expected failed upgrade to throw")
    } catch {
        #expect(!(error is CancellationError))
    }
}
// No credentials are sent: any HTTP response verifies Foundation's TLS path to
// the actual Apple authentication/developer endpoints, including their roots.
@Test(.enabled(if: ProcessInfo.processInfo.environment["XTOOL_HTTP_TEST_URL"] != nil), .timeLimit(.minutes(1)))
func windowsAppleServiceTLS() async throws {
    for host in ["gsa.apple.com", "developerservices2.apple.com"] {
        let url = try #require(URL(string: "https://\(host)/"))
        let result = try await HTTPClientDependencyKey.liveValue.makeRequest(
            HTTPRequest(url: url), requireHTTPSuccess: false
        )
        #expect((100..<600).contains(result.response.status.code))
    }
}
#endif

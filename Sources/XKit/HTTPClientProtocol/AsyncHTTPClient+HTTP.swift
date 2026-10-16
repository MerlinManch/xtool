//
//  AsyncHTTPClient+HTTP.swift
//
//
//  Created by Kabir Oberai on 05/05/21.
//

#if os(Linux)
import Foundation
import AsyncHTTPClient
import NIO
import NIOHTTP1
import NIOSSL
import NIOFoundationCompat
import WebSocketKit
import OpenAPIRuntime
import OpenAPIAsyncHTTPClient
import Dependencies

extension HTTPClientDependencyKey: DependencyKey {
    public static let liveValue: HTTPClientProtocol = Client()
}

private struct Client: HTTPClientProtocol {
    private static var proxyConfiguration: HTTPClient.Configuration.Proxy? {
        // e.g. `XTL_HTTP_PROXY=localhost:8080`
        guard let value = ProcessInfo.processInfo.environment["XTL_HTTP_PROXY"],
              let separator = value.lastIndex(of: ":"),
              let port = Int(value[value.index(after: separator)...]) else {
            return nil
        }

        let host = String(value[..<separator])
        return host.isEmpty ? nil : .server(host: host, port: port)
    }

    private static let tlsConfiguration: TLSConfiguration = {
        let appleRoots = appleRootCertificates.map { pem in
            // if ssl cert parsing fails we're screwed so we might as well force try
            // swiftlint:disable:next force_try
            try! NIOSSLCertificate(bytes: Array(pem.utf8), format: .pem)
        }
        var tlsConfiguration: TLSConfiguration = .makeClientConfiguration()
        tlsConfiguration.additionalTrustRoots = [.certificates(appleRoots)]
        if ProcessInfo.processInfo.environment["XTL_DISABLE_TLS_VALIDATION"] == "1" {
            tlsConfiguration.certificateVerification = .none
        }
        return tlsConfiguration
    }()

    var client: HTTPClient

    init() {
        var config = HTTPClient.Configuration(
            tlsConfiguration: Self.tlsConfiguration,
            proxy: Self.proxyConfiguration,
            decompression: .enabled(limit: .none)
        )
        config.timeout.connect = .seconds(60)
        self.client = HTTPClient(configuration: config)
    }

    func makeWebSocket(url: URL) async throws -> any WebSocketSession {
        let (stream, continuation) = AsyncStream.makeStream(of: WebSocketSessionWrapper.self)
        async let value = stream.first(where: { _ in true })
        // must be after the `async let` so that we finish if connect throws
        defer { continuation.finish() }
        // we can't use the async overload because we need to immediately subscribe
        // to onText/onBinary in the same EventLoop tick that the WebSocket is created.
        // This is also why we create the SessionWrapper inside the closure.
        let future = WebSocket.connect(to: url, on: client.eventLoopGroup) {
            continuation.yield(WebSocketSessionWrapper(webSocket: $0))
        }
        try await future.get()
        guard let webSocket = await value else {
            throw Errors.connectFailed
        }
        return webSocket
    }

    private enum Errors: Error {
        case connectFailed
    }

    var asOpenAPITransport: any ClientTransport {
        AsyncHTTPClientTransport(configuration: .init(client: client))
    }

    func withEphemeralClient<T>(
        perform: (any HTTPClientProtocol) async throws -> T
    ) async throws -> T {
        let ephemeralClient = Client()
        let result = await Result { try await perform(ephemeralClient) }
        try? await ephemeralClient.client.shutdown()
        return try result.get()
    }
}

private final class WebSocketSessionWrapper: WebSocketSession {
    let webSocket: WebSocket
    let stream: AsyncStream<WebSocketMessage>
    private let finishStream: @Sendable () -> Void

    init(webSocket: WebSocket) {
        self.webSocket = webSocket

        let (stream, continuation) = AsyncStream<WebSocketMessage>.makeStream(bufferingPolicy: .unbounded)
        self.stream = stream
        self.finishStream = { continuation.finish() }
        webSocket.onText { _, text in
            continuation.yield(.text(text))
        }
        webSocket.onBinary { _, data in
            continuation.yield(.data(Data(data.readableBytesView)))
        }
    }

    deinit {
        close()
    }

    func close() {
        finishStream()
        Task { [webSocket] in try? await webSocket.close() }
    }

    func send(_ message: WebSocketMessage) async throws {
        switch message {
        case .text(let text):
            try await webSocket.send(text)
        case .data(let data):
            try await webSocket.send(.init(data))
        }
    }

    func receive() async throws -> WebSocketMessage {
        await stream.first(where: { _ in true }) ?? .data(Data())
    }
}

#endif

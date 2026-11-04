import MMServer
import MMTestSupport
import MMWire
import NIOCore
import Testing

@Suite("The hello deadline, apart from idle reaping")
struct HelloTimeoutIntegrationTests {
    @Test("a peer that never sends its hello is closed at the hello timeout, with idle reaping off")
    func silentPeerClosedAtHelloTimeout() async throws {
        try await withTempSocketPath { path in
            let server = makeTestServer(
                configuration: .init(
                    endpoint: .unix(path: path),
                    idleTimeout: nil,
                    helloTimeout: .milliseconds(200)
                )
            )
            try await withRunningServer(server) { _ in
                try await withWireSession(unixPath: path) { session in
                    _ = try await session.expectServerHello()
                    // No hello from us: the next read sees the close (the
                    // session's watchdog bounds the wait).
                    let next = try await session.nextFrame()
                    #expect(next == nil)
                }
            }
        }
    }

    @Test("a peer that completed its hello outlives the hello timeout while quiet")
    func establishedPeerSurvivesQuietly() async throws {
        try await withTempSocketPath { path in
            let server = makeTestServer(
                configuration: .init(
                    endpoint: .unix(path: path),
                    idleTimeout: nil,
                    helloTimeout: .milliseconds(100)
                )
            )
            try await withRunningServer(server) { _ in
                try await withWireSession(unixPath: path) { session in
                    _ = try await session.handshake()
                    try await Task.sleep(for: .milliseconds(400))
                    try await session.send(
                        request(
                            msgid: 1, method: "echo.run", entity: entity("box.item"),
                            EchoRequest(entity: entity("box.item"), value: 1)
                        )
                    )
                    let echoed = try await session.response(msgid: 1)
                    #expect(echoed.error == nil)
                }
            }
        }
    }
}

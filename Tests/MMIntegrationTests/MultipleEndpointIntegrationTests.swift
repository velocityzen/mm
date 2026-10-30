import MMServer
import MMTestSupport
import MMWire
import NIOConcurrencyHelpers
import NIOCore
import Testing

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

@Suite("One server listening on several endpoints")
struct MultipleEndpointIntegrationTests {
    @Test("a unix socket and a TCP port serve one router, each with its own peer identity")
    func unixAndTCPTogether() async throws {
        try await withTempSocketPath { path in
            let server = makeTestServer(
                configuration: .init(
                    endpoints: [.unix(path: path), .tcp(host: "127.0.0.1", port: 0)]
                )
            )
            try await withRunningServer(server) { addresses in
                // One bound address per endpoint, in declaration order.
                #expect(addresses.count == 2)
                #expect(addresses.first?.pathname == path)
                let port = try #require(addresses.last?.port)

                // The unix peer is this process: owner-class access.
                try await withWireSession(unixPath: path) { session in
                    _ = try await session.handshake()
                    try await session.send(
                        request(
                            msgid: 1, method: "echo.run", entity: entity("box.item"),
                            EchoRequest(entity: entity("box.item"), value: 1)
                        )
                    )
                    let echoed = try await session.response(msgid: 1)
                    #expect(echoed.error == nil)
                }
                // The TCP peer is anonymous: the same call is denied.
                try await withWireSession(host: "127.0.0.1", port: port) { session in
                    _ = try await session.handshake()
                    try await session.send(
                        request(
                            msgid: 1, method: "echo.run", entity: entity("box.item"),
                            EchoRequest(entity: entity("box.item"), value: 1)
                        )
                    )
                    let denied = try await session.response(msgid: 1)
                    #expect(denied.error?.code == 2)
                }
            }
        }
    }

    @Test("the connection cap counts connections on every endpoint")
    func connectionCapAcrossEndpoints() async throws {
        try await withTempSocketPath { path in
            let server = makeTestServer(
                configuration: .init(
                    endpoints: [.unix(path: path), .tcp(host: "127.0.0.1", port: 0)],
                    maxConnections: 1
                )
            )
            try await withRunningServer(server) { addresses in
                let port = try #require(addresses.last?.port)
                try await withWireSession(unixPath: path) { first in
                    _ = try await first.handshake()
                    // A full round trip proves this connection is admitted and counted.
                    try await first.send(
                        request(
                            msgid: 1, method: "echo.run", entity: entity("box.item"),
                            EchoRequest(entity: entity("box.item"), value: 1)
                        )
                    )
                    _ = try await first.response(msgid: 1)
                    // The unix connection holds the only slot, so a TCP
                    // connection is rejected: its stream ends (server-side
                    // close, not watchdog) without serving anything.
                    try await withWireSession(host: "127.0.0.1", port: port) { second in
                        #expect(await second.drainUntilClosedByServer())
                    }
                }
            }
        }
    }

    @Test("graceful shutdown stops every listener at once and removes every socket file")
    func gracefulShutdownCoversEveryEndpoint() async throws {
        try await withTempSocketPath { first in
            try await withTempSocketPath { second in
                let server = makeTestServer(
                    configuration: .init(endpoints: [.unix(path: first), .unix(path: second)])
                )
                let drain = Signal<Void>()
                async let served: Void = runServerUntilDrained(server, drain: drain)
                _ = try await withDeadline { try await server.bound.wait() }
                try await withWireSession(unixPath: second) { session in
                    _ = try await session.handshake()
                    try await session.send(
                        request(
                            msgid: 9, method: "slow.wait", entity: entity("box.item"),
                            TargetRequest(entity: entity("box.item"))
                        )
                    )
                    _ = try await withDeadline { try await server.slowStarted.wait() }
                    drain.fire(())
                    // While the request on the second endpoint is parked,
                    // both listeners refuse new connects, including the
                    // first, which has nothing in flight; both files stay
                    // until the drain ends.
                    try await expectConnectRefused(unixPath: first)
                    try await expectConnectRefused(unixPath: second)
                    #expect(statMode(path: first) != nil)
                    #expect(statMode(path: second) != nil)
                    server.slowGate.fire(())
                    let reply = try await session.response(msgid: 9)
                    #expect(reply.error == nil)
                }
                try await served
                #expect(statMode(path: first) == nil)
                #expect(statMode(path: second) == nil)
            }
        }
    }

    @Test("a failed bind closes the endpoints already bound and fails start")
    func failedBindClosesBoundEndpoints() async throws {
        try await withTempSocketPath { bound in
            try await withTempSocketPath { occupied in
                // A regular file at the second path: never a socket, never
                // unlinked, so its bind fails after the first one succeeded.
                let descriptor = open(occupied, O_CREAT | O_WRONLY, 0o600)
                try #require(descriptor >= 0)
                close(descriptor)
                let server = makeTestServer(
                    configuration: .init(endpoints: [.unix(path: bound), .unix(path: occupied)])
                )
                let bodyRan = NIOLockedValueBox(false)
                let result = try await withDeadline(seconds: 30) {
                    let withServer = server.service.start()
                    return await withServer { _ in
                        bodyRan.withLockedValue { $0 = true }
                        return .success(())
                    }
                }
                guard case .failure(.socketPathOccupied(let refused)) = result else {
                    Issue.record("expected socketPathOccupied, got \(result)")
                    return
                }
                #expect(refused == occupied)
                #expect(bodyRan.withLockedValue { $0 } == false)
                // The first endpoint's listener closed and its file is gone;
                // the file the server did not create is left alone.
                #expect(statMode(path: bound) == nil)
                #expect(statMode(path: occupied) != nil)
            }
        }
    }
}

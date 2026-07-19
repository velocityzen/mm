import Logging
import MMSchema
import MMServer
import MMTestSupport
import MMWire
import NIOCore
import ServiceLifecycle
import Testing

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

extension WireSession {
    /// Completes the hello exchange from the client side and returns the
    /// server's hello.
    func handshake(version: UInt8 = MMWireInfo.protocolVersion) async throws -> MMHello {
        let serverHello = try await self.expectServerHello()
        try await self.sendHello(version: version)
        return serverHello
    }

    /// Reads until the stream ends; `true` when the *server* closed it (a
    /// watchdog-forced close reports `false`, so a hung server cannot pass a
    /// closed-connection assertion).
    func drainUntilClosedByServer() async -> Bool {
        do {
            while try await self.nextFrame() != nil {}
        } catch {
            // A transport error also ends the stream; attribution below.
        }
        return !self.timedOut
    }
}

@Suite("MMServer integration over a real temp-dir unix socket")
struct ServerIntegrationTests {
    @Test("request/response round trip with entity-scoped payload")
    func roundTrip() async throws {
        try await withTempSocketPath { path in
            let server = makeTestServer(configuration: .init(endpoint: .unix(path: path)))
            try await withRunningServer(server) { _ in
                try await withWireSession(unixPath: path) { session in
                    let hello = try await session.expectServerHello()
                    #expect(hello.protocolVersion == MMWireInfo.protocolVersion)
                    #expect(hello.schemaFingerprint == server.service.router.fingerprint)
                    #expect(hello.capabilities == 0)
                    try await session.sendHello()
                    try await session.send(
                        request(
                            msgid: 1, method: "echo.run", entity: entity("box.item"),
                            EchoRequest(entity: entity("box.item"), value: 41)
                        )
                    )
                    let reply = try await session.response(msgid: 1)
                    #expect(reply.error == nil)
                    #expect(
                        try decodeResult(EchoResponse.self, from: reply.result)
                            == EchoResponse(value: 41)
                    )
                }
            }
        }
    }

    @Test("owner-class bits deny the owning peer even when other bits grant")
    func permissionDenied() async throws {
        try await withTempSocketPath { path in
            let server = makeTestServer(configuration: .init(endpoint: .unix(path: path)))
            try await withRunningServer(server) { _ in
                try await withWireSession(unixPath: path) { session in
                    _ = try await session.handshake()
                    // box.locked: owner == this process, mode 0o077 — the owner
                    // class matches first and its zero bits are final, even though
                    // group and other bits would grant.
                    try await session.send(
                        request(
                            msgid: 2, method: "echo.run", entity: entity("box.locked"),
                            EchoRequest(entity: entity("box.locked"), value: 1)
                        )
                    )
                    let reply = try await session.response(msgid: 2)
                    #expect(reply.error?.code == 2)
                    #expect(reply.error?.message == "permission denied")
                    #expect(reply.result == nil)
                }
            }
        }
    }

    @Test("missing x on an ancestor prefix denies traversal")
    func traversalDenied() async throws {
        try await withTempSocketPath { path in
            let server = makeTestServer(configuration: .init(endpoint: .unix(path: path)))
            try await withRunningServer(server) { _ in
                try await withWireSession(unixPath: path) { session in
                    _ = try await session.handshake()
                    // sealed.item is 0o777, but its ancestor sealed is 0o600 — no
                    // x anywhere on the prefix chain.
                    try await session.send(
                        request(
                            msgid: 3, method: "echo.run", entity: entity("sealed.item"),
                            EchoRequest(entity: entity("sealed.item"), value: 1)
                        )
                    )
                    let reply = try await session.response(msgid: 3)
                    #expect(reply.error?.code == 2)
                }
            }
        }
    }

    @Test("a root-targeted request to a normal method is denied over the wire")
    func rootTargetDeniedOverTheWire() async throws {
        try await withTempSocketPath { path in
            let server = makeTestServer(configuration: .init(endpoint: .unix(path: path)))
            try await withRunningServer(server) { _ in
                try await withWireSession(unixPath: path) { session in
                    _ = try await session.handshake()
                    // echo.run is not opted into root targets: an empty target
                    // must never reach the handler, even for a peer that could
                    // access concrete entities.
                    try await session.send(
                        request(
                            msgid: 4, method: "echo.run", entity: .root,
                            EchoRequest(entity: .root, value: 1)
                        )
                    )
                    let denied = try await session.response(msgid: 4)
                    #expect(denied.error?.code == 2)
                    // server.schema opts in: root-scoped discovery still works.
                    try await session.send(
                        request(msgid: 5, method: "server.schema", SchemaRequest())
                    )
                    let discovery = try await session.response(msgid: 5)
                    #expect(discovery.error == nil)
                }
            }
        }
    }

    @Test("unknown method is answered with error code 1 and the request's msgid")
    func unknownMethod() async throws {
        try await withTempSocketPath { path in
            let server = makeTestServer(configuration: .init(endpoint: .unix(path: path)))
            try await withRunningServer(server) { _ in
                try await withWireSession(unixPath: path) { session in
                    _ = try await session.handshake()
                    try await session.send(
                        request(
                            msgid: 77, method: "nope.method", entity: entity("box.item"),
                            TargetRequest(entity: entity("box.item"))
                        )
                    )
                    let reply = try await session.response(msgid: 77)
                    #expect(reply.error?.code == 1)
                    #expect(reply.error?.message == "unknown method")
                }
            }
        }
    }

    @Test("a frame claiming cap+1 bytes closes the connection")
    func oversizedFrameClosesConnection() async throws {
        try await withTempSocketPath { path in
            let server = makeTestServer(
                configuration: .init(endpoint: .unix(path: path), maxFrameLength: 256)
            )
            try await withRunningServer(server) { _ in
                try await withWireSession(unixPath: path) { session in
                    _ = try await session.handshake()
                    var oversized = ByteBuffer()
                    oversized.writeInteger(UInt32(257), endianness: .little)  // cap + 1; no body needed
                    try await session.sendRaw(oversized)
                    #expect(await session.drainUntilClosedByServer())
                }
            }
        }
    }

    @Test("an undecodable envelope after the hello drains in-flight work, then closes")
    func garbageEnvelopeClosesAfterDrain() async throws {
        try await withTempSocketPath { path in
            let server = makeTestServer(configuration: .init(endpoint: .unix(path: path)))
            try await withRunningServer(server) { _ in
                try await withWireSession(unixPath: path) { session in
                    _ = try await session.handshake()
                    try await session.send(
                        request(
                            msgid: 1, method: "slow.wait", entity: entity("box.item"),
                            TargetRequest(entity: entity("box.item"))
                        )
                    )
                    _ = try await withDeadline { try await server.slowStarted.wait() }
                    // A well-framed frame whose payload is not an envelope: a
                    // protocol violation — the server stops reading and closes
                    // the connection, but only after in-flight handlers drain
                    // and their responses flush.
                    var notAnEnvelope = ByteBuffer()
                    notAnEnvelope.writeMessagePackInt(7)
                    try await session.sendFramed(notAnEnvelope)
                    server.slowGate.fire(())
                    let reply = try await session.response(msgid: 1)
                    #expect(reply.error == nil)
                    #expect(try decodeResult(EchoResponse.self, from: reply.result).value == 99)
                    #expect(await session.drainUntilClosedByServer())
                }
            }
        }
    }

    @Test("connections over the cap are rejected deterministically")
    func connectionCap() async throws {
        try await withTempSocketPath { path in
            let server = makeTestServer(
                configuration: .init(endpoint: .unix(path: path), maxConnections: 2)
            )
            try await withRunningServer(server) { _ in
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
                    try await withWireSession(unixPath: path) { second in
                        _ = try await second.handshake()
                        try await second.send(
                            request(
                                msgid: 1, method: "echo.run", entity: entity("box.item"),
                                EchoRequest(entity: entity("box.item"), value: 2)
                            )
                        )
                        _ = try await second.response(msgid: 1)
                        // Accepts are FIFO: both admitted connections were counted
                        // before this one is processed, and neither has closed, so
                        // the third must be rejected — its stream ends (server-side
                        // close, not watchdog) without serving anything.
                        try await withWireSession(unixPath: path) { third in
                            #expect(await third.drainUntilClosedByServer())
                        }
                    }
                }
            }
        }
    }

    @Test("requests over the per-connection in-flight cap get tooManyInFlight")
    func tooManyInFlight() async throws {
        try await withTempSocketPath { path in
            let server = makeTestServer(
                configuration: .init(
                    endpoint: .unix(path: path), maxInFlightRequestsPerConnection: 1
                )
            )
            try await withRunningServer(server) { _ in
                try await withWireSession(unixPath: path) { session in
                    _ = try await session.handshake()
                    try await session.send(
                        request(
                            msgid: 1, method: "slow.wait", entity: entity("box.item"),
                            TargetRequest(entity: entity("box.item"))
                        )
                    )
                    _ = try await withDeadline { try await server.slowStarted.wait() }
                    try await session.send(
                        request(
                            msgid: 2, method: "echo.run", entity: entity("box.item"),
                            EchoRequest(entity: entity("box.item"), value: 5)
                        )
                    )
                    let rejected = try await session.response(msgid: 2)
                    #expect(rejected.error?.code == 4)
                    #expect(rejected.error?.message == "too many in-flight requests")
                    server.slowGate.fire(())
                    let completed = try await session.response(msgid: 1)
                    #expect(completed.error == nil)
                    #expect(
                        try decodeResult(EchoResponse.self, from: completed.result).value == 99
                    )
                }
            }
        }
    }

    @Test("concurrent handlers racing responses through one funnel keep the wire intact")
    func writerFunnelUnderConcurrency() async throws {
        try await withTempSocketPath { path in
            // Default configuration: in-flight cap 16 admits all 8 requests,
            // so 8 handler tasks race their responses through the one
            // ConnectionWriter. A regression that bypasses the funnel or splits
            // an envelope across writes interleaves partial frames — some frame
            // then fails envelope decode, or a msgid is answered twice/never,
            // and this test fails.
            let server = makeTestServer(configuration: .init(endpoint: .unix(path: path)))
            try await withRunningServer(server) { _ in
                try await withWireSession(unixPath: path) { session in
                    _ = try await session.handshake()
                    let count = TestServer.burstConcurrency
                    for msgid in 1...UInt32(count) {
                        try await session.send(
                            request(
                                msgid: msgid, method: "burst.wait", entity: entity("box.item"),
                                EchoRequest(entity: entity("box.item"), value: Int(msgid) * 10)
                            )
                        )
                    }
                    // All handlers have parked: every request is in flight
                    // concurrently before the gate opens and the responses
                    // race out through the funnel.
                    _ = try await withDeadline { try await server.burstStarted.wait() }
                    server.burstGate.fire(())
                    // Exactly N frames, every one a decodable response envelope.
                    var responseValuesByMsgid: [UInt32: Int] = [:]
                    for _ in 0..<count {
                        guard let envelope = try await session.nextEnvelope() else {
                            Issue.record("stream ended before all envelopes arrived")
                            return
                        }
                        switch envelope {
                            case .response(let msgid, let error, let result):
                                #expect(error == nil)
                                #expect(
                                    responseValuesByMsgid[msgid] == nil,
                                    "msgid \(msgid) answered more than once"
                                )
                                responseValuesByMsgid[msgid] =
                                    try decodeResult(EchoResponse.self, from: result).value
                            case .request, .credit, .item, .end, .stop, .cancel:
                                Issue.record("server sent an unexpected envelope: \(envelope)")
                                return
                        }
                    }
                    // Each msgid was answered exactly once with its own payload.
                    #expect(responseValuesByMsgid.count == count)
                    for msgid in 1...UInt32(count) {
                        #expect(responseValuesByMsgid[msgid] == Int(msgid) * 10)
                    }
                }
            }
        }
    }

    @Test("a fully silent connection is reaped at the idle timeout")
    func silentConnectionReaped() async throws {
        try await withTempSocketPath { path in
            let server = makeTestServer(
                configuration: .init(endpoint: .unix(path: path), idleTimeout: .milliseconds(200))
            )
            try await withRunningServer(server) { _ in
                try await withWireSession(unixPath: path) { session in
                    _ = try await session.expectServerHello()
                    // No client hello, no traffic in either direction: the
                    // idle reaper must close well inside the 15 s watchdog.
                    #expect(await session.drainUntilClosedByServer())
                }
            }
        }
    }

    @Test("server.schema filters by traversal rights of the unix peer")
    func rpcSchemaOverTheWire() async throws {
        try await withTempSocketPath { path in
            let server = makeTestServer(configuration: .init(endpoint: .unix(path: path)))
            try await withRunningServer(server) { _ in
                try await withWireSession(unixPath: path) { session in
                    _ = try await session.handshake()
                    try await session.send(
                        request(msgid: 6, method: "server.schema", SchemaRequest())
                    )
                    let reply = try await session.response(msgid: 6)
                    #expect(reply.error == nil)
                    let schema = try decodeResult(SchemaResponse.self, from: reply.result)
                    #expect(schema.fingerprint == server.service.router.fingerprint)
                    // Visible: prefixes whose chain grants us x — "box" (owner,
                    // 0o700; the S3 streaming fixtures live under it), "echo"
                    // (owner, 0o700) and "pub" (other, 0o001). Hidden: "hidden"
                    // (foreign owner, 0o700), plus every prefix with no ACL
                    // record at all (builtins, meta, slow, burst).
                    #expect(
                        schema.methods.map(\.name) == [
                            "box.follow", "box.followEndPark", "box.followFail",
                            "box.followGated", "box.followStoppable", "box.import",
                            "box.importGated", "box.importStop", "box.pipe",
                            "echo.run", "pub.ping",
                        ]
                    )
                }
            }
        }
    }

    @Test("anonymous TCP peer sees and reaches only other-class grants")
    func rpcSchemaAnonymousOverTCP() async throws {
        let server = makeTestServer(
            configuration: .init(endpoint: .tcp(host: "127.0.0.1", port: 0))
        )
        try await withRunningServer(server) { _ in
            let address = try await server.bound.wait()
            let port = try #require(address.port)
            try await withWireSession(host: "127.0.0.1", port: port) { session in
                _ = try await session.handshake()
                try await session.send(
                    request(msgid: 1, method: "server.schema", SchemaRequest())
                )
                let schemaReply = try await session.response(msgid: 1)
                let schema = try decodeResult(SchemaResponse.self, from: schemaReply.result)
                #expect(schema.methods.map(\.name) == ["pub.ping"])

                // The other-class grant is callable for the anonymous peer…
                try await session.send(
                    request(
                        msgid: 2, method: "pub.ping", entity: entity("pub.thing"),
                        TargetRequest(entity: entity("pub.thing"))
                    )
                )
                let ping = try await session.response(msgid: 2)
                #expect(ping.error == nil)
                #expect(try decodeResult(PingResponse.self, from: ping.result).ok)

                // …while owner-class-only entities deny it.
                try await session.send(
                    request(
                        msgid: 3, method: "echo.run", entity: entity("box.item"),
                        EchoRequest(entity: entity("box.item"), value: 1)
                    )
                )
                let denied = try await session.response(msgid: 3)
                #expect(denied.error?.code == 2)
            }
        }
    }

    @Test("server.entity returns the ten-byte ACL over the wire")
    func entityStatOverTheWire() async throws {
        try await withTempSocketPath { path in
            let server = makeTestServer(configuration: .init(endpoint: .unix(path: path)))
            try await withRunningServer(server) { _ in
                try await withWireSession(unixPath: path) { session in
                    _ = try await session.handshake()
                    try await session.send(
                        request(
                            msgid: 8, method: "server.entity", entity: entity("box"),
                            StatRequest())
                    )
                    let reply = try await session.response(msgid: 8)
                    #expect(reply.error == nil)
                    let status = try decodeResult(StatResponse.self, from: reply.result)
                    #expect(status.owner == UInt32(getuid()))
                    #expect(status.group == UInt32(getgid()))
                    #expect(status.mode == 0o700)
                }
            }
        }
    }

    @Test("graceful shutdown drains the in-flight request, then removes the socket file")
    func gracefulShutdownDrainsInFlight() async throws {
        try await withTempSocketPath { path in
            let server = makeTestServer(configuration: .init(endpoint: .unix(path: path)))
            try await withRunningServer(server) { group in
                try await withWireSession(unixPath: path) { session in
                    _ = try await session.handshake()
                    try await session.send(
                        request(
                            msgid: 9, method: "slow.wait", entity: entity("box.item"),
                            TargetRequest(entity: entity("box.item"))
                        )
                    )
                    _ = try await withDeadline { try await server.slowStarted.wait() }
                    await group.triggerGracefulShutdown()
                    // Drain window, observed directly: new connects are refused
                    // (listener closed) while the in-flight request is still
                    // parked and the socket file still exists — response
                    // delivery strictly precedes file removal.
                    try await expectConnectRefused(unixPath: path)
                    #expect(statMode(path: path) != nil)
                    server.slowGate.fire(())
                    let reply = try await session.response(msgid: 9)
                    #expect(reply.error == nil)
                    #expect(try decodeResult(EchoResponse.self, from: reply.result).value == 99)
                }
            }
            // withRunningServer joined: run() returned, and the socket file was
            // removed last.
            #expect(statMode(path: path) == nil)
        }
    }

    @Test("graceful shutdown releases a connection that never sent its hello")
    func gracefulShutdownReleasesPreHelloConnection() async throws {
        try await withTempSocketPath { path in
            // Idle timeout far beyond the watchdog and harness deadlines, so
            // only graceful shutdown itself can end the pre-hello connection —
            // the idle reaper cannot mask a shutdown-coverage bug.
            let server = makeTestServer(
                configuration: .init(endpoint: .unix(path: path), idleTimeout: .seconds(600))
            )
            try await withRunningServer(server) { group in
                try await withWireSession(unixPath: path) { session in
                    _ = try await session.expectServerHello()
                    // No client hello: the server connection task is parked in
                    // its pre-hello read when shutdown fires.
                    await group.triggerGracefulShutdown()
                    // The input-half close ends the hello read; the server
                    // closes the connection well inside the 15 s watchdog
                    // (a server that ignores pre-hello connections would stall
                    // until the watchdog and fail this assertion).
                    #expect(await session.drainUntilClosedByServer())
                }
            }
            #expect(statMode(path: path) == nil)
        }
    }

    @Test("a draining server never unlinks the successor's freshly bound socket")
    func shutdownUnlinkSparesSuccessorSocket() async throws {
        try await withTempSocketPath { path in
            let server = makeTestServer(configuration: .init(endpoint: .unix(path: path)))
            let group = ServiceGroup(
                configuration: .init(
                    services: [.init(service: server.service)],
                    logger: Logger(label: "mm.test.group")
                )
            )
            try await withThrowingTaskGroup(of: Void.self) { tasks in
                tasks.addTask {
                    try await withDeadline(seconds: 60) { try await group.run() }
                }
                _ = try await withDeadline { try await server.bound.wait() }
                try await withWireSession(unixPath: path) { session in
                    _ = try await session.handshake()
                    try await session.send(
                        request(
                            msgid: 1, method: "slow.wait", entity: entity("box.item"),
                            TargetRequest(entity: entity("box.item"))
                        )
                    )
                    _ = try await withDeadline { try await server.slowStarted.wait() }
                    await group.triggerGracefulShutdown()
                    try await expectConnectRefused(unixPath: path)
                    // The old server is now draining: listener closed, socket
                    // file present but refusing — exactly what a successor's
                    // liveness probe classifies as stale. The successor
                    // replaces the file and starts serving.
                    let successor = makeTestServer(
                        configuration: .init(endpoint: .unix(path: path)))
                    try await withRunningServer(successor) { _ in
                        // Complete the old server's drain while the successor
                        // is live, and join its run() — its shutdown unlink
                        // has then executed.
                        server.slowGate.fire(())
                        let reply = try await session.response(msgid: 1)
                        #expect(reply.error == nil)
                        #expect(await session.drainUntilClosedByServer())
                        try await tasks.waitForAll()
                        // The successor's socket must have survived the old
                        // server's unlink, and must still serve.
                        #expect(statMode(path: path) != nil)
                        try await withWireSession(unixPath: path) { fresh in
                            _ = try await fresh.handshake()
                        }
                    }
                }
            }
        }
    }

    @Test("socket file is a socket with the configured mode (default 0o660)")
    func socketFileMode() async throws {
        try await withTempSocketPath { defaultPath in
            let defaultServer = makeTestServer(
                configuration: .init(endpoint: .unix(path: defaultPath))
            )
            try await withRunningServer(defaultServer) { _ in
                let mode = try #require(statMode(path: defaultPath))
                #expect(mode & S_IFMT == S_IFSOCK)
                #expect(mode & 0o777 == 0o660)
            }
        }

        try await withTempSocketPath { customPath in
            let customServer = makeTestServer(
                configuration: .init(endpoint: .unix(path: customPath), unixSocketMode: 0o600)
            )
            try await withRunningServer(customServer) { _ in
                let mode = try #require(statMode(path: customPath))
                #expect(mode & 0o777 == 0o600)
            }
        }
    }

    @Test("a stale socket file from a dead server is replaced at startup")
    func staleSocketReplaced() async throws {
        try await withTempSocketPath { path in
            try createDeadSocketFile(path: path)
            #expect(statMode(path: path) != nil)
            let server = makeTestServer(configuration: .init(endpoint: .unix(path: path)))
            try await withRunningServer(server) { _ in
                try await withWireSession(unixPath: path) { session in
                    let hello = try await session.handshake()
                    #expect(hello.protocolVersion == MMWireInfo.protocolVersion)
                }
            }
        }
    }

    @Test("a live socket fails startup with a typed error instead of stealing the path")
    func liveSocketRefusedAtStartup() async throws {
        try await withTempSocketPath { path in
            let server = makeTestServer(configuration: .init(endpoint: .unix(path: path)))
            try await withRunningServer(server) { _ in
                let contender = makeTestServer(configuration: .init(endpoint: .unix(path: path)))
                await #expect(throws: MMServiceError.socketPathInUse(path: path)) {
                    try await contender.service.run()
                }
                // The refused contender must not have unlinked the live socket.
                #expect(statMode(path: path) != nil)
                try await withWireSession(unixPath: path) { session in
                    _ = try await session.handshake()  // still serving
                }
            }
        }
    }

    @Test("hello version negotiation is min-wins, observable via the connection context")
    func helloVersionNegotiation() async throws {
        try await withTempSocketPath { path in
            let server = makeTestServer(configuration: .init(endpoint: .unix(path: path)))
            try await withRunningServer(server) { _ in
                try await withWireSession(unixPath: path) { session in
                    _ = try await session.handshake(version: 0)
                    try await session.send(
                        request(
                            msgid: 1, method: "meta.version", entity: entity("box.item"),
                            TargetRequest(entity: entity("box.item"))
                        )
                    )
                    let reply = try await session.response(msgid: 1)
                    #expect(
                        try decodeResult(VersionResponse.self, from: reply.result).version == 0
                    )
                }
                try await withWireSession(unixPath: path) { session in
                    _ = try await session.handshake(version: 1)
                    try await session.send(
                        request(
                            msgid: 1, method: "meta.version", entity: entity("box.item"),
                            TargetRequest(entity: entity("box.item"))
                        )
                    )
                    let reply = try await session.response(msgid: 1)
                    #expect(
                        try decodeResult(VersionResponse.self, from: reply.result).version == 1
                    )
                }
            }
        }
    }

    @Test("a garbage first frame closes the connection")
    func garbageFirstFrameCloses() async throws {
        try await withTempSocketPath { path in
            let server = makeTestServer(configuration: .init(endpoint: .unix(path: path)))
            try await withRunningServer(server) { _ in
                try await withWireSession(unixPath: path) { session in
                    _ = try await session.expectServerHello()
                    var garbage = ByteBuffer()
                    garbage.writeBytes([UInt8](repeating: 0x58, count: 15))  // framed, but not a hello
                    try await session.sendFramed(garbage)
                    #expect(await session.drainUntilClosedByServer())
                }
            }
        }
    }
}

@Suite("Integration harness self-checks")
struct HarnessTests {
    /// The harness's "never hangs" guarantee rests on `Signal.wait()`
    /// observing cancellation: a handler parked on a gate must unblock when
    /// the deadline cancels the server task tree, even if the gate is never
    /// fired.
    @Test("Signal.wait observes task cancellation instead of parking forever")
    func signalWaitObservesCancellation() async throws {
        let gate = Signal<Void>()
        try await withDeadline(seconds: 10) {
            await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    do {
                        _ = try await gate.wait()
                        return false  // fired — not what this test arranges
                    } catch {
                        return true  // cancellation surfaced
                    }
                }
                group.cancelAll()
                let cancelled = await group.next() ?? false
                #expect(cancelled)
            }
        }
    }

    @Test("Signal still delivers the value to waiters and late arrivals")
    func signalDeliversValue() async throws {
        let signal = Signal<Int>()
        try await withDeadline(seconds: 10) {
            try await withThrowingTaskGroup(of: Int.self) { group in
                group.addTask { try await signal.wait() }
                signal.fire(7)
                let waited = try await group.next()
                #expect(waited == 7)
            }
            // Late arrival after the fire resolves immediately.
            #expect(try await signal.wait() == 7)
        }
    }
}

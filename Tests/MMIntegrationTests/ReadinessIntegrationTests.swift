import Logging
import MMSchema
import MMTestSupport
import NIOConcurrencyHelpers
import ServiceLifecycle
import Testing

@testable import MMClient
@testable import MMServer

/// A dependent service gated on the RPC server being bound: at its start it
/// records whether readiness had truly fired, proves the socket accepts by
/// making a real typed call, then parks until shutdown like any daemon
/// component.
private struct ProbeService: Service {
    let path: String
    let gateWasReady: NIOLockedValueBox<Bool?>
    let probed: Signal<Result<EchoResponse, MMCallError>>
    let readiness: ServiceReadiness

    func run() async throws {
        gateWasReady.withLockedValue { $0 = readiness.isReady }
        let connection = try await MMClientConnection.connect(
            to: .unix(path: path), logger: quietClientLogger()
        ).get()

        await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { _ = await connection.run() }
            let reply = await connection.call(
                TestMethods.echo, on: entity("box.item"),
                EchoRequest(entity: entity("box.item"), value: 42))
            probed.fire(reply)
            await connection.close()
            try? await group.waitForAll()
        }

        try await gracefulShutdown()
    }
}

@Suite("Readiness end to end: gated service starts only after the server binds")
struct ReadinessIntegrationTests {
    @Test("Ready(part) fires at bind; the gated dependent connects first try")
    func gatedDependentStartsAfterBind() async throws {
        try await withTempSocketPath { path in
            let rpcReady = ServiceReadiness()
            let gateWasReady = NIOLockedValueBox<Bool?>(nil)
            let probed = Signal<Result<EchoResponse, MMCallError>>()
            // The server is built declaratively with a Ready part; the probe
            // is gated on it — both live in ONE ServiceGroup, started
            // concurrently, ordered purely by the readiness signal.
            let server = MMService {
                Configuration(endpoint: .unix(path: path))
                ACLProvider(InMemoryACLProvider(fixtureACLs()))
                Log(label: "test.readiness.server", level: .warning)
                Ready(rpcReady)
                On(TestMethods.echo) { auth, request in
                    .success(EchoResponse(value: request.value))
                }
            }
            var logger = Logger(label: "test.readiness.group")
            logger.logLevel = .error
            let group = ServiceGroup(
                configuration: .init(
                    services: [
                        .init(service: server),
                        .init(
                            service: GatedService(
                                after: rpcReady,
                                run: ProbeService(
                                    path: path,
                                    gateWasReady: gateWasReady,
                                    probed: probed,
                                    readiness: rpcReady
                                ))),
                    ],
                    logger: logger
                )
            )
            try await withThrowingTaskGroup(of: Void.self) { tasks in
                tasks.addTask {
                    try await withDeadline(seconds: 30) { try await group.run() }
                }
                let reply = try await withDeadline { try await probed.wait() }
                #expect(reply == .success(EchoResponse(value: 42)))
                #expect(gateWasReady.withLockedValue { $0 } == true)
                await group.triggerGracefulShutdown()
                try await tasks.waitForAll()
            }
        }
    }
}

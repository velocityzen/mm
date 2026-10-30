import FPBracket
import FPService
import MMSchema
import MMTestSupport
import NIOConcurrencyHelpers
import NIOCore
import Testing

@testable import MMClient
@testable import MMServer

/// One failure channel for a host that composes the server with a client.
private enum HostFailure: Error {
    case server(MMServiceError)
    case client(MMClientError)
    case call(MMCallError)
}

/// The server and a client of it as one bracket: the client's acquire runs
/// only once the server's has returned, so it connects on the first try.
private func withServerAndClient(
    _ server: TestServer,
    path: String
) -> BracketAsync<([SocketAddress], MMClientConnection), HostFailure> {
    BracketAsyncDo<HostFailure>()
        .bind { server.service.start().mapError(HostFailure.server) }
        .bind { _ in
            MMClient {
                Configuration(endpoint: .unix(path: path))
                Log(quietClientLogger())
            }
            .mapError(HostFailure.client)
        }
}

/// A TCP server on an ephemeral port and a client of it: the client's
/// endpoint comes from the address the server's bracket yields.
private func withTCPServerAndClient(
    _ server: TestServer
) -> BracketAsync<([SocketAddress], MMClientConnection), HostFailure> {
    BracketAsyncDo<HostFailure>()
        .bind { server.service.start().mapError(HostFailure.server) }
        .bind { addresses in
            MMClient(
                endpoint: .tcp(host: "127.0.0.1", port: addresses.first?.port ?? 0),
                logger: quietClientLogger()
            )
            .mapError(HostFailure.client)
        }
}

@Suite("The server as a bracket, run by fp-swift-service")
struct LifecycleIntegrationTests {
    @Test("a client composed after the server connects first try; the body returning stops both")
    func composedClientStartsAfterBind() async throws {
        try await withTempSocketPath { path in
            let server = makeTestServer(configuration: .init(endpoint: .unix(path: path)))
            let reply = NIOLockedValueBox<Result<EchoResponse, MMCallError>?>(nil)
            let result = try await withDeadline(seconds: 30) {
                let withService = Service(withServerAndClient(server, path: path))
                return await withService { resources, _ in
                    let (_, client) = resources
                    let echoed = await client.call(
                        TestMethods.echo, on: entity("box.item"),
                        EchoRequest(entity: entity("box.item"), value: 42))
                    reply.withLockedValue { $0 = echoed }
                    return echoed.map { _ in () }.mapError(HostFailure.call)
                }
            }
            #expect(reply.withLockedValue { $0 } == .success(EchoResponse(value: 42)))
            switch result {
                case .success(let outcome):
                    #expect(outcome.shutdownReason == .serveReturned)
                    #expect(outcome.cancellationReason == nil)
                case .failure(let error):
                    Issue.record("the composed service must stop cleanly, got \(error)")
            }
            // Dispose ran in reverse: the client closed, then the server
            // drained and removed its socket file.
            #expect(statMode(path: path) == nil)
        }
    }

    @Test("a bind failure fails start: neither the body nor a dependent runs")
    func bindFailureSkipsDependents() async throws {
        // Longer than sockaddr_un.sun_path holds: the bind is refused.
        let path = "/tmp/" + String(repeating: "x", count: 200)
        let server = makeTestServer(configuration: .init(endpoint: .unix(path: path)))
        let bodyRan = NIOLockedValueBox(false)
        let result = try await withDeadline(seconds: 30) {
            let withService = Service(withServerAndClient(server, path: path))
            return await withService { _, _ in
                bodyRan.withLockedValue { $0 = true }
                return .success(())
            }
        }
        guard case .failure(.startFailed(.server(.invalidSocketPath(let refused)))) = result
        else {
            Issue.record("expected startFailed(server(invalidSocketPath)), got \(result)")
            return
        }
        #expect(refused == path)
        #expect(bodyRan.withLockedValue { $0 } == false)
    }

    @Test("the bracket yields the bound addresses: a client reaches an ephemeral TCP port")
    func ephemeralPortFromTheBracket() async throws {
        let server = makeTestServer(
            configuration: .init(endpoint: .tcp(host: "127.0.0.1", port: 0))
        )
        let reply = NIOLockedValueBox<Result<PingResponse, MMCallError>?>(nil)
        let result = try await withDeadline(seconds: 30) {
            let withService = Service(withTCPServerAndClient(server))
            return await withService { resources, _ in
                let (_, client) = resources
                let pinged = await client.call(
                    TestMethods.ping, on: entity("pub.thing"),
                    TargetRequest(entity: entity("pub.thing")))
                reply.withLockedValue { $0 = pinged }
                return pinged.map { _ in () }.mapError(HostFailure.call)
            }
        }
        #expect(reply.withLockedValue { $0 } == .success(PingResponse(ok: true)))
        if case .failure(let error) = result {
            Issue.record("the composed service must stop cleanly, got \(error)")
        }
    }

    @Test("the client builder's Schema reaches the hello")
    func clientBuilderSchemaReachesTheHello() async throws {
        try await withTempSocketPath { path in
            let server = makeTestServer(configuration: .init(endpoint: .unix(path: path)))
            let fingerprint = server.service.router.fingerprint
            try await withRunningServer(server) { _ in
                let expecting = MMClient {
                    Configuration(endpoint: .unix(path: path))
                    Schema(MMClientSchema(contracts: [], serverFingerprint: fingerprint))
                    Log(quietClientLogger())
                }
                let matched = await expecting { connection in
                    .success(connection.server.fingerprintMatched)
                }
                #expect(matched == .success(true))

                let unexpecting = MMClient {
                    Configuration(endpoint: .unix(path: path))
                    Log(quietClientLogger())
                }
                let unmatched = await unexpecting { connection in
                    .success(connection.server.fingerprintMatched)
                }
                #expect(unmatched == .success(nil))
            }
        }
    }
}

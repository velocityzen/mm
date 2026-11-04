import MMClient
import MMSchema
import MMServer
import MMWire
import Testing

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Android)
import Android
#endif

private struct WhoAmIRequest: Codable, Hashable, Sendable {
    var nonce: Int

    enum CodingKeys: Int, CodingKey {
        case nonce = 0
    }
}

private struct WhoAmIResponse: Codable, Hashable, Sendable {
    var nonce: Int
    var uid: UInt64
    var label: String?

    enum CodingKeys: Int, CodingKey {
        case nonce = 0
        case uid = 1
        case label = 2
    }
}

private let whoAmI = Method<WhoAmIRequest, WhoAmIResponse>(name: "adopt.whoami", access: .read)

private func makeSocketPair() throws -> (server: CInt, client: CInt) {
    var descriptors: [CInt] = [-1, -1]
    guard socketpair(AF_UNIX, streamSocketType, 0, &descriptors) == 0 else {
        throw POSIXFailure(code: errno)
    }
    return (descriptors[0], descriptors[1])
}

private struct POSIXFailure: Error {
    let code: CInt
}

private func inboxServer(endpoints: [MMEndpoint] = []) -> MMService {
    MMService {
        Configuration(endpoints: endpoints)
        ACLProvider {
            Entity("adopt", owner: getuid(), group: getgid(), mode: 0o700)
        }
        SocketInbox()
        On(whoAmI) { context, request in
            .success(
                WhoAmIResponse(
                    nonce: request.nonce,
                    uid: UInt64(context.peer.uid),
                    label: context.peer.label
                )
            )
        }
    }
}

/// Whether the peer end of a socketpair reads EOF: the server closed its end.
/// (Probing the closed descriptor number itself would race fd reuse by tests
/// running in parallel.)
private func peerSeesEOF(_ descriptor: CInt) -> Bool {
    var byte: UInt8 = 0
    return read(descriptor, &byte, 1) == 0
}

@Suite("Connected sockets adopted through MMServiceHandle.adopt")
struct SocketInboxIntegrationTests {
    @Test("an adopted socketpair end is served with the identity the host attested")
    func adoptedConnectionCarriesHostIdentity() async throws {
        let pair = try makeSocketPair()
        let target = try EntityName.parse("adopt").get()
        let identity = PeerIdentity(
            uid: getuid(),
            gid: getgid(),
            supplementaryGroups: [],
            pid: getpid(),
            label: "worker-1"
        )

        let service = inboxServer()
        let outcome = await service { server -> Result<Result<WhoAmIResponse, MMClientError>, MMServiceError> in
            guard case .success = await server.adopt(descriptor: pair.server, peer: identity) else {
                return .failure(.io(description: "adoption failed"))
            }
            let client = MMClient(endpoint: .fd(pair.client))
            let reply = await client { connection in
                await connection.call(whoAmI, on: target, WhoAmIRequest(nonce: 7))
                    .mapError { MMClientError.transport(description: "\($0)") }
            }
            return .success(reply)
        }

        let reply = try outcome.get().get()
        #expect(reply == WhoAmIResponse(nonce: 7, uid: UInt64(getuid()), label: "worker-1"))
    }

    @Test("the ACL still decides by the attested uid, not the label")
    func adoptedConnectionIsAuthorizedByUID() async throws {
        let pair = try makeSocketPair()
        let target = try EntityName.parse("adopt").get()
        // Not the owner: other bits (none) apply, whatever the label says.
        let stranger = PeerIdentity(
            uid: getuid() &+ 1,
            gid: getgid() &+ 1,
            supplementaryGroups: [],
            pid: 0,
            label: "owner"
        )

        let service = inboxServer()
        let outcome = await service { server in
            _ = await server.adopt(descriptor: pair.server, peer: stranger)
            let client = MMClient(endpoint: .fd(pair.client))
            let call = await client { connection in
                .success(await connection.call(whoAmI, on: target, WhoAmIRequest(nonce: 1)))
            }
            return .success(call)
        }

        let call = try outcome.get().get()
        guard case .failure(.denied) = call else {
            Issue.record("expected a denial, got \(call)")
            return
        }
    }

    @Test("adopting after the server stopped fails and closes the descriptor")
    func adoptionAfterStopFails() async throws {
        let pair = try makeSocketPair()
        defer { _ = close(pair.client) }
        let identity = PeerIdentity(uid: getuid(), gid: getgid(), supplementaryGroups: [], pid: 0)

        // The body hands the running server out; adopt once it has stopped.
        let service = inboxServer()
        let stopped = try await service { server in .success(server) }.get()
        guard case .failure = await stopped.adopt(descriptor: pair.server, peer: identity) else {
            Issue.record("expected the adoption to fail")
            return
        }
        #expect(peerSeesEOF(pair.client))
    }

    @Test("a service without SocketInbox() refuses adoption and closes the descriptor")
    func adoptionWithoutInboxFails() async throws {
        let pair = try makeSocketPair()
        defer { _ = close(pair.client) }
        let identity = PeerIdentity(uid: getuid(), gid: getgid(), supplementaryGroups: [], pid: 0)
        let service = MMService {
            Configuration(endpoint: .tcp(host: "127.0.0.1", port: 0))
            ACLProvider {
                Entity("adopt", owner: getuid(), group: getgid(), mode: 0o700)
            }
        }

        let adopted = try await service { server in
            .success(await server.adopt(descriptor: pair.server, peer: identity))
        }.get()
        guard case .failure = adopted else {
            Issue.record("expected the adoption to fail")
            return
        }
        #expect(peerSeesEOF(pair.client))
    }
}

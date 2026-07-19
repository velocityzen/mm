import MMSchema
import MMServer
import MMTestSupport
import MMWire
import Testing

/// The builtin handlers wired by `registerBuiltins`: server.schema's
/// traversal-filtered discovery and server.entity's ACL report.
@Suite("Builtins")
struct BuiltinTests {
    /// Five app methods + two builtins over this ACL world (owner 1000,
    /// group 500):
    ///
    /// - `journal`   r-x for everyone → traversable and discoverable by all
    /// - `journal.sub` missing ACL → journal.sub.* unreachable for everyone
    /// - `admin`     r-x owner+group only → hidden from `other`
    /// - `rpc`, `entity` r-x for everyone → builtins visible
    /// - `ghost` has no ACL → ghost.* excluded
    static let world: [EntityName: EntityACL] = [
        entity("journal"): acl(0o555),
        entity("admin"): acl(0o550),
        entity("server"): acl(0o555),
    ]

    private func makeRouter(acls: [EntityName: EntityACL] = Self.world) -> Router {
        Router(aclProvider: InMemoryACLProvider(acls), registerBuiltins: true) {
            Handle(Method<EchoRequest, EchoResponse>(name: "journal.append", access: .write)) {
                request, _ in .success(EchoResponse(value: request.value))
            }
            Handle(Method<EchoRequest, EchoResponse>(name: "journal.list", access: .read)) {
                request, _ in .success(EchoResponse(value: request.value))
            }
            Handle(Method<EchoRequest, EchoResponse>(name: "journal.sub.op", access: .read)) {
                request, _ in .success(EchoResponse(value: request.value))
            }
            Handle(Method<EchoRequest, EchoResponse>(name: "admin.wipe", access: .write)) {
                request, _ in .success(EchoResponse(value: request.value))
            }
            Handle(Method<EchoRequest, EchoResponse>(name: "ghost.walk", access: .read)) {
                request, _ in .success(EchoResponse(value: request.value))
            }
        }
    }

    private func discover(
        _ router: Router,
        peer: PeerIdentity,
        scope: EntityName = .root
    ) async throws -> SchemaResponse {
        let reply = await router.dispatch(
            envelope: request(method: "server.schema", entity: scope, SchemaRequest()),
            context: makeContext(peer: peer)
        )
        let buffer = try #require(resultBuffer(of: reply))
        return try MMPackDecoder().decode(SchemaResponse.self, from: buffer).get()
    }

    @Test("peer with x on a prefix sees its methods; peers without do not")
    func filteringByTraversalRights() async throws {
        let router = self.makeRouter()

        let otherView = try await self.discover(router, peer: Peers.other)
        #expect(
            otherView.methods.map(\.name)
                == ["journal.append", "journal.list", "server.entity", "server.schema"]
        )

        let ownerView = try await self.discover(router, peer: Peers.owner)
        #expect(
            ownerView.methods.map(\.name)
                == ["admin.wipe", "journal.append", "journal.list", "server.entity", "server.schema"]
        )
    }

    @Test("a missing ACL on any prefix step excludes the method for everyone")
    func missingPrefixACLExcludes() async throws {
        let router = self.makeRouter()
        // ghost.walk (no "ghost" ACL) and journal.sub.op (no "journal.sub"
        // ACL) are invisible even to the owner.
        let ownerView = try await self.discover(router, peer: Peers.owner)
        #expect(!ownerView.methods.map(\.name).contains("ghost.walk"))
        #expect(!ownerView.methods.map(\.name).contains("journal.sub.op"))
    }

    @Test("response fingerprint is the unfiltered router fingerprint")
    func fingerprintUnfiltered() async throws {
        let router = self.makeRouter()
        let otherView = try await self.discover(router, peer: Peers.other)
        let ownerView = try await self.discover(router, peer: Peers.owner)
        #expect(otherView.fingerprint == router.fingerprint)
        #expect(ownerView.fingerprint == router.fingerprint)
        #expect(otherView.methods.count < ownerView.methods.count)
    }

    @Test("the router fingerprint covers all signatures including builtins")
    func fingerprintCoversEverything() {
        let router = self.makeRouter()
        #expect(router.fingerprint == SchemaFingerprint.compute(router.signatures))
        #expect(
            router.signatures.map(\.name)
                == [
                    "admin.wipe", "ghost.walk", "journal.append",
                    "journal.list", "journal.sub.op", "server.entity", "server.schema",
                ]
        )
    }

    @Test("SchemaRequest.entity narrows discovery to the subtree")
    func subtreeNarrowing() async throws {
        let router = self.makeRouter()
        let view = try await self.discover(router, peer: Peers.owner, scope: entity("journal"))
        #expect(view.methods.map(\.name) == ["journal.append", "journal.list"])
        #expect(view.fingerprint == router.fingerprint)
    }

    @Test("server.entity returns the exact ACL fields when read is granted")
    func statGranted() async throws {
        let router = self.makeRouter()
        let reply = await router.dispatch(
            envelope: request(method: "server.entity", entity: entity("journal"), StatRequest()),
            context: makeContext(peer: Peers.other)
        )
        let buffer = try #require(resultBuffer(of: reply))
        #expect(
            MMPackDecoder().decode(StatResponse.self, from: buffer)
                == .success(StatResponse(owner: 1000, group: 500, mode: 0o555))
        )
    }

    @Test("server.entity denies without read on the target")
    func statDeniedWithoutRead() async {
        let router = self.makeRouter()
        // "admin" is r-x for owner+group only; `other` lacks read.
        let reply = await router.dispatch(
            envelope: request(method: "server.entity", entity: entity("admin"), StatRequest()),
            context: makeContext(peer: Peers.other)
        )
        #expect(errorCode(of: reply) == MMErrorCode.permissionDenied.code)
    }

    @Test("server.entity on an entity with no ACL record is permissionDenied")
    func statMissingACLDenied() async {
        let router = self.makeRouter()
        let reply = await router.dispatch(
            envelope: request(method: "server.entity", entity: entity("ghost"), StatRequest()),
            context: makeContext(peer: Peers.owner)
        )
        #expect(errorCode(of: reply) == MMErrorCode.permissionDenied.code)
    }

    @Test("server.entity on root is permissionDenied (root carries no ACL)")
    func statRootDenied() async {
        let router = self.makeRouter()
        let reply = await router.dispatch(
            envelope: request(method: "server.entity", entity: .root, StatRequest()),
            context: makeContext(peer: Peers.owner)
        )
        #expect(errorCode(of: reply) == MMErrorCode.permissionDenied.code)
    }

    @Test("server.schema scoped to a concrete entity requires read on it")
    func schemaScopedRequiresRead() async {
        let router = self.makeRouter()
        // "admin" grants nothing to `other`, so even asking about that
        // subtree is denied.
        let reply = await router.dispatch(
            envelope: request(method: "server.schema", entity: entity("admin"), SchemaRequest()),
            context: makeContext(peer: Peers.other)
        )
        #expect(errorCode(of: reply) == MMErrorCode.permissionDenied.code)
    }
}

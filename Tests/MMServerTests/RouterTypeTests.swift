import MMSchema
import MMServer
import MMWire
import Testing

// MARK: - Fixtures: namespaces carrying named-type tables

/// Request whose declared schema references `journal.Meta` — the field itself
/// is irrelevant to these tests; discovery never decodes it.
private struct TagRequest: Codable, Hashable, Sendable, SchemaDescribable {
    var entity: EntityName

    enum CodingKeys: Int, CodingKey {
        case entity = 0
    }

    static var schema: TypeSchema {
        .structure(fields: [
            .init(key: 0, name: "entity", type: .string),
            .init(key: 1, name: "meta", type: .reference("journal.Meta")),
        ])
    }
}

private struct ToolRequest: Codable, Hashable, Sendable, SchemaDescribable {
    var entity: EntityName

    enum CodingKeys: Int, CodingKey {
        case entity = 0
    }

    static var schema: TypeSchema {
        .structure(fields: [
            .init(key: 0, name: "entity", type: .string),
            .init(key: 1, name: "tool", type: .reference("admin.Tool")),
        ])
    }
}

/// `journal.Meta` references `common.Flavor` — the transitive step discovery
/// must chase through the definition table.
private enum TypedJournal: MethodNamespace {
    static let tag = Method<TagRequest, EchoResponse>(name: "journal.tag", access: .write)

    @SchemaBuilder static var all: [AnyMethod] {
        tag
    }

    static var types: [TypeDefinition] {
        [
            TypeDefinition(
                name: "journal.Meta",
                schema: .structure(fields: [
                    .init(key: 0, name: "author", type: .string),
                    .init(key: 1, name: "flavor", type: .reference("common.Flavor")),
                ])
            )
        ]
    }
}

private enum TypedAdmin: MethodNamespace {
    static let tool = Method<ToolRequest, EchoResponse>(name: "admin.tool", access: .write)

    @SchemaBuilder static var all: [AnyMethod] {
        tool
    }

    static var types: [TypeDefinition] {
        [
            TypeDefinition(
                name: "admin.Tool",
                schema: .structure(fields: [.init(key: 0, name: "label", type: .string)])
            )
        ]
    }
}

/// A types-only shared container, registered via the `sharedTypes` parameter
/// (the `Types(...)` builder element).
private enum SharedFlavors: TypeNamespace {
    static var types: [TypeDefinition] {
        [
            TypeDefinition(
                name: "common.Flavor",
                schema: .enumeration(cases: [.init(name: "sweet"), .init(name: "sour")])
            )
        ]
    }
}

/// An entity-scoped named type standing as a request payload.
private struct ScopedSetPayload: Codable, Hashable, Sendable, SchemaDescribable {
    var entity: EntityName
    var line: String

    enum CodingKeys: Int, CodingKey {
        case entity = 0
        case line = 1
    }

    static var schema: TypeSchema { .reference("journal.SetPayload") }
}

private enum ScopedJournal: MethodNamespace {
    static let set = Method<ScopedSetPayload, EchoResponse>(name: "journal.set", access: .write)

    @SchemaBuilder static var all: [AnyMethod] {
        Self.set
    }

    static var types: [TypeDefinition] {
        [
            TypeDefinition(
                name: "journal.SetPayload",
                schema: .structure(fields: [
                    .init(key: 0, name: "entity", type: .string),
                    .init(key: 1, name: "line", type: .string),
                ])
            )
        ]
    }
}

@Suite("Router: nominal type tables")
struct RouterTypeTests {
    /// journal is world-traversable; admin is owner/group only.
    static let world: [EntityName: EntityACL] = [
        entity("journal"): acl(0o555),
        entity("admin"): acl(0o550),
        entity("rpc"): acl(0o555),
        entity("entity"): acl(0o555),
    ]

    private func makeRouter() -> Router {
        Router(
            namespaces: [TypedJournal.self, TypedAdmin.self],
            sharedTypes: [SharedFlavors.self],
            aclProvider: InMemoryACLProvider(Self.world),
            registerBuiltins: true
        ) {
            Handle(TypedJournal.tag) { request, _ in .success(EchoResponse(value: 1)) }
            Handle(TypedAdmin.tool) { request, _ in .success(EchoResponse(value: 2)) }
        }
    }

    private func discover(
        _ router: Router,
        peer: PeerIdentity
    ) async throws -> SchemaResponse {
        let reply = await router.dispatch(
            envelope: request(method: "rpc.schema", entity: .root, SchemaRequest()),
            context: makeContext(peer: peer)
        )
        let buffer = try #require(resultBuffer(of: reply))
        return try MMPackDecoder().decode(SchemaResponse.self, from: buffer).get()
    }

    @Test("the router aggregates namespace and shared tables, sorted by name")
    func aggregation() {
        let router = self.makeRouter()
        #expect(router.types.map(\.name) == ["admin.Tool", "common.Flavor", "journal.Meta"])
    }

    @Test("the fingerprint covers signatures AND the type table")
    func fingerprintCoversTypes() {
        let router = self.makeRouter()
        #expect(
            router.fingerprint
                == SchemaFingerprint.compute(router.signatures, types: router.types)
        )
        #expect(router.fingerprint != SchemaFingerprint.compute(router.signatures))
    }

    @Test("discovery serves the types transitively reachable from visible methods")
    func reachabilityFiltering() async throws {
        let router = self.makeRouter()
        // `other` cannot traverse admin: sees journal.tag → journal.Meta and,
        // through its definition, common.Flavor — but never admin.Tool.
        let otherView = try await self.discover(router, peer: Peers.other)
        #expect(otherView.methods.map(\.name).contains("journal.tag"))
        #expect(!otherView.methods.map(\.name).contains("admin.tool"))
        #expect(otherView.types.map(\.name) == ["common.Flavor", "journal.Meta"])
        // The owner reaches both subtrees and sees all three definitions.
        let ownerView = try await self.discover(router, peer: Peers.owner)
        #expect(ownerView.types.map(\.name) == ["admin.Tool", "common.Flavor", "journal.Meta"])
    }

    @Test("a reference no registered table defines fails the boot")
    func unresolvedReferenceExits() async {
        await #expect(processExitsWith: .failure) {
            _ = Router(
                namespaces: [TypedJournal.self],  // journal.Meta → common.Flavor undefined
                aclProvider: InMemoryACLProvider(Self.world),
                registerBuiltins: false
            ) {
                Handle(TypedJournal.tag) { request, _ in .success(EchoResponse(value: 1)) }
            }
        }
    }

    @Test("a request that IS an entity-scoped type resolves and dispatches")
    func entityScopedRequestDispatches() async throws {
        let router = Router(
            namespaces: [ScopedJournal.self],
            aclProvider: InMemoryACLProvider([entity("journal"): acl(0o750)]),
            registerBuiltins: false
        ) {
            Handle(ScopedJournal.set) { request, _ in
                .success(EchoResponse(value: request.line.count))
            }
        }
        // The entity rides at key 0 of the referenced type; authorization and
        // full decode both work through it.
        let reply = await router.dispatch(
            envelope: request(
                method: "journal.set", entity: entity("journal"),
                ScopedSetPayload(entity: entity("journal"), line: "abc")),
            context: makeContext(peer: Peers.owner)
        )
        let buffer = try #require(resultBuffer(of: reply))
        #expect(
            MMPackDecoder().decode(EchoResponse.self, from: buffer)
                == .success(EchoResponse(value: 3))
        )
    }

    @Test("duplicate type definitions fail the boot")
    func duplicateDefinitionExits() async {
        await #expect(processExitsWith: .failure) {
            _ = Router(
                namespaces: [TypedJournal.self, TypedAdmin.self],
                sharedTypes: [SharedFlavors.self, SharedFlavors.self],
                aclProvider: InMemoryACLProvider(Self.world),
                registerBuiltins: false
            ) {
                Handle(TypedJournal.tag) { request, _ in .success(EchoResponse(value: 1)) }
                Handle(TypedAdmin.tool) { request, _ in .success(EchoResponse(value: 2)) }
            }
        }
    }
}

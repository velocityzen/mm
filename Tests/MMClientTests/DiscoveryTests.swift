import MMSchema
import MMTestSupport
import MMWire
import NIOCore
import Testing

@testable import MMClient

// MARK: - Signature fixtures

private func signature(
    _ name: String,
    access: AccessMode = .read,
    request: TypeSchema = .structure(fields: [
        .init(key: 0, name: "entity", type: .string)
    ]),
    response: TypeSchema = .structure(fields: [
        .init(key: 0, name: "ok", type: .bool)
    ]),
    requestStream: TypeSchema? = nil,
    responseStream: TypeSchema? = nil
) -> MethodSignature {
    MethodSignature(
        name: name, access: access, request: request, response: response,
        requestStream: requestStream, responseStream: responseStream)
}

private func remote(
    _ methods: [MethodSignature],
    types: [TypeDefinition] = []
) -> SchemaResponse {
    SchemaResponse(fingerprint: 0, methods: methods, types: types)
}

@Suite("Schema discovery: wire behavior")
struct DiscoveryWireTests {
    @Test("discoverSchema is a plain server.schema call scoped to root, and decodes the response")
    func discoverSchemaOverTheWire() async throws {
        _ = try await withRunningConnection { client in
            let served = [signature("box.get"), signature("box.watch", access: .write)]
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    let reply = await client.connection.discoverSchema()
                    #expect(reply == .success(SchemaResponse(fingerprint: 0xFEED, methods: served)))
                }
                let (msgid, method, params) = try await client.readRequestFrame()
                #expect(method == "server.schema")
                // SchemaRequest is an empty payload — the scope is the
                // envelope entity (root here).
                #expect(allBytes(params) == [0x80])
                try await client.channel.writeInbound(
                    responseFrame(
                        msgid: msgid,
                        result: SchemaResponse(fingerprint: 0xFEED, methods: served)
                    )
                )
                try await group.waitForAll()
            }
        }
    }

    @Test("a denied server.schema surfaces as a normal call error")
    func discoveryDenied() async throws {
        _ = try await withRunningConnection { client in
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    let reply = await client.connection.discoverSchema()
                    #expect(reply == .failure(.denied))
                }
                let (msgid, _, _) = try await client.readRequestFrame()
                try await client.channel.writeInbound(
                    errorFrame(
                        msgid: msgid,
                        MMError(code: 2, message: "permission denied", payload: nil)
                    )
                )
                try await group.waitForAll()
            }
        }
    }
}

@Suite("SchemaDifference: degradation decision input")
struct SchemaDifferenceTests {
    @Test("a local method the server does not serve is missing")
    func missing() {
        let local = signature("box.get")
        let diff = SchemaDifference(local: [local], remote: remote([]))
        #expect(diff.missingMethods == [local])
        #expect(diff.accessChanged.isEmpty)
        #expect(diff.signatureChanged.isEmpty)
        #expect(diff.remoteOnly.isEmpty)
        #expect(!diff.isEmpty)
    }

    @Test("a server method this build has no descriptor for is remoteOnly")
    func remoteOnly() {
        let served = signature("box.new")
        let diff = SchemaDifference(local: [], remote: remote([served]))
        #expect(diff.remoteOnly == [served])
        #expect(diff.missingMethods.isEmpty)
        #expect(!diff.isEmpty)
    }

    @Test("same name, different access mode lands in accessChanged")
    func accessChanged() {
        let local = signature("box.get", access: .read)
        let served = signature("box.get", access: .write)
        let diff = SchemaDifference(local: [local], remote: remote([served]))
        #expect(diff.accessChanged == [SchemaDifference.Change(local: local, remote: served)])
        #expect(diff.signatureChanged.isEmpty)
        #expect(diff.missingMethods.isEmpty)
    }

    @Test("same name, different request or response schema lands in signatureChanged")
    func signatureChanged() {
        let local = signature("box.get", request: .structure(fields: [
            .init(key: 0, name: "entity", type: .string)
        ]))
        let served = signature("box.get", request: .structure(fields: [
            .init(key: 0, name: "entity", type: .string),
            .init(key: 1, name: "depth", type: .optional(.int)),
        ]))
        let diff = SchemaDifference(local: [local], remote: remote([served]))
        #expect(diff.signatureChanged == [SchemaDifference.Change(local: local, remote: served)])
        #expect(diff.accessChanged.isEmpty)
    }

    @Test("a diverged response-stream element lands in signatureChanged")
    func responseStreamChanged() {
        let local = signature(
            "box.follow",
            responseStream: .structure(fields: [.init(key: 0, name: "line", type: .string)]))
        let served = signature(
            "box.follow",
            responseStream: .structure(fields: [.init(key: 0, name: "line", type: .int)]))
        let diff = SchemaDifference(local: [local], remote: remote([served]))
        #expect(diff.signatureChanged == [SchemaDifference.Change(local: local, remote: served)])
        #expect(diff.accessChanged.isEmpty)
    }

    @Test("gaining or losing a stream direction lands in signatureChanged")
    func streamDirectionAppeared() {
        let unary = signature("box.follow")
        let streaming = signature(
            "box.follow",
            responseStream: .structure(fields: [.init(key: 0, name: "line", type: .string)]))
        // Local unary, server now streams: a contract move this build cannot see.
        let diff = SchemaDifference(local: [unary], remote: remote([streaming]))
        #expect(diff.signatureChanged == [SchemaDifference.Change(local: unary, remote: streaming)])
    }

    @Test("a request-stream-only divergence is caught (request/response identical)")
    func requestStreamChanged() {
        let local = signature(
            "box.import",
            requestStream: .structure(fields: [.init(key: 0, name: "line", type: .string)]))
        let served = signature(
            "box.import",
            requestStream: .structure(fields: [.init(key: 0, name: "note", type: .string)]))
        let diff = SchemaDifference(local: [local], remote: remote([served]))
        #expect(diff.signatureChanged.count == 1)
    }

    @Test("a method whose access AND shape both moved appears in both buckets")
    func bothChanged() {
        let local = signature("box.get", access: .read, response: .structure(fields: [
            .init(key: 0, name: "ok", type: .bool)
        ]))
        let served = signature("box.get", access: .all, response: .structure(fields: [
            .init(key: 0, name: "ok", type: .string)
        ]))
        let diff = SchemaDifference(local: [local], remote: remote([served]))
        #expect(diff.accessChanged.count == 1)
        #expect(diff.signatureChanged.count == 1)
    }

    @Test("identical sets diff to empty")
    func identical() {
        let shared = [signature("a.get"), signature("b.get", access: .write)]
        let diff = SchemaDifference(local: shared, remote: remote(shared))
        #expect(diff.isEmpty)
    }

    @Test("an empty difference describes itself as in sync")
    func descriptionInSync() {
        let shared = [signature("a.get")]
        let diff = SchemaDifference(local: shared, remote: remote(shared))
        #expect("\(diff)" == "in sync")
    }

    @Test("the description lists only non-empty buckets, names sorted")
    func descriptionBuckets() {
        // z.gone/a.gone missing; box.get access changed; extra.new remote-only.
        let local = [
            signature("z.gone"),
            signature("a.gone"),
            signature("box.get", access: .read),
        ]
        let served = [
            signature("box.get", access: .write),
            signature("extra.new"),
        ]
        let diff = SchemaDifference(local: local, remote: remote(served))
        #expect(
            "\(diff)"
                == "missing: a.gone, z.gone; access changed: box.get; server only: extra.new"
        )
    }

    @Test("a single-bucket difference describes without stray separators")
    func descriptionSingleBucket() {
        let diff = SchemaDifference(local: [signature("a.gone")], remote: remote([]))
        #expect("\(diff)" == "missing: a.gone")
    }

    @Test("all four buckets sort by method name")
    func sorted() {
        let localOnly = [signature("z.gone"), signature("a.gone")]
        let served = [signature("z.new"), signature("a.new")]
        let diff = SchemaDifference(local: localOnly, remote: remote(served))
        #expect(diff.missingMethods.map(\.name) == ["a.gone", "z.gone"])
        #expect(diff.remoteOnly.map(\.name) == ["a.new", "z.new"])
    }

    // MARK: Named types

    private static let priority = TypeDefinition(
        name: "box.Priority",
        schema: .enumeration(cases: [.init(name: "low"), .init(name: "high")])
    )

    @Test("type tables diff into missing, changed, and server-only buckets")
    func typeBuckets() {
        let localTypes = [
            Self.priority,
            TypeDefinition(name: "box.Gone", schema: .structure(fields: [])),
        ]
        let servedTypes = [
            TypeDefinition(
                name: "box.Priority",
                schema: .enumeration(cases: [.init(name: "low"), .init(name: "urgent")])
            ),
            TypeDefinition(name: "box.New", schema: .structure(fields: [])),
        ]
        let diff = SchemaDifference(
            local: [], localTypes: localTypes, remote: remote([], types: servedTypes))
        #expect(diff.missingTypes.map(\.name) == ["box.Gone"])
        #expect(diff.typeChanged.map(\.local.name) == ["box.Priority"])
        #expect(diff.remoteOnlyTypes.map(\.name) == ["box.New"])
        #expect(!diff.isEmpty)
        #expect(
            "\(diff)"
                == "missing types: box.Gone; types changed: box.Priority; server-only types: box.New"
        )
    }

    @Test("description-only differences are never drift")
    func docInsensitive() {
        var documentedMethod = signature("box.get")
        documentedMethod.description = "does the thing"
        documentedMethod.request = .structure(fields: [
            .init(key: 0, name: "entity", type: .string, description: "the target")
        ])
        var documentedType = Self.priority
        documentedType.description = "how urgent"
        documentedType.schema = .enumeration(cases: [
            .init(name: "low", description: "whenever"),
            .init(name: "high"),
        ])
        let diff = SchemaDifference(
            local: [signature("box.get")],
            localTypes: [Self.priority],
            remote: remote([documentedMethod], types: [documentedType])
        )
        #expect(diff.isEmpty)
    }

    @Test("a declared contract diffs directly, types included")
    func declarationInit() {
        let contract = Schema("box") {
            Enum("Priority") {
                Case("low")
                Case("high")
            }
            Call("get") {
                Access { .read }
                Request { Field("priority", "Priority") }
                Response { Field("ok", .bool) }
            }
        }
        let served = SchemaResponse(
            fingerprint: 0,
            methods: contract.signatures,
            types: contract.types
        )
        #expect(SchemaDifference(local: contract, remote: served).isEmpty)
        // Same contract served without its type table: the type goes missing.
        let typeless = SchemaResponse(fingerprint: 0, methods: contract.signatures)
        let diff = SchemaDifference(local: contract, remote: typeless)
        #expect(diff.missingTypes.map(\.name) == ["box.Priority"])
        #expect("\(diff)" == "missing types: box.Priority")
    }
}

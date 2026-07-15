import Foundation
import Testing

@testable import MMSchema

@Suite("Method and Builtins")
struct MethodTests {
    /// The probed shape of MethodSignature itself (used inside SchemaResponse):
    /// method-level keys in the single digits, the request block in the 10s,
    /// the response block in the 20s, every slot immediately followed by its
    /// doc slot.
    static let signatureSchema: TypeSchema = .structure(fields: [
        .init(key: 0, name: "name", type: .string),
        .init(key: 1, name: "access", type: .uint),
        .init(key: 2, name: "description", type: .optional(.string)),
        .init(key: 10, name: "request", type: TypeSchema.schema),
        .init(key: 11, name: "requestDescription", type: .optional(.string)),
        .init(key: 12, name: "requestStream", type: .optional(TypeSchema.schema)),
        .init(key: 13, name: "requestStreamDescription", type: .optional(.string)),
        .init(key: 20, name: "response", type: TypeSchema.schema),
        .init(key: 21, name: "responseDescription", type: .optional(.string)),
        .init(key: 22, name: "responseStream", type: .optional(TypeSchema.schema)),
        .init(key: 23, name: "responseStreamDescription", type: .optional(.string)),
    ])

    /// Builtin requests are empty payloads: the target/scope is the call's
    /// envelope entity.
    static let emptyRequest: TypeSchema = .structure(fields: [])

    /// The probed shape of TypeDefinition (used inside SchemaResponse).
    static let typeDefinitionSchema: TypeSchema = .structure(fields: [
        .init(key: 0, name: "name", type: .string),
        .init(key: 1, name: "schema", type: TypeSchema.schema),
        .init(key: 2, name: "description", type: .optional(.string)),
    ])

    @Test("rpc.schema signature")
    func schemaSignature() {
        #expect(
            Builtins.schema.signature()
                == .success(
                    MethodSignature(
                        name: "rpc.schema",
                        access: .read,
                        request: Self.emptyRequest,
                        response: .structure(fields: [
                            .init(key: 0, name: "fingerprint", type: .uint),
                            .init(key: 1, name: "methods", type: .array(Self.signatureSchema)),
                            // The hand-written decoder reads `types` with
                            // decodeIfPresent (absent on pre-types wires), so
                            // the probe records it optional.
                            .init(
                                key: 2, name: "types",
                                type: .optional(.array(Self.typeDefinitionSchema))),
                        ])
                    )
                )
        )
    }

    @Test("entity.stat signature")
    func statSignature() {
        #expect(
            Builtins.stat.signature()
                == .success(
                    MethodSignature(
                        name: "entity.stat",
                        access: .read,
                        request: Self.emptyRequest,
                        response: .structure(fields: [
                            .init(key: 0, name: "owner", type: .uint),
                            .init(key: 1, name: "group", type: .uint),
                            .init(key: 2, name: "mode", type: .uint),
                        ])
                    )
                )
        )
    }

    @Test("AnyMethod erases without losing name, access, or signature")
    func anyMethodErasure() {
        let erased = AnyMethod(Builtins.schema)
        #expect(erased.name == "rpc.schema")
        #expect(erased.access == .read)
        #expect(erased.signature() == Builtins.schema.signature())
    }

    @Test("Builtins namespace lists all methods")
    func namespaceAll() {
        #expect(Builtins.all.map(\.name) == ["rpc.schema", "entity.stat"])
        #expect(Builtins.all.map(\.access) == [.read, .read])
        for method in Builtins.all {
            #expect(throws: Never.self) {
                _ = try method.signature().get()
            }
        }
    }

    @Test("builtin request/response types round trip with root entity")
    func builtinCodableRoundTrip() throws {
        let request = SchemaRequest()
        let decoded = try JSONDecoder().decode(
            SchemaRequest.self, from: JSONEncoder().encode(request))
        #expect(decoded == request)

        let response = SchemaResponse(
            fingerprint: 0x0123_4567_89ab_cdef,
            methods: [FingerprintTests.statSignature]
        )
        let decodedResponse = try JSONDecoder().decode(
            SchemaResponse.self, from: JSONEncoder().encode(response))
        #expect(decodedResponse == response)

        let stat = StatResponse(owner: 1000, group: 100, mode: 0o750)
        let decodedStat = try JSONDecoder().decode(
            StatResponse.self, from: JSONEncoder().encode(stat))
        #expect(decodedStat == stat)
    }
}

import Foundation
import MMSchema
import Testing

/// A `#schema` expansion with a tagged union and raw bytes: field-less cases,
/// cases with required, optional, pinned and nested fields, and a union as a
/// whole response stream element.
private enum Post: MethodNamespace {
    #schema("post") {
        Enum("Priority") {
            Case("low")
            Case("high")
        }
        Union("Cursor", description: "Where a feed starts") {
            Case("beginning")
            Case("seq", description: "Just after a sequence number") {
                Field("seq", .uint)
            }
            Case("live")
        }
        Union("Event") {
            Case("note") {
                Field("text", .string, description: "The note")
                Field(4, "priority", .optional(.reference("Priority")))
            }
            Case("blob") {
                Field("data", .bytes)
                Field("meta") {
                    Field("mime", .string)
                }
            }
            Case("cleared")
        }
        Call("follow") {
            Access { .read }
            Request {
                Field("from", "Cursor")
                Field("token", .optional(.bytes))
            }
            ResponseStream(.reference("Event"))
            Response {
                Field("delivered", .uint)
            }
        }
    }
}

@Suite("Unions and bytes in the schema")
struct UnionSchemaTests {
    @Test("the generated types honor the re-emitted contract (macro fidelity)")
    func contractFidelity() throws {
        let breaks = try Post.contract.verify(against: Post.self).get()
        for line in breaks { Issue.record("mismatch: \(line)") }
        #expect(breaks == [])
    }

    @Test("a union definition keys each case's fields from 0, pins honored")
    func definition() {
        let cursor = Post.types.first { $0.name == "post.Cursor" }
        #expect(cursor?.description == "Where a feed starts")
        #expect(
            cursor?.schema
                == .union(cases: [
                    .init(name: "beginning"),
                    .init(
                        name: "seq",
                        fields: [.init(key: 0, name: "seq", type: .uint)],
                        description: "Just after a sequence number"
                    ),
                    .init(name: "live"),
                ])
        )
        let event = Post.types.first { $0.name == "post.Event" }
        #expect(
            event?.schema.strippingDescriptions
                == .union(cases: [
                    .init(
                        name: "note",
                        fields: [
                            .init(key: 0, name: "text", type: .string),
                            .init(
                                key: 4,
                                name: "priority",
                                type: .optional(.reference("post.Priority"))
                            ),
                        ]
                    ),
                    .init(
                        name: "blob",
                        fields: [
                            .init(key: 0, name: "data", type: .bytes),
                            .init(
                                key: 1,
                                name: "meta",
                                type: .structure(fields: [
                                    .init(key: 0, name: "mime", type: .string)
                                ])
                            ),
                        ]
                    ),
                    .init(name: "cleared"),
                ])
        )
        // A union's decoder is data-dependent, so it gets no behavior probe.
        #expect(Set(Post.probedTypes.keys) == ["post.Priority"])
    }

    @Test("the runtime DSL declares the same union the macro does")
    func runtimeDeclaration() {
        let declared = Schema("post") {
            Enum("Priority") {
                Case("low")
                Case("high")
            }
            Union("Cursor", description: "Where a feed starts") {
                Case("beginning")
                Case("seq", description: "Just after a sequence number") {
                    Field("seq", .uint)
                }
                Case("live")
            }
            Call("tail") {
                Access { .read }
                Request { Field("from", "Cursor") }
            }
        }
        #expect(
            declared.types.first { $0.name == "post.Cursor" }
                == Post.types.first { $0.name == "post.Cursor" }
        )
        guard case .structure(let fields) = declared.signatures[0].request else {
            Issue.record("request is not a structure")
            return
        }
        #expect(fields[0].type == .reference("post.Cursor"))
    }

    @Test("generated union cases carry their fields as labeled values")
    func generatedCases() {
        let cursor = Post.Cursor.seq(seq: 7)
        #expect(cursor != .live)
        #expect(TypeSchema.of(Post.Cursor.self) == .success(.reference("post.Cursor")))
        #expect(TypeSchema.of(MMBytes.self) == .success(.bytes))
        let request = Post.FollowRequest(from: .beginning, token: MMBytes([1, 2, 3]))
        #expect(request.token?.bytes == [1, 2, 3])
    }

    @Test("a union's JSON mirrors its wire map: case, then fields")
    func json() throws {
        let note = Post.Event.note(text: "hi", priority: .high)
        let encoded = String(decoding: try sortedJSON(note), as: UTF8.self)
        #expect(encoded == #"{"case":"note","fields":{"priority":"high","text":"hi"}}"#)
        #expect(try JSONDecoder().decode(Post.Event.self, from: Data(encoded.utf8)) == note)

        let cleared = String(decoding: try sortedJSON(Post.Event.cleared), as: UTF8.self)
        #expect(cleared == #"{"case":"cleared"}"#)

        let blob = Post.Event.blob(data: [0, 255], meta: .init(mime: "a/b"))
        let blobJSON = String(decoding: try sortedJSON(blob), as: UTF8.self)
        #expect(blobJSON == #"{"case":"blob","fields":{"data":"AP8=","meta":{"mime":"a\/b"}}}"#)
        #expect(try JSONDecoder().decode(Post.Event.self, from: Data(blobJSON.utf8)) == blob)

        let future = try JSONDecoder().decode(
            Post.Event.self,
            from: Data(#"{"case":"edited","fields":{"x":1}}"#.utf8)
        )
        #expect(future == .unknown)
    }

    @Test("a union schema round-trips through its own wire encoding, descriptions included")
    func schemaCoding() throws {
        let schema = Post.types.first { $0.name == "post.Event" }!.schema
        let data = try JSONEncoder().encode(schema)
        #expect(try JSONDecoder().decode(TypeSchema.self, from: data) == schema)
    }

    @Test("the fingerprint sees case names and fields, never descriptions")
    func fingerprint() {
        func fingerprint(_ union: TypeSchema) -> UInt64 {
            SchemaFingerprint.compute([], types: [TypeDefinition(name: "x.U", schema: union)])
        }
        let base = TypeSchema.union(cases: [
            .init(name: "a"), .init(name: "b", fields: [.init(key: 0, name: "n", type: .int)]),
        ])
        let described = TypeSchema.union(cases: [
            .init(name: "a", description: "doc"),
            .init(name: "b", fields: [.init(key: 0, name: "n", type: .int, description: "doc")]),
        ])
        let renamed = TypeSchema.union(cases: [
            .init(name: "a"), .init(name: "c", fields: [.init(key: 0, name: "n", type: .int)]),
        ])
        let retyped = TypeSchema.union(cases: [
            .init(name: "a"), .init(name: "b", fields: [.init(key: 0, name: "n", type: .uint)]),
        ])
        // The same fields as a structure must not collide with the union.
        let asStructure = TypeSchema.structure(fields: [.init(key: 0, name: "n", type: .int)])
        #expect(fingerprint(base) == fingerprint(described))
        #expect(fingerprint(base) != fingerprint(renamed))
        #expect(fingerprint(base) != fingerprint(retyped))
        #expect(fingerprint(base) != fingerprint(asStructure))
    }

    @Test("dynamic values: a union takes case and fields, and canonicalizes")
    func dynamicValues() {
        let resolver = TypeResolver(Post.types)
        let event = TypeSchema.reference("post.Event")
        func validated(_ value: SchemaValue) -> Result<SchemaValue, SchemaValueError> {
            value.validated(against: event, resolver: resolver)
        }
        #expect(
            validated(
                .object([
                    .init("fields", .object([.init("text", .string("hi"))])),
                    .init("case", .string("note")),
                ])
            )
                == .success(
                    .object([
                        .init("case", .string("note")),
                        .init("fields", .object([.init("text", .string("hi"))])),
                    ])
                )
        )
        #expect(
            validated(.object([.init("case", .string("cleared"))]))
                == .success(.object([.init("case", .string("cleared"))]))
        )
        #expect(
            validated(.object([.init("case", .string("cleared")), .init("fields", .object([]))]))
                == .success(.object([.init("case", .string("cleared"))]))
        )
        func problem(_ value: SchemaValue) -> String? {
            guard case .failure(let error) = validated(value) else { return nil }
            return error.description
        }
        #expect(
            problem(.object([.init("case", .string("edited"))]))
                == "case: 'edited' is not one of: note, blob, cleared"
        )
        #expect(
            problem(.object([.init("case", .string("note"))]))
                == "fields.text: missing required field"
        )
        #expect(
            problem(.object([.init("case", .string("cleared")), .init("extra", .null)]))
                == "extra: unknown member (a union value has only 'case' and 'fields')"
        )
        #expect(
            validated(
                .object([
                    .init("case", .string("blob")),
                    .init(
                        "fields",
                        .object([
                            .init("data", .string("AP8=")),
                            .init("meta", .object([.init("mime", .string("a/b"))])),
                        ])
                    ),
                ])
            )
                == .success(
                    .object([
                        .init("case", .string("blob")),
                        .init(
                            "fields",
                            .object([
                                .init("data", .bytes([0, 255])),
                                .init("meta", .object([.init("mime", .string("a/b"))])),
                            ])
                        ),
                    ])
                )
        )
    }

    @Test("MMBytes: base64 through Codable, raw bytes as a collection")
    func bytes() throws {
        let bytes: MMBytes = [0, 1, 254, 255]
        #expect(Array(bytes) == [0, 1, 254, 255])
        #expect(bytes.description == "AAH+/w==")
        let encoded = try JSONEncoder().encode([bytes])
        #expect(String(decoding: encoded, as: UTF8.self) == #"["AAH+\/w=="]"#)
        #expect(try JSONDecoder().decode([MMBytes].self, from: encoded) == [bytes])
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode([MMBytes].self, from: Data(#"["not base64!"]"#.utf8))
        }
    }
}

private func sortedJSON(_ value: some Encodable) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
}

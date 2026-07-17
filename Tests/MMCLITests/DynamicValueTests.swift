import ArgumentParser
import MMSchema
import MMWire
import NIOCore
import Testing

@testable import MMCLI

// MARK: - Fixtures: a hand-written "generated" type and its discovered schema

/// Shaped exactly like a macro-generated wire type: Int-raw `CodingKeys`
/// whose `stringValue`s are the case names. Dynamic requests must produce
/// bytes this type decodes; dynamic responses must decode bytes this type
/// encodes.
private struct LedgerEntry: Codable, Equatable, Sendable {
    var line: String
    var kind: LedgerKind
    var meta: LedgerMeta?
    var count: Int?
    var tags: [Int64]
    var flags: UInt64
    var ratio: Double
    var active: Bool

    enum CodingKeys: Int, CodingKey {
        case line = 0
        case kind = 1
        case meta = 2
        case count = 3
        case tags = 4
        case flags = 5
        case ratio = 6
        case active = 7
    }
}

private enum LedgerKind: String, Codable, Equatable, Sendable {
    case credit
    case debit
}

private struct LedgerMeta: Codable, Equatable, Sendable {
    var note: String

    enum CodingKeys: Int, CodingKey {
        case note = 0
    }
}

/// The discovery-shaped schema for ``LedgerEntry``: enum and nested
/// structure behind **references**, exercising resolution through the
/// definitions table.
private let ledgerDefinitions = [
    TypeDefinition(
        name: "ledger.Kind",
        schema: .enumeration(cases: [
            TypeSchema.EnumCase(name: "credit"),
            TypeSchema.EnumCase(name: "debit"),
        ])
    ),
    TypeDefinition(
        name: "ledger.Meta",
        schema: .structure(fields: [
            TypeSchema.Field(key: 0, name: "note", type: .string)
        ])
    ),
]

private let ledgerEntrySchema = TypeSchema.structure(fields: [
    TypeSchema.Field(key: 0, name: "line", type: .string),
    TypeSchema.Field(key: 1, name: "kind", type: .reference("ledger.Kind")),
    TypeSchema.Field(key: 2, name: "meta", type: .optional(.reference("ledger.Meta"))),
    TypeSchema.Field(key: 3, name: "count", type: .optional(.int)),
    TypeSchema.Field(key: 4, name: "tags", type: .array(.int)),
    TypeSchema.Field(key: 5, name: "flags", type: .uint),
    TypeSchema.Field(key: 6, name: "ratio", type: .double),
    TypeSchema.Field(key: 7, name: "active", type: .bool),
])

private func makeLedgerRequest(_ jsonText: String) throws -> MMCLIDynamicRequest {
    try MMCLIDynamicRequest(
        schema: ledgerEntrySchema,
        definitions: ledgerDefinitions,
        json: MMCLIDynamicTree.parse(jsonText: jsonText)
    )
}

private func expectValidationFailure(
    _ jsonText: String,
    messageContains fragment: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        _ = try makeLedgerRequest(jsonText)
        Issue.record(
            "expected a ValidationError containing '\(fragment)'",
            sourceLocation: sourceLocation)
    } catch let error as ValidationError {
        #expect(
            error.message.contains(fragment),
            "got: \(error.message)",
            sourceLocation: sourceLocation)
    } catch {
        Issue.record("expected ValidationError, got \(error)", sourceLocation: sourceLocation)
    }
}

/// `JSONSerialization` yields object members in arbitrary order (documented
/// on ``MMCLIDynamicTree/parse(jsonText:)``), so parse assertions compare
/// with members sorted by name.
private func normalized(_ tree: MMCLIDynamicTree) -> MMCLIDynamicTree {
    switch tree {
        case .array(let items):
            return .array(items.map(normalized))
        case .object(let members):
            return .object(
                members
                    .map { SchemaValue.Member($0.name, normalized($0.value)) }
                    .sorted { $0.name < $1.name })
        default:
            return tree
    }
}

// MARK: - Request encoding

@Suite("MMCLIDynamicRequest: schema-driven encoding")
struct DynamicRequestTests {
    @Test("a full request round-trips into the generated-shaped fixture")
    func fullRoundTrip() throws {
        let request = try makeLedgerRequest(
            #"{"line":"hi","kind":"credit","meta":{"note":"n"},"count":4,"tags":[1,2],"flags":9,"ratio":1.5,"active":true}"#
        )
        let bytes = try MMPackEncoder().encode(request).get()
        let decoded = try MMPackDecoder().decode(LedgerEntry.self, from: bytes).get()
        #expect(
            decoded
                == LedgerEntry(
                    line: "hi", kind: .credit, meta: LedgerMeta(note: "n"), count: 4,
                    tags: [1, 2], flags: 9, ratio: 1.5, active: true))
    }

    @Test("absent and null optionals are skipped on the wire")
    func optionalsSkipped() throws {
        // `meta` absent, `count` explicitly null: both must encode nothing.
        let request = try makeLedgerRequest(
            #"{"line":"x","kind":"debit","count":null,"tags":[],"flags":0,"ratio":0.5,"active":false}"#
        )
        let bytes = try MMPackEncoder().encode(request).get()
        let decoded = try MMPackDecoder().decode(LedgerEntry.self, from: bytes).get()
        #expect(decoded.meta == nil)
        #expect(decoded.count == nil)
        #expect(decoded.kind == .debit)
    }

    @Test("integer fields accept either JSON integer kind when the value fits")
    func integerKindCoercion() throws {
        // flags (uint schema) from a plain JSON integer; ratio (double
        // schema) from an integer literal.
        let request = try makeLedgerRequest(
            #"{"line":"x","kind":"credit","tags":[3],"flags":18446744073709551615,"ratio":2,"active":true}"#
        )
        let bytes = try MMPackEncoder().encode(request).get()
        let decoded = try MMPackDecoder().decode(LedgerEntry.self, from: bytes).get()
        #expect(decoded.flags == UInt64.max)
        #expect(decoded.ratio == 2.0)
    }

    @Test("a string-keyed map schema encodes what a Dictionary would")
    func mapEncoding() throws {
        let schema = TypeSchema.structure(fields: [
            TypeSchema.Field(key: 0, name: "scores", type: .map(key: .string, value: .int))
        ])
        struct Holder: Codable, Equatable {
            var scores: [String: Int]
            enum CodingKeys: Int, CodingKey { case scores = 0 }
        }
        let request = try MMCLIDynamicRequest(
            schema: schema,
            definitions: [],
            json: MMCLIDynamicTree.parse(jsonText: #"{"scores":{"a":1,"b":2}}"#)
        )
        let bytes = try MMPackEncoder().encode(request).get()
        let decoded = try MMPackDecoder().decode(Holder.self, from: bytes).get()
        #expect(decoded == Holder(scores: ["a": 1, "b": 2]))
    }

    @Test("a bytes field takes base64 JSON and encodes a MessagePack bin")
    func bytesEncoding() throws {
        let schema = TypeSchema.structure(fields: [
            TypeSchema.Field(key: 0, name: "blob", type: .bytes)
        ])
        struct Holder: Codable {
            var blob: ByteBuffer
            enum CodingKeys: Int, CodingKey { case blob = 0 }
        }
        let request = try MMCLIDynamicRequest(
            schema: schema,
            definitions: [],
            json: MMCLIDynamicTree.parse(jsonText: #"{"blob":"AQID"}"#)
        )
        let bytes = try MMPackEncoder().encode(request).get()
        var decoded = try MMPackDecoder().decode(Holder.self, from: bytes).get()
        #expect(decoded.blob.readBytes(length: decoded.blob.readableBytes) == [1, 2, 3])
    }

    @Test("validation failures carry the offending field path")
    func validationFailures() {
        expectValidationFailure(
            #"{"kind":"credit","tags":[],"flags":0,"ratio":0,"active":true}"#,
            messageContains: "params.line: missing required field")
        expectValidationFailure(
            #"{"line":5,"kind":"credit","tags":[],"flags":0,"ratio":0,"active":true}"#,
            messageContains: "params.line: expected string")
        expectValidationFailure(
            #"{"line":"a","kind":"credit","bogus":1,"tags":[],"flags":0,"ratio":0,"active":true}"#,
            messageContains: "params.bogus: unknown member")
        expectValidationFailure(
            #"{"line":"a","kind":"wat","tags":[],"flags":0,"ratio":0,"active":true}"#,
            messageContains: "params.kind: 'wat' is not one of")
        expectValidationFailure(
            #"{"line":null,"kind":"credit","tags":[],"flags":0,"ratio":0,"active":true}"#,
            messageContains: "params.line: expected string, got null")
        expectValidationFailure(
            #"{"line":"a","kind":"credit","tags":[true],"flags":0,"ratio":0,"active":true}"#,
            messageContains: "params.tags[0]: expected integer")
        expectValidationFailure(
            #"{"line":"a","kind":"credit","tags":[],"flags":-1,"ratio":0,"active":true}"#,
            messageContains: "params.flags: expected non-negative integer")
    }

    @Test("an unresolved reference is a validation failure, not a trap")
    func unresolvedReference() {
        do {
            _ = try MMCLIDynamicRequest(
                schema: ledgerEntrySchema,
                definitions: [],  // no table: ledger.Kind cannot resolve
                json: MMCLIDynamicTree.parse(
                    jsonText:
                        #"{"line":"a","kind":"credit","tags":[],"flags":0,"ratio":0,"active":true}"#
                )
            )
            Issue.record("expected a ValidationError")
        } catch let error as ValidationError {
            #expect(error.message.contains("unresolved type reference 'ledger.Kind'"))
        } catch {
            Issue.record("expected ValidationError, got \(error)")
        }
    }

    @Test("a field with an unknown schema shape refuses to encode")
    func unknownSchemaRefused() {
        let schema = TypeSchema.structure(fields: [
            TypeSchema.Field(key: 0, name: "mystery", type: .unknown)
        ])
        do {
            _ = try MMCLIDynamicRequest(
                schema: schema,
                definitions: [],
                json: MMCLIDynamicTree.parse(jsonText: #"{"mystery":1}"#)
            )
            Issue.record("expected a ValidationError")
        } catch let error as ValidationError {
            #expect(error.message.contains("params.mystery"))
        } catch {
            Issue.record("expected ValidationError, got \(error)")
        }
    }
}

// MARK: - Response decoding

@Suite("MMCLIDynamicResponse: schema-driven decoding")
struct DynamicResponseTests {
    private func decodeLedger(_ entry: LedgerEntry) throws -> MMCLIDynamicTree {
        let bytes = try MMPackEncoder().encode(entry).get()
        let response = try MMCLIDynamicResponse.$schema.withValue(
            (ledgerEntrySchema, ledgerDefinitions)
        ) {
            try MMPackDecoder().decode(MMCLIDynamicResponse.self, from: bytes).get()
        }
        return response.tree
    }

    @Test("a full fixture decodes into the named, schema-ordered tree")
    func fullDecode() throws {
        let tree = try decodeLedger(
            LedgerEntry(
                line: "x", kind: .debit, meta: LedgerMeta(note: "m"), count: 4,
                tags: [3, 5], flags: 2, ratio: 0.5, active: false))
        #expect(
            tree
                == .object([
                    .init("line", .string("x")),
                    .init("kind", .string("debit")),
                    .init("meta", .object([.init("note", .string("m"))])),
                    .init("count", .int(4)),
                    .init("tags", .array([.int(3), .int(5)])),
                    .init("flags", .uint(2)),
                    .init("ratio", .double(0.5)),
                    .init("active", .bool(false)),
                ]))
    }

    @Test("absent optionals are omitted from the tree")
    func absentOptionals() throws {
        let tree = try decodeLedger(
            LedgerEntry(
                line: "y", kind: .credit, meta: nil, count: nil,
                tags: [], flags: 0, ratio: 1.0, active: true))
        #expect(
            tree
                == .object([
                    .init("line", .string("y")),
                    .init("kind", .string("credit")),
                    .init("tags", .array([])),
                    .init("flags", .uint(0)),
                    .init("ratio", .double(1.0)),
                    .init("active", .bool(true)),
                ]))
    }

    @Test("unknown slots fall back through String, Int64, UInt64, Bool, Double, then null")
    func unknownFallback() throws {
        struct Mixed: Codable, Sendable {
            var name: String
            var count: Int
            var big: UInt64
            var flag: Bool
            var ratio: Double
            var nested: [String: Int]

            enum CodingKeys: Int, CodingKey {
                case name = 0
                case count = 1
                case big = 2
                case flag = 3
                case ratio = 4
                case nested = 5
            }
        }
        let schema = TypeSchema.structure(
            fields: (0...5).map { key in
                TypeSchema.Field(
                    key: key,
                    name: ["name", "count", "big", "flag", "ratio", "nested"][key],
                    type: .unknown)
            })
        let bytes = try MMPackEncoder().encode(
            Mixed(
                name: "n", count: 7, big: UInt64.max, flag: true, ratio: 2.5,
                nested: ["a": 1])
        ).get()
        let response = try MMCLIDynamicResponse.$schema.withValue((schema, [])) {
            try MMPackDecoder().decode(MMCLIDynamicResponse.self, from: bytes).get()
        }
        #expect(
            response.tree
                == .object([
                    .init("name", .string("n")),
                    .init("count", .int(7)),
                    .init("big", .uint(UInt64.max)),
                    .init("flag", .bool(true)),
                    .init("ratio", .double(2.5)),
                    .init("nested", .null),  // no scalar try matches a map
                ]))
    }

    @Test("arrays of referenced structures decode element by element")
    func arrayOfStructures() throws {
        struct Batch: Codable, Sendable {
            var entries: [LedgerMeta]
            enum CodingKeys: Int, CodingKey { case entries = 0 }
        }
        let schema = TypeSchema.structure(fields: [
            TypeSchema.Field(key: 0, name: "entries", type: .array(.reference("ledger.Meta")))
        ])
        let bytes = try MMPackEncoder().encode(
            Batch(entries: [LedgerMeta(note: "a"), LedgerMeta(note: "b")])
        ).get()
        let response = try MMCLIDynamicResponse.$schema.withValue((schema, ledgerDefinitions)) {
            try MMPackDecoder().decode(MMCLIDynamicResponse.self, from: bytes).get()
        }
        #expect(
            response.tree
                == .object([
                    .init(
                        "entries",
                        .array([
                            .object([.init("note", .string("a"))]),
                            .object([.init("note", .string("b"))]),
                        ])
                    )
                ]))
    }

    @Test("maps decode with deterministic key order")
    func mapDecoding() throws {
        struct Holder: Codable, Sendable {
            var scores: [String: Int]
            enum CodingKeys: Int, CodingKey { case scores = 0 }
        }
        let schema = TypeSchema.structure(fields: [
            TypeSchema.Field(key: 0, name: "scores", type: .map(key: .string, value: .int))
        ])
        let bytes = try MMPackEncoder().encode(Holder(scores: ["b": 2, "a": 1, "c": 3])).get()
        let response = try MMCLIDynamicResponse.$schema.withValue((schema, [])) {
            try MMPackDecoder().decode(MMCLIDynamicResponse.self, from: bytes).get()
        }
        #expect(
            response.tree
                == .object([
                    .init(
                        "scores",
                        .object([.init("a", .int(1)), .init("b", .int(2)), .init("c", .int(3))])
                    )
                ]))
    }

    @Test("bytes fields decode to raw bytes, which render as base64")
    func bytesDecoding() throws {
        struct Holder: Codable {
            var blob: ByteBuffer
            enum CodingKeys: Int, CodingKey { case blob = 0 }
        }
        let schema = TypeSchema.structure(fields: [
            TypeSchema.Field(key: 0, name: "blob", type: .bytes)
        ])
        let bytes = try MMPackEncoder().encode(Holder(blob: ByteBuffer(bytes: [1, 2, 3]))).get()
        let response = try MMCLIDynamicResponse.$schema.withValue((schema, [])) {
            try MMPackDecoder().decode(MMCLIDynamicResponse.self, from: bytes).get()
        }
        #expect(response.tree == .object([.init("blob", .bytes([1, 2, 3]))]))
        #expect(MMCLIDynamicJSONText(response.tree, pretty: false) == #"{"blob":"AQID"}"#)
    }

    @Test("an unbound task-local is an honest decode failure")
    func unboundTaskLocal() throws {
        let bytes = try MMPackEncoder().encode(LedgerMeta(note: "x")).get()
        let result = MMPackDecoder().decode(MMCLIDynamicResponse.self, from: bytes)
        switch result {
            case .success:
                Issue.record("expected a decode failure without the bound schema")
            case .failure:
                break
        }
    }
}

// MARK: - JSON text: parsing and rendering

@Suite("Dynamic JSON text: parsing")
struct DynamicJSONParseTests {
    @Test("booleans stay booleans; numbers stay numbers")
    func booleanVersusNumber() throws {
        #expect(try MMCLIDynamicTree.parse(jsonText: "true") == .bool(true))
        #expect(try MMCLIDynamicTree.parse(jsonText: "false") == .bool(false))
        #expect(try MMCLIDynamicTree.parse(jsonText: "1") == .int(1))
        #expect(try MMCLIDynamicTree.parse(jsonText: "0") == .int(0))
        #expect(
            try normalized(MMCLIDynamicTree.parse(jsonText: #"{"a":true,"b":1,"c":0}"#))
                == .object([
                    .init("a", .bool(true)),
                    .init("b", .int(1)),
                    .init("c", .int(0)),
                ]))
    }

    @Test("number kinds map to Int64, then UInt64, then Double")
    func numberKinds() throws {
        #expect(try MMCLIDynamicTree.parse(jsonText: "-2") == .int(-2))
        #expect(
            try MMCLIDynamicTree.parse(jsonText: "9223372036854775807") == .int(Int64.max))
        #expect(
            try MMCLIDynamicTree.parse(jsonText: "9223372036854775808")
                == .uint(9_223_372_036_854_775_808))
        #expect(
            try MMCLIDynamicTree.parse(jsonText: "18446744073709551615") == .uint(UInt64.max))
        #expect(try MMCLIDynamicTree.parse(jsonText: "1.5") == .double(1.5))
        #expect(try MMCLIDynamicTree.parse(jsonText: "-2.5e-1") == .double(-0.25))
        // A whole-valued float literal collapses to the integer kind — fine,
        // because validation is schema-directed and re-widens where the
        // schema says double.
        #expect(try MMCLIDynamicTree.parse(jsonText: "1e3") == .int(1000))
    }

    @Test("literals, arrays, nesting, and whitespace")
    func structure() throws {
        let tree = try MMCLIDynamicTree.parse(
            jsonText: #" { "a" : [ true , false , null ] , "b" : { } } "#)
        #expect(
            normalized(tree)
                == .object([
                    .init("a", .array([.bool(true), .bool(false), .null])),
                    .init("b", .object([])),
                ]))
    }

    @Test("malformed JSON is a ValidationError")
    func malformed() {
        for bad in ["{", "tru", "1 2", #"{"a":}"#, #"{"a" 1}"#, "\"\\q\"", "01x", ""] {
            #expect(throws: ValidationError.self, "input: \(bad)") {
                _ = try MMCLIDynamicTree.parse(jsonText: bad)
            }
        }
    }

    @Test("Foundation's documented leniency: array trailing commas parse")
    func trailingCommaLeniency() throws {
        // JSON syntax is Foundation's domain now (by design); correctness is
        // the schema-directed validation layer's job, not syntax pedantry.
        #expect(try MMCLIDynamicTree.parse(jsonText: "[1,]") == .array([.int(1)]))
    }
}

@Suite("Dynamic JSON text: rendering")
struct DynamicJSONRenderTests {
    @Test("compact rendering preserves order and escapes")
    func compact() {
        let tree = MMCLIDynamicTree.object([
            .init("b", .int(1)),
            .init("a", .string("x\"y\n")),
            .init("u", .uint(UInt64.max)),
            .init("d", .double(1.5)),
            .init("n", .null),
            .init("list", .array([.bool(true), .object([])])),
        ])
        #expect(
            MMCLIDynamicJSONText(tree, pretty: false)
                == #"{"b":1,"a":"x\"y\n","u":18446744073709551615,"d":1.5,"n":null,"list":[true,{}]}"#
        )
        // Control characters take the \u form; quote and backslash their
        // shorthands.
        #expect(
            MMCLIDynamicJSONText(.string("\u{01}\u{1F}\\"), pretty: false)
                == "\"\\u0001\\u001f\\\\\"")
    }

    @Test("pretty rendering indents two spaces")
    func pretty() {
        let tree = MMCLIDynamicTree.object([
            .init("b", .int(1)),
            .init("list", .array([.bool(true)])),
        ])
        let expected = """
            {
              "b": 1,
              "list": [
                true
              ]
            }
            """
        #expect(MMCLIDynamicJSONText(tree, pretty: true) == expected)
    }

    @Test("bytes render as a base64 string")
    func bytes() {
        #expect(MMCLIDynamicJSONText(.bytes([1, 2, 3]), pretty: false) == "\"AQID\"")
        #expect(MMCLIDynamicJSONText(.bytes([]), pretty: false) == "\"\"")
        #expect(
            MMCLIDynamicJSONText(.object([.init("blob", .bytes([0xFF]))]), pretty: false)
                == #"{"blob":"\/w=="}"#.replacingOccurrences(of: "\\/", with: "/"))
    }

    @Test("rendered text parses back to the identical tree (up to member order)")
    func roundTrip() throws {
        let tree = MMCLIDynamicTree.object([
            .init("z", .array([.int(-3), .uint(UInt64.max), .double(0.25), .string("s")])),
            .init("emoji", .string("ok 😀 \u{07}")),
            .init("inner", .object([.init("k", .null), .init("b", .bool(false))])),
        ])
        #expect(
            try normalized(MMCLIDynamicTree.parse(jsonText: MMCLIDynamicJSONText(tree, pretty: false)))
                == normalized(tree))
        #expect(
            try normalized(MMCLIDynamicTree.parse(jsonText: MMCLIDynamicJSONText(tree, pretty: true)))
                == normalized(tree))
    }
}

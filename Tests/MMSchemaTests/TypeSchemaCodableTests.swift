import Foundation
import Testing

@testable import MMSchema

@Suite("TypeSchema Codable")
struct TypeSchemaCodableTests {
    static let samples: [TypeSchema] = [
        .bool, .int, .uint, .float, .double, .string, .bytes, .unknown,
        .optional(.string),
        .array(.optional(.int)),
        .map(key: .string, value: .array(.double)),
        .structure(fields: [
            .init(key: 0, name: "entity", type: .string),
            .init(key: nil, name: "legacy", type: .unknown),
            .init(
                key: 2, name: "inner",
                type: .structure(fields: [.init(key: 0, name: "x", type: .int)])),
        ]),
        .enumeration(cases: [
            .init(name: "low"),
            .init(name: "high", description: "wakes the pager"),
        ]),
        .reference("journal.Priority"),
        .structure(fields: [
            .init(
                key: 0, name: "meta", type: .reference("common.LineMeta"), description: "documented"
            )
        ]),
    ]

    @Test("round trip", arguments: samples)
    func roundTrip(_ schema: TypeSchema) throws {
        let data = try JSONEncoder().encode(schema)
        let decoded = try JSONDecoder().decode(TypeSchema.self, from: data)
        #expect(decoded == schema)
    }

    @Test("unrecognized case tag decodes to unknown, never fails")
    func unknownTag() throws {
        let data = Data(#"{"tag": 99}"#.utf8)
        #expect(try JSONDecoder().decode(TypeSchema.self, from: data) == .unknown)
    }

    @Test("missing tag decodes to unknown")
    func missingTag() throws {
        let data = Data(#"{"first": 1}"#.utf8)
        #expect(try JSONDecoder().decode(TypeSchema.self, from: data) == .unknown)
    }

    @Test("non-map value decodes to unknown")
    func nonMapValue() throws {
        #expect(try JSONDecoder().decode(TypeSchema.self, from: Data(#""hello""#.utf8)) == .unknown)
        #expect(try JSONDecoder().decode(TypeSchema.self, from: Data("7".utf8)) == .unknown)
    }

    @Test("recognized tag with corrupt payload decodes to unknown")
    func corruptPayload() throws {
        // optional (7) with no wrapped schema; map (9) missing its value schema.
        #expect(
            try JSONDecoder().decode(TypeSchema.self, from: Data(#"{"tag": 7}"#.utf8)) == .unknown)
        #expect(
            try JSONDecoder().decode(
                TypeSchema.self, from: Data(#"{"tag": 9, "first": {"tag": 5}}"#.utf8))
                == .unknown
        )
        // enumeration (11) with no case list; reference (12) with no name.
        #expect(
            try JSONDecoder().decode(TypeSchema.self, from: Data(#"{"tag": 11}"#.utf8)) == .unknown)
        #expect(
            try JSONDecoder().decode(TypeSchema.self, from: Data(#"{"tag": 12}"#.utf8)) == .unknown)
    }

    @Test("TypeDefinition round trips, with and without description")
    func typeDefinitionRoundTrip() throws {
        let definitions = [
            TypeDefinition(
                name: "journal.Priority",
                schema: .enumeration(cases: [.init(name: "low"), .init(name: "high")]),
                description: "how urgent"
            ),
            TypeDefinition(
                name: "common.LineMeta",
                schema: .structure(fields: [.init(key: 0, name: "author", type: .string)])
            ),
        ]
        for definition in definitions {
            let decoded = try JSONDecoder().decode(
                TypeDefinition.self, from: JSONEncoder().encode(definition))
            #expect(decoded == definition)
        }
    }

    @Test("an undocumented field emits no description key")
    func undocumentedFieldEmitsNoDescriptionKey() throws {
        let field = TypeSchema.Field(key: 0, name: "entity", type: .string)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(field))
        let keys = try #require(object as? [String: Any]).keys.sorted()
        #expect(keys == ["key", "name", "type"])
    }

    @Test("strippingDescriptions removes docs everywhere, shape untouched")
    func stripping() {
        let documented = TypeSchema.structure(fields: [
            .init(key: 0, name: "entity", type: .string, description: "target"),
            .init(
                key: 1, name: "priority",
                type: .enumeration(cases: [.init(name: "low", description: "whenever")]),
                description: "urgency"),
            .init(key: 2, name: "meta", type: .optional(.reference("common.LineMeta"))),
        ])
        let stripped = TypeSchema.structure(fields: [
            .init(key: 0, name: "entity", type: .string),
            .init(key: 1, name: "priority", type: .enumeration(cases: [.init(name: "low")])),
            .init(key: 2, name: "meta", type: .optional(.reference("common.LineMeta"))),
        ])
        #expect(documented.strippingDescriptions == stripped)
        #expect(stripped.strippingDescriptions == stripped)
    }

    @Test("MethodSignature.strippingDescriptions clears all five doc slots")
    func signatureStripping() {
        let documented = MethodSignature(
            name: "journal.append",
            access: .write,
            request: .structure(fields: [
                .init(key: 0, name: "entity", type: .string, description: "target")
            ]),
            response: .structure(fields: []),
            requestStream: .structure(fields: [
                .init(key: 0, name: "line", type: .string, description: "one line")
            ]),
            description: "appends",
            requestDescription: "what to append",
            responseDescription: "ack",
            requestStreamDescription: "the lines",
            responseStreamDescription: "unused"
        )
        let stripped = documented.strippingDescriptions
        #expect(stripped.description == nil)
        #expect(stripped.requestDescription == nil)
        #expect(stripped.responseDescription == nil)
        #expect(stripped.requestStreamDescription == nil)
        #expect(stripped.responseStreamDescription == nil)
        #expect(
            stripped.request
                == .structure(fields: [.init(key: 0, name: "entity", type: .string)])
        )
        #expect(
            stripped.requestStream
                == .structure(fields: [.init(key: 0, name: "line", type: .string)])
        )
    }

    @Test("MethodSignature Codable round trip")
    func methodSignatureRoundTrip() throws {
        let signature = MethodSignature(
            name: "journal.append",
            access: .write,
            request: .structure(fields: [.init(key: 0, name: "entity", type: .string)]),
            response: .structure(fields: [.init(key: 0, name: "sequence", type: .uint)])
        )
        let data = try JSONEncoder().encode(signature)
        let decoded = try JSONDecoder().decode(MethodSignature.self, from: data)
        #expect(decoded == signature)
    }

    @Test("MethodSignature with streams round trips")
    func methodSignatureStreamRoundTrip() throws {
        let signature = MethodSignature(
            name: "journal.sync",
            access: [.read, .write],
            request: .structure(fields: [.init(key: 0, name: "entity", type: .string)]),
            response: .structure(fields: [.init(key: 0, name: "delivered", type: .uint)]),
            requestStream: .structure(fields: [.init(key: 0, name: "line", type: .string)]),
            responseStream: .structure(fields: [.init(key: 0, name: "count", type: .int)])
        )
        let data = try JSONEncoder().encode(signature)
        let decoded = try JSONDecoder().decode(MethodSignature.self, from: data)
        #expect(decoded == signature)
    }

    @Test("a pre-stream four-field encoding decodes with nil stream slots")
    func legacyEncodingDecodesWithNilStreams() throws {
        let legacy = LegacyMethodSignature(
            name: "journal.append",
            access: .write,
            request: .structure(fields: [.init(key: 0, name: "entity", type: .string)]),
            response: .structure(fields: [.init(key: 0, name: "sequence", type: .uint)])
        )
        let decoded = try JSONDecoder().decode(
            MethodSignature.self, from: JSONEncoder().encode(legacy))
        #expect(
            decoded
                == MethodSignature(
                    name: "journal.append",
                    access: .write,
                    request: legacy.request,
                    response: legacy.response,
                    requestStream: nil,
                    responseStream: nil
                )
        )
    }

    @Test("a documented signature round trips and an old reader skips keys 6–10")
    func documentedSignatureRoundTrip() throws {
        let documented = MethodSignature(
            name: "journal.append",
            access: .write,
            request: .structure(fields: [
                .init(key: 0, name: "entity", type: .string, description: "target journal")
            ]),
            response: .structure(fields: [.init(key: 0, name: "count", type: .uint)]),
            description: "appends a line",
            requestDescription: "what to append",
            responseDescription: "the new line count"
        )
        let decoded = try JSONDecoder().decode(
            MethodSignature.self, from: JSONEncoder().encode(documented))
        #expect(decoded == documented)
        // The pre-types reader (keys 0–3 only) skips the doc keys.
        let legacy = try JSONDecoder().decode(
            LegacyMethodSignature.self, from: JSONEncoder().encode(documented))
        #expect(legacy.name == documented.name)
        #expect(legacy.access == documented.access)
    }

    @Test("a stream-carrying encoding decodes on an old reader by skipping keys 4/5")
    func streamEncodingDecodesOnOldReader() throws {
        let streaming = MethodSignature(
            name: "journal.sync",
            access: [.read, .write],
            request: .structure(fields: [.init(key: 0, name: "entity", type: .string)]),
            response: .structure(fields: [.init(key: 0, name: "delivered", type: .uint)]),
            requestStream: .structure(fields: [.init(key: 0, name: "line", type: .string)]),
            responseStream: .structure(fields: [.init(key: 0, name: "count", type: .int)])
        )
        let decoded = try JSONDecoder().decode(
            LegacyMethodSignature.self, from: JSONEncoder().encode(streaming))
        #expect(
            decoded
                == LegacyMethodSignature(
                    name: streaming.name,
                    access: streaming.access,
                    request: streaming.request,
                    response: streaming.response
                )
        )
    }

    @Test("a unary signature encodes exactly the four pre-stream keys")
    func unaryEncodingEmitsNoStreamKeys() throws {
        let unary = MethodSignature(
            name: "journal.append",
            access: .write,
            request: .structure(fields: [.init(key: 0, name: "entity", type: .string)]),
            response: .structure(fields: [.init(key: 0, name: "sequence", type: .uint)])
        )
        // JSON spells the integer-raw-value CodingKeys by their stringValue;
        // the point pinned here is that the nil stream slots emit no keys.
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(unary))
        let keys = try #require(object as? [String: Any]).keys.sorted()
        #expect(keys == ["access", "name", "request", "response"])
    }
}

/// The pre-stream (S2) four-field shape of `MethodSignature`, replicated here
/// as an "old reader" so both evolution directions are pinned against real
/// coder output.
private struct LegacyMethodSignature: Codable, Equatable {
    var name: String
    var access: AccessMode
    var request: TypeSchema
    var response: TypeSchema

    enum CodingKeys: Int, CodingKey {
        case name = 0
        case access = 1
        case request = 2
        case response = 3
    }
}

import Testing

@testable import MMSchema

// MARK: - A contract exercising named types, references, and descriptions

private let libraryContract = Schema("library") {
    Enum("Genre", description: "Shelf classification") {
        Case("fiction")
        Case("reference", description: "Not lendable")
    }
    Type("BookMeta", description: "Catalog metadata") {
        Field("author", .string, description: "Display name")
        Field("genre", "Genre")
    }
    Call("shelve", description: "Files a book onto a shelf") {
        Access { .write }
        Request(description: "The book to shelve") {
            Field("title", .string, description: "Spine title")
            Field("meta", "BookMeta")
            Field("related", .optional(.reference("Genre")))
            Field("tags", "common.TagSet")
        }
        Response(description: "Shelving acknowledgement") {
            Field("count", .int)
        }
    }
}

@Suite("Named types in the declaration DSL")
struct TypeDeclarationTests {
    @Test("Enum and Type declarations become namespace-qualified definitions")
    func qualifiedDefinitions() {
        #expect(libraryContract.types.map(\.name) == ["library.Genre", "library.BookMeta"])
        #expect(libraryContract.types[0].description == "Shelf classification")
        #expect(
            libraryContract.types[0].schema
                == .enumeration(cases: [
                    .init(name: "fiction"),
                    .init(name: "reference", description: "Not lendable"),
                ])
        )
    }

    @Test("references inside type definitions resolve against the same block")
    func definitionInternalReferences() {
        #expect(
            libraryContract.types[1].schema
                == .structure(fields: [
                    .init(key: 0, name: "author", type: .string, description: "Display name"),
                    .init(key: 1, name: "genre", type: .reference("library.Genre")),
                ])
        )
    }

    @Test("field references qualify locally, pass dotted names through, and reach nested positions")
    func fieldReferences() {
        let request = libraryContract.signatures[0].request
        guard case .structure(let fields) = request else {
            Issue.record("request is not a structure")
            return
        }
        #expect(fields[1].type == .reference("library.BookMeta"))
        #expect(fields[2].type == .optional(.reference("library.Genre")))
        #expect(fields[3].type == .reference("common.TagSet"))
    }

    @Test("descriptions land in the signature doc slots and on fields")
    func descriptions() {
        let signature = libraryContract.signatures[0]
        #expect(signature.description == "Files a book onto a shelf")
        #expect(signature.requestDescription == "The book to shelve")
        #expect(signature.responseDescription == "Shelving acknowledgement")
        guard case .structure(let fields) = signature.request else {
            Issue.record("request is not a structure")
            return
        }
        #expect(fields[0].description == "Spine title")
    }

    @Test("the fingerprint covers the type table and ignores descriptions")
    func fingerprintCoversTypes() {
        #expect(
            libraryContract.fingerprint()
                == SchemaFingerprint.compute(
                    libraryContract.signatures, types: libraryContract.types)
        )
        #expect(
            libraryContract.fingerprint()
                != SchemaFingerprint.compute(libraryContract.signatures)
        )
        // The same contract with no documentation fingerprints identically.
        let undocumented = Schema("library") {
            Enum("Genre") {
                Case("fiction")
                Case("reference")
            }
            Type("BookMeta") {
                Field("author", .string)
                Field("genre", "Genre")
            }
            Call("shelve") {
                Access { .write }
                Request {
                    Field("title", .string)
                    Field("meta", "BookMeta")
                    Field("related", .optional(.reference("Genre")))
                    Field("tags", "common.TagSet")
                }
                Response {
                    Field("count", .int)
                }
            }
        }
        #expect(undocumented.fingerprint() == libraryContract.fingerprint())
    }

    @Test("a Types block qualifies shared types and resolves internal references")
    func typesBlock() {
        let common = Types("common") {
            Enum("Color") {
                Case("red")
            }
            Type("TagSet") {
                Field("tags", .array(.string))
                Field("color", "Color")
            }
        }
        #expect(common.namespace == "common")
        #expect(common.types.map(\.name) == ["common.Color", "common.TagSet"])
        #expect(
            common.types[1].schema
                == .structure(fields: [
                    .init(key: 0, name: "tags", type: .array(.string)),
                    .init(key: 1, name: "color", type: .reference("common.Color")),
                ])
        )
    }

    @Test("an undotted reference that resolves nowhere is programmer error")
    func unresolvedReferenceExits() async {
        await #expect(processExitsWith: .failure) {
            _ = Schema("box") {
                Call("put") {
                    Access { .write }
                    Request {
                        Field("meta", "Missing")
                    }
                }
            }
        }
    }

    @Test("duplicate type names in one block are programmer error")
    func duplicateTypeExits() async {
        await #expect(processExitsWith: .failure) {
            _ = Types("common") {
                Enum("Color") { Case("red") }
                Type("Color") { Field("x", .int) }
            }
        }
    }

    @Test("any named type can BE the request — and stay a value type elsewhere")
    func namedTypeRequest() {
        // The entity rides the open envelope, so a request payload is a plain
        // value like any other part.
        let contract = Schema("box") {
            Type("SetPayload", description: "Shared set request") {
                Field("line", .string)
            }
            Call("set") {
                Access { .write }
                Request(.reference("SetPayload"), description: "What to set")
            }
            Call("last") {
                Access { .read }
                Response(.reference("SetPayload"))
            }
        }
        #expect(
            contract.types[0].schema
                == .structure(fields: [.init(key: 0, name: "line", type: .string)])
        )
        #expect(contract.signatures[0].request == .reference("box.SetPayload"))
        #expect(contract.signatures[0].requestDescription == "What to set")
        #expect(contract.signatures[1].response == .reference("box.SetPayload"))
    }

    @Test("Response and stream parts can BE a named type")
    func partReferences() {
        let contract = Schema("box") {
            Type("Meta") { Field("author", .string) }
            Enum("Verdict") {
                Case("yes")
                Case("no")
            }
            Call("get") {
                Access { .read }
                Response(.reference("Meta"), description: "The whole payload is Meta")
            }
            Call("watch") {
                Access { .read }
                ResponseStream(.reference("Meta"))
                Response(.reference("Verdict"))
            }
            Call("send") {
                Access { .write }
                RequestStream(.reference("Meta"))
            }
        }
        #expect(contract.signatures[0].response == .reference("box.Meta"))
        #expect(contract.signatures[0].responseDescription == "The whole payload is Meta")
        #expect(contract.signatures[1].responseStream == .reference("box.Meta"))
        #expect(contract.signatures[1].response == .reference("box.Verdict"))
        #expect(contract.signatures[2].requestStream == .reference("box.Meta"))
    }
}

// MARK: - Verification fixtures: a namespace implementing a typed contract

private let tagsContract = Schema("tags") {
    Enum("Color", description: "Paint color") {
        Case("red")
        Case("blue")
    }
    Call("paint", description: "Paints the entity") {
        Access { .write }
        Request {
            Field("color", "Color")
        }
        Response {
            Field("ok", .bool)
        }
    }
    // The response IS the named enum: verify resolves the reference and
    // accepts the probed .string (enums decode their raw value).
    Call("pick", description: "Returns the current color") {
        Access { .read }
        Response(.reference("Color"))
    }
    // The response IS another container's type (cross-schema): verify cannot
    // resolve it here, so the described reference carries the check.
    Call("stamp") {
        Access { .read }
        Response(HandTypes.Stamp.self)
    }
    // The request IS a named type — a plain value; the entity rides the
    // envelope.
    Type("Recolor", description: "Shared recolor request") {
        Field("color", "Color")
    }
    Call("recolor") {
        Access { .write }
        Request(.reference("Recolor"))
        Response {
            Field("ok", .bool)
        }
    }
}

private enum PaintColor: String, Codable, Sendable, CaseIterable, SchemaDescribable {
    case red, blue, unknown

    static var schema: TypeSchema { .reference("tags.Color") }
}

private struct PaintRequest: Codable, Hashable, Sendable {
    var color: PaintColor

    enum CodingKeys: Int, CodingKey {
        case color = 0
    }
}

private struct PaintResponse: Codable, Hashable, Sendable {
    var ok: Bool

    enum CodingKeys: Int, CodingKey {
        case ok = 0
    }
}

/// An empty request payload; self-describes because a property-less decoder
/// is unprobeable.
private struct PickRequest: Codable, Hashable, Sendable, SchemaDescribable {
    static var schema: TypeSchema { .structure(fields: []) }
}

/// The hand-written counterpart of the named `Recolor` request payload.
private struct RecolorPayload: Codable, Hashable, Sendable, SchemaDescribable {
    var color: PaintColor

    enum CodingKeys: Int, CodingKey {
        case color = 0
    }

    static var schema: TypeSchema { .reference("tags.Recolor") }
}

private enum Tags: MethodNamespace {
    static let paint = Method<PaintRequest, PaintResponse>(
        name: "tags.paint",
        access: .write,
        documentation: .init(description: "Paints the entity")
    )
    // The named enum IS the response type.
    static let pick = Method<PickRequest, PaintColor>(
        name: "tags.pick",
        access: .read,
        documentation: .init(description: "Returns the current color")
    )
    // Another container's type IS the response type.
    static let stamp = Method<PickRequest, HandTypes.Stamp>(name: "tags.stamp", access: .read)
    // The entity-scoped named type IS the request type.
    static let recolor = Method<RecolorPayload, PaintResponse>(name: "tags.recolor", access: .write)

    @SchemaBuilder static var all: [AnyMethod] {
        paint
        pick
        stamp
        recolor
    }

    static var types: [TypeDefinition] {
        [
            TypeDefinition(
                name: "tags.Color",
                schema: .enumeration(cases: [.init(name: "red"), .init(name: "blue")])
            ),
            TypeDefinition(
                name: "tags.Recolor",
                schema: .structure(fields: [
                    .init(key: 0, name: "color", type: .reference("tags.Color"))
                ])
            ),
        ]
    }

    static var probedTypes: [String: Result<TypeSchema, SchemaError>] {
        [
            "tags.Color": TypeSchema.probed(PaintColor.self),
            "tags.Recolor": TypeSchema.probed(RecolorPayload.self),
        ]
    }
}

/// Behavior matches the contract (`value` decodes as Int) but the described
/// schema lies about it.
private struct LyingRequest: Codable, Hashable, Sendable, SchemaDescribable {
    var value: Int

    enum CodingKeys: Int, CodingKey {
        case value = 0
    }

    static var schema: TypeSchema {
        .structure(fields: [
            .init(key: 0, name: "value", type: .string)  // lie: behavior is .int
        ])
    }
}

@Suite("Verification of typed contracts")
struct TypedVerifyTests {
    @Test("a faithful namespace with types verifies clean, docs ignored")
    func faithfulNamespace() throws {
        #expect(try tagsContract.verify(against: Tags.self).get().isEmpty)
    }

    @Test("probed bypasses a top-level SchemaDescribable; of honors it")
    func probedBypassesDescribable() {
        #expect(TypeSchema.of(PaintColor.self) == .success(.reference("tags.Color")))
        #expect(TypeSchema.probed(PaintColor.self) == .success(.string))
    }

    @Test("descriptor documentation overlays the signature, not the probe")
    func documentationOverlay() throws {
        let signature = try Tags.paint.signature().get()
        #expect(signature.description == "Paints the entity")
        let probed = try Tags.paint.probedSignature().get()
        #expect(probed.description == nil)
    }

    @Test("a diverging type definition is reported")
    func divergingDefinition() throws {
        let contract = Schema("tags") {
            Enum("Color") {
                Case("red")
                Case("green")  // namespace defines blue
            }
            Call("paint") {
                Access { .write }
                Request { Field("color", "Color") }
                Response { Field("ok", .bool) }
            }
        }
        let mismatches = try contract.verify(against: Tags.self).get()
        #expect(mismatches.contains("tags.Color: type definition diverges from the contract"))
        #expect(!mismatches.contains { $0.contains("tags.paint") })
    }

    @Test("declared-but-undefined and defined-but-undeclared types are reported")
    func typePresenceMismatches() throws {
        let contract = Schema("tags") {
            Enum("Hue") { Case("red") }
            Call("paint") {
                Access { .write }
                Request { Field("color", "tags.Color") }
                Response { Field("ok", .bool) }
            }
        }
        let mismatches = try contract.verify(against: Tags.self).get()
        #expect(mismatches.contains("tags.Hue: type declared but not defined by the namespace"))
        #expect(
            mismatches.contains("tags.Color: type defined by the namespace but not in the contract")
        )
    }

    @Test("a SchemaDescribable lying about decoder behavior is reported")
    func lyingDescription() throws {
        let method = Method<LyingRequest, PaintResponse>(name: "tags.lie", access: .write)
        let contract = Schema("tags") {
            Call("lie") {
                Access { .write }
                Request { Field("value", .int) }
                Response { Field("ok", .bool) }
            }
        }
        let mismatches = try contract.verify(against: [AnyMethod(method)]).get()
        #expect(mismatches == ["tags.lie: request described schema diverges from the contract"])
    }

    @Test("a referenced-payload slot whose behavior diverges is reported")
    func referencedSlotBehaviorDiverges() throws {
        // Contract: response IS the Color enum. Implementation returns a
        // struct — the resolution step (definition says enumeration →
        // expected .string) catches it.
        let wrong = Method<PickRequest, PaintResponse>(name: "tags.pick", access: .read)
        let contract = Schema("tags") {
            Enum("Color") {
                Case("red")
                Case("blue")
            }
            Call("pick") {
                Access { .read }
                Response(.reference("Color"))
            }
        }
        let mismatches = try contract.verify(against: [AnyMethod(wrong)]).get()
        #expect(mismatches == ["tags.pick: response shape diverges from the contract"])
    }
}

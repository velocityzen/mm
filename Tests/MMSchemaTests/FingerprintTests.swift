import Testing

@testable import MMSchema

@Suite("SchemaFingerprint")
struct FingerprintTests {
    static let appendSignature = MethodSignature(
        name: "journal.append",
        access: .write,
        request: .structure(fields: [
            .init(key: 0, name: "entity", type: .string),
            .init(key: 1, name: "events", type: .array(.bytes)),
            .init(key: 2, name: "note", type: .optional(.string)),
        ]),
        response: .structure(fields: [.init(key: 0, name: "sequence", type: .uint)])
    )

    // The name is a frozen test-vector string (it predates the builtin
    // rename and is deliberately NOT kept in sync): changing any fixture
    // input would invalidate the golden pinned value below.
    static let statSignature = MethodSignature(
        name: "entity.stat",
        access: .read,
        request: .structure(fields: [.init(key: 0, name: "entity", type: .string)]),
        response: .structure(fields: [
            .init(key: 0, name: "owner", type: .uint),
            .init(key: 1, name: "group", type: .uint),
            .init(key: 2, name: "mode", type: .uint),
        ])
    )

    static let listSignature = MethodSignature(
        name: "journal.list",
        access: .read,
        request: .structure(fields: [
            .init(key: 0, name: "entity", type: .string),
            .init(key: 1, name: "filters", type: .map(key: .string, value: .bool)),
            .init(key: nil, name: "legacy", type: .unknown),
        ]),
        response: .array(.double)
    )

    @Test("stable across source-order permutations")
    func orderInsensitive() {
        let signatures = [Self.appendSignature, Self.statSignature, Self.listSignature]
        let reference = SchemaFingerprint.compute(signatures)
        #expect(
            SchemaFingerprint.compute([
                Self.statSignature, Self.listSignature, Self.appendSignature,
            ]) == reference)
        #expect(
            SchemaFingerprint.compute([
                Self.listSignature, Self.appendSignature, Self.statSignature,
            ]) == reference)
        #expect(SchemaFingerprint.compute(signatures.reversed()) == reference)
    }

    @Test("sensitive to a renamed method")
    func renamedMethod() {
        var renamed = Self.appendSignature
        renamed.name = "journal.appendx"
        let reference = SchemaFingerprint.compute([Self.appendSignature, Self.statSignature])
        #expect(SchemaFingerprint.compute([renamed, Self.statSignature]) != reference)
    }

    @Test("sensitive to a changed access mode")
    func changedAccess() {
        var relaxed = Self.appendSignature
        relaxed.access = .read
        let reference = SchemaFingerprint.compute([Self.appendSignature])
        #expect(SchemaFingerprint.compute([relaxed]) != reference)
    }

    @Test("sensitive to a changed field type")
    func changedFieldType() {
        var mutated = Self.statSignature
        mutated.response = .structure(fields: [
            .init(key: 0, name: "owner", type: .uint),
            .init(key: 1, name: "group", type: .uint),
            .init(key: 2, name: "mode", type: .int),  // was .uint
        ])
        #expect(
            SchemaFingerprint.compute([mutated]) != SchemaFingerprint.compute([Self.statSignature]))
    }

    @Test("sensitive to struct field order (declaration order is hashed)")
    func fieldOrderMatters() {
        var reordered = Self.statSignature
        reordered.response = .structure(fields: [
            .init(key: 1, name: "group", type: .uint),
            .init(key: 0, name: "owner", type: .uint),
            .init(key: 2, name: "mode", type: .uint),
        ])
        #expect(
            SchemaFingerprint.compute([reordered])
                != SchemaFingerprint.compute([Self.statSignature]))
    }

    @Test("sensitive to adding a request stream")
    func addedRequestStream() {
        var streaming = Self.appendSignature
        streaming.requestStream = .structure(fields: [.init(key: 0, name: "line", type: .string)])
        #expect(
            SchemaFingerprint.compute([streaming])
                != SchemaFingerprint.compute([Self.appendSignature]))
    }

    @Test("sensitive to a changed stream element type")
    func changedStreamElement() {
        var stringElements = Self.appendSignature
        stringElements.responseStream = .structure(fields: [
            .init(key: 0, name: "line", type: .string)
        ])
        var intElements = Self.appendSignature
        intElements.responseStream = .structure(fields: [.init(key: 0, name: "line", type: .int)])
        #expect(
            SchemaFingerprint.compute([stringElements]) != SchemaFingerprint.compute([intElements]))
    }

    @Test("request-vs-response stream slots are asymmetric")
    func streamSlotAsymmetry() {
        let element = TypeSchema.structure(fields: [.init(key: 0, name: "line", type: .string)])
        var requestSide = Self.appendSignature
        requestSide.requestStream = element
        var responseSide = Self.appendSignature
        responseSide.responseStream = element
        #expect(
            SchemaFingerprint.compute([requestSide]) != SchemaFingerprint.compute([responseSide]))
    }

    @Test("order-insensitive even for duplicate method names")
    func duplicateNamesOrderInsensitive() {
        // Duplicate names are rejected by the router, but compute is a public API
        // computed independently on both sides; the sort must be a total order or
        // identical sets can fingerprint differently and force spurious discovery.
        var relaxed = Self.appendSignature
        relaxed.access = .read
        let reference = SchemaFingerprint.compute([Self.appendSignature, relaxed])
        #expect(SchemaFingerprint.compute([relaxed, Self.appendSignature]) == reference)
    }

    @Test("empty set hashes to the FNV-1a offset basis")
    func emptySet() {
        #expect(SchemaFingerprint.compute([]) == 0xcbf2_9ce4_8422_2325)
    }

    @Test("golden pinned value guards cross-platform drift")
    func goldenValue() {
        // Pinned once from a verified run; a change here is a wire-protocol
        // break, not a test to update casually.
        let fingerprint = SchemaFingerprint.compute([
            Self.appendSignature, Self.statSignature, Self.listSignature,
        ])
        #expect(fingerprint == 0x4011_1844_3279_fc06)
    }

    static let followSignature = MethodSignature(
        name: "box.follow",
        access: .read,
        request: .structure(fields: [.init(key: 0, name: "entity", type: .string)]),
        response: .structure(fields: [.init(key: 0, name: "total", type: .uint)]),
        responseStream: .structure(fields: [.init(key: 0, name: "line", type: .string)])
    )

    static let importSignature = MethodSignature(
        name: "box.import",
        access: .write,
        request: .structure(fields: [.init(key: 0, name: "entity", type: .string)]),
        response: .structure(fields: [.init(key: 0, name: "count", type: .uint)]),
        requestStream: .structure(fields: [.init(key: 0, name: "line", type: .string)])
    )

    @Test("golden pinned value for a stream-carrying signature set")
    func goldenStreamValue() {
        // Independently computed (Python reference implementation of §9.1's
        // canonical encoding + FNV-1a, cross-validated against the unary golden
        // above). `box.follow` exercises the tag-2 response-stream entry,
        // `box.import` the tag-1 request-stream entry. A change here is a
        // wire-protocol break.
        let fingerprint = SchemaFingerprint.compute([Self.followSignature, Self.importSignature])
        #expect(fingerprint == 0x2a29_3e62_e6fc_e10f)
    }

    // MARK: Named types and descriptions (types amendment)

    static let setSignature = MethodSignature(
        name: "box.set",
        access: .write,
        request: .structure(fields: [
            .init(key: 0, name: "entity", type: .string),
            .init(key: 1, name: "meta", type: .reference("box.LineMeta")),
        ]),
        response: .structure(fields: [.init(key: 0, name: "count", type: .uint)])
    )

    static let priorityDefinition = TypeDefinition(
        name: "box.Priority",
        schema: .enumeration(cases: [.init(name: "low"), .init(name: "high")])
    )

    static let lineMetaDefinition = TypeDefinition(
        name: "box.LineMeta",
        schema: .structure(fields: [
            .init(key: 0, name: "author", type: .string),
            .init(key: 1, name: "priority", type: .reference("box.Priority")),
        ])
    )

    @Test("an empty type table hashes to the pre-types value")
    func emptyTypesMatchLegacy() {
        let signatures = [Self.appendSignature, Self.statSignature]
        #expect(
            SchemaFingerprint.compute(signatures, types: [])
                == SchemaFingerprint.compute(signatures))
    }

    @Test("descriptions never affect the fingerprint")
    func descriptionsNeverHash() {
        var documented = Self.setSignature
        documented.description = "sets a line"
        documented.requestDescription = "what to set"
        documented.responseDescription = "the new count"
        documented.request = .structure(fields: [
            .init(key: 0, name: "entity", type: .string, description: "target entity"),
            .init(key: 1, name: "meta", type: .reference("box.LineMeta")),
        ])
        var documentedPriority = Self.priorityDefinition
        documentedPriority.description = "how urgent"
        documentedPriority.schema = .enumeration(cases: [
            .init(name: "low", description: "whenever"),
            .init(name: "high", description: "wakes the pager"),
        ])
        #expect(
            SchemaFingerprint.compute(
                [documented], types: [documentedPriority, Self.lineMetaDefinition])
                == SchemaFingerprint.compute(
                    [Self.setSignature], types: [Self.priorityDefinition, Self.lineMetaDefinition])
        )
    }

    @Test("the type table is hashed — adding a definition changes the fingerprint")
    func typeTableHashes() {
        let bare = SchemaFingerprint.compute([Self.setSignature])
        let typed = SchemaFingerprint.compute([Self.setSignature], types: [Self.lineMetaDefinition])
        #expect(bare != typed)
    }

    @Test("type definitions are order-insensitive")
    func typeOrderInsensitive() {
        let reference = SchemaFingerprint.compute(
            [Self.setSignature], types: [Self.priorityDefinition, Self.lineMetaDefinition])
        #expect(
            SchemaFingerprint.compute(
                [Self.setSignature], types: [Self.lineMetaDefinition, Self.priorityDefinition])
                == reference
        )
    }

    @Test("names are nominal — renaming a type changes the fingerprint")
    func typeRenameChanges() {
        var renamed = Self.lineMetaDefinition
        renamed.name = "box.LineMetadata"
        #expect(
            SchemaFingerprint.compute([Self.setSignature], types: [renamed])
                != SchemaFingerprint.compute([Self.setSignature], types: [Self.lineMetaDefinition])
        )
    }

    @Test("renaming an enum case changes the fingerprint (case names are wire values)")
    func enumCaseRenameChanges() {
        var renamed = Self.priorityDefinition
        renamed.schema = .enumeration(cases: [.init(name: "low"), .init(name: "urgent")])
        #expect(
            SchemaFingerprint.compute([], types: [renamed])
                != SchemaFingerprint.compute([], types: [Self.priorityDefinition])
        )
    }

    @Test("golden pinned value for a typed signature set")
    func goldenTypedValue() {
        // Independently computed (Python reference implementation of the
        // canonical encoding + FNV-1a, cross-validated against the unary
        // golden above). Exercises tag 11 (enumeration), tag 12 (reference),
        // and the tag-3 type-definition entries. A change here is a
        // wire-protocol break.
        let fingerprint = SchemaFingerprint.compute(
            [Self.setSignature],
            types: [Self.priorityDefinition, Self.lineMetaDefinition]
        )
        #expect(fingerprint == 0x9666_7b70_65cb_b8e4)
    }

    @Test("FNV-1a reference vectors")
    func fnvReference() {
        // Published FNV-1a 64 test vectors.
        #expect(SchemaFingerprint.fnv1a64([]) == 0xcbf2_9ce4_8422_2325)
        #expect(SchemaFingerprint.fnv1a64(Array("a".utf8)) == 0xaf63_dc4c_8601_ec8c)
        #expect(SchemaFingerprint.fnv1a64(Array("foobar".utf8)) == 0x85944171f73967e8)
    }
}

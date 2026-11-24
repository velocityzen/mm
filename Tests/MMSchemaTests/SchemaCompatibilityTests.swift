import MMSchema
import Testing

private typealias Field = TypeSchema.Field

/// The breaks of `reader` reading what `writer` writes, as text.
private func breaks(
    reader: TypeSchema,
    readerTypes: [TypeDefinition] = [],
    writer: TypeSchema,
    writerTypes: [TypeDefinition] = []
) -> [String] {
    TypeSchema.compatibility(
        reader: reader,
        readerTypes: TypeResolver(readerTypes),
        writer: writer,
        writerTypes: TypeResolver(writerTypes)
    ).breaks.map(\.description)
}

private func structure(_ fields: Field...) -> TypeSchema {
    .structure(fields: fields)
}

private func cases(_ names: String...) -> TypeSchema {
    .enumeration(cases: names.map { TypeSchema.EnumCase(name: $0) })
}

@Suite("Schema compatibility: what a reader reads of what a writer writes")
struct SchemaCompatibilityTests {
    private static let record = structure(
        Field(key: 0, name: "id", type: .int),
        Field(key: 1, name: "note", type: .optional(.string))
    )

    @Test("a schema reads itself")
    func identical() {
        #expect(
            TypeSchema.compatibility(reader: Self.record, writer: Self.record) == .compatible
        )
        #expect(breaks(reader: .unknown, writer: .unknown).isEmpty)
    }

    @Test("an optional field only one side declares reads")
    func addedOptionalField() {
        let wider = structure(
            Field(key: 0, name: "id", type: .int),
            Field(key: 1, name: "note", type: .optional(.string)),
            Field(key: 2, name: "tags", type: .optional(.array(.string)))
        )
        #expect(breaks(reader: Self.record, writer: wider).isEmpty)
        #expect(breaks(reader: wider, writer: Self.record).isEmpty)
    }

    @Test("a required field the writer does not write breaks; one only the writer has is skipped")
    func requiredField() {
        let wider = structure(
            Field(key: 0, name: "id", type: .int),
            Field(key: 1, name: "note", type: .optional(.string)),
            Field(key: 2, name: "size", type: .int)
        )
        #expect(
            breaks(reader: wider, writer: Self.record) == [
                "size: required by the reader, not written"
            ]
        )
        #expect(breaks(reader: Self.record, writer: wider).isEmpty)
        // Removing a field the reader requires is the same break.
        let removed = structure(Field(key: 1, name: "note", type: .optional(.string)))
        #expect(
            breaks(reader: Self.record, writer: removed) == [
                "id: required by the reader, not written"
            ]
        )
        // A field the reader holds as optional may go.
        #expect(breaks(reader: removed, writer: Self.record).isEmpty)
    }

    @Test("fields pair by key, then by name, so a rename that keeps the key reads")
    func renamedField() {
        let renamed = structure(
            Field(key: 0, name: "identifier", type: .int),
            Field(key: 1, name: "note", type: .optional(.string))
        )
        #expect(breaks(reader: Self.record, writer: renamed).isEmpty)
        #expect(breaks(reader: renamed, writer: Self.record).isEmpty)
        // A key moved is a field removed and another added.
        let moved = structure(
            Field(key: 5, name: "id", type: .int),
            Field(key: 1, name: "note", type: .optional(.string))
        )
        #expect(
            breaks(reader: Self.record, writer: moved) == [
                "id: required by the reader, not written"
            ]
        )
        // String-keyed fields pair by name.
        let named = structure(Field(key: nil, name: "id", type: .int))
        let renamedByName = structure(Field(key: nil, name: "identifier", type: .int))
        #expect(
            breaks(reader: named, writer: renamedByName) == [
                "id: required by the reader, not written"
            ]
        )
        // A reader finds a keyed field by its name when the writer writes
        // it without a key, never the other way: a keyed writer writes no
        // names.
        let keyed = structure(Field(key: 0, name: "id", type: .int))
        #expect(breaks(reader: keyed, writer: named).isEmpty)
        #expect(
            breaks(reader: keyed, writer: structure(Field(key: nil, name: "id", type: .string)))
                == [
                    "id: read as int, written as string"
                ]
        )
        #expect(breaks(reader: named, writer: keyed) == ["id: required by the reader, not written"])
    }

    @Test("a keyed field whose name reads as another integer pairs by its name, as it travels")
    func numeralNamedField() {
        // The 2026-11-20 nightly pair (MM-334): "0" with key 2 travels
        // under "0", so a reader's `a` moved to key 2 finds nothing there.
        let writer = structure(
            Field(key: 0, name: "a", type: .bool),
            Field(key: 1, name: "a'", type: .bool),
            Field(key: 2, name: "0", type: .bool)
        )
        let rekeyed = structure(
            Field(key: 2, name: "a", type: .bool),
            Field(key: 1, name: "a'", type: .bool)
        )
        #expect(
            breaks(reader: rekeyed, writer: writer) == ["a: required by the reader, not written"]
        )
        // Under another key, "0" still reads it by its name.
        let movedNumeral = structure(Field(key: 7, name: "0", type: .bool))
        #expect(breaks(reader: movedNumeral, writer: writer).isEmpty)
        // A name that is its key's own numeral travels under the key, and a
        // padded one ("05" for key 5) under its name.
        let count = structure(Field(key: 5, name: "count", type: .int))
        #expect(
            breaks(reader: structure(Field(key: 5, name: "5", type: .int)), writer: count).isEmpty
        )
        #expect(
            breaks(reader: structure(Field(key: 5, name: "05", type: .int)), writer: count) == [
                "05: required by the reader, not written"
            ]
        )
    }

    @Test("a changed field type breaks")
    func changedFieldType() {
        let changed = structure(
            Field(key: 0, name: "id", type: .string),
            Field(key: 1, name: "note", type: .optional(.string))
        )
        #expect(
            breaks(reader: Self.record, writer: changed) == ["id: read as int, written as string"]
        )
        #expect(
            breaks(reader: changed, writer: Self.record) == ["id: read as string, written as int"]
        )
        let nested = structure(
            Field(key: 0, name: "id", type: .int),
            Field(key: 1, name: "note", type: .optional(.array(.int)))
        )
        #expect(
            breaks(reader: Self.record, writer: nested) == [
                "note: read as string, written as an array"
            ]
        )
    }

    @Test("a reader may take an optional where the writer always writes a value, not the reverse")
    func optionality() {
        let optional = structure(Field(key: 0, name: "id", type: .optional(.int)))
        let required = structure(Field(key: 0, name: "id", type: .int))
        #expect(breaks(reader: optional, writer: required).isEmpty)
        #expect(
            breaks(reader: required, writer: optional) == [
                "id: required by the reader, optional for the writer"
            ]
        )
        // Optionals nest, on the wire, into one.
        let twice = structure(Field(key: 0, name: "id", type: .optional(.optional(.int))))
        #expect(breaks(reader: optional, writer: twice).isEmpty)
        #expect(breaks(reader: twice, writer: optional).isEmpty)
    }

    @Test("a case only one side declares reads; a case on each side the other lacks breaks")
    func enumerationCases() {
        let levels = cases("low", "high")
        #expect(breaks(reader: levels, writer: cases("low", "high", "urgent")).isEmpty)
        #expect(breaks(reader: cases("low", "high", "urgent"), writer: levels).isEmpty)
        #expect(breaks(reader: levels, writer: cases("high", "low")).isEmpty)
        #expect(
            breaks(reader: levels, writer: cases("low", "urgent")) == [
                #"renamed or replaced cases: reads "high", writes "urgent""#
            ]
        )
    }

    @Test("union cases follow the enumeration rule, and a shared case's fields the structure rule")
    func unionCases() {
        let moved = TypeSchema.UnionCase(
            name: "moved",
            fields: [Field(key: 0, name: "to", type: .string)]
        )
        let gone = TypeSchema.UnionCase(name: "gone")
        let union = TypeSchema.union(cases: [moved, gone])
        #expect(breaks(reader: union, writer: .union(cases: [moved])).isEmpty)
        #expect(breaks(reader: .union(cases: [moved]), writer: union).isEmpty)
        #expect(
            breaks(
                reader: union,
                writer: .union(cases: [moved, TypeSchema.UnionCase(name: "lost")])
            )
                == [#"renamed or replaced cases: reads "gone", writes "lost""#]
        )
        // A case with no fields leaves its fields map out, which a reader
        // reads as a map of no fields: an optional field reads as absent,
        // and a required one breaks.
        let goneSince = TypeSchema.UnionCase(
            name: "gone",
            fields: [Field(key: 0, name: "since", type: .optional(.timestamp))]
        )
        #expect(breaks(reader: .union(cases: [moved, goneSince]), writer: union).isEmpty)
        #expect(breaks(reader: union, writer: .union(cases: [moved, goneSince])).isEmpty)
        let goneAt = TypeSchema.UnionCase(
            name: "gone",
            fields: [Field(key: 0, name: "at", type: .timestamp)]
        )
        #expect(
            breaks(reader: .union(cases: [moved, goneAt]), writer: union) == [
                "(gone).at: required by the reader, not written"
            ]
        )
        #expect(breaks(reader: union, writer: .union(cases: [moved, goneAt])).isEmpty)
        let movedElsewhere = TypeSchema.UnionCase(
            name: "moved",
            fields: [Field(key: 0, name: "to", type: .uuid)]
        )
        #expect(
            breaks(reader: union, writer: .union(cases: [movedElsewhere, gone])) == [
                "(moved).to: read as string, written as uuid"
            ]
        )
    }

    @Test("the writer must keep every rule the reader requires")
    func constraints() {
        func limit(_ constraints: TypeSchema.Constraints?) -> TypeSchema {
            structure(Field(key: 0, name: "limit", type: .int, constraints: constraints))
        }
        let wide = TypeSchema.Constraints(minimum: .integer(1), maximum: .integer(1_000))
        let narrow = TypeSchema.Constraints(minimum: .integer(1), maximum: .integer(100))
        #expect(breaks(reader: limit(wide), writer: limit(narrow)).isEmpty)
        #expect(breaks(reader: limit(nil), writer: limit(narrow)).isEmpty)
        #expect(
            breaks(reader: limit(narrow), writer: limit(wide)) == [
                "limit: the reader requires a maximum of 100, the writer keeps a maximum of 1000"
            ]
        )
        #expect(
            breaks(reader: limit(narrow), writer: limit(nil)) == [
                "limit: the reader requires a minimum of 1, the writer keeps no minimum",
                "limit: the reader requires a maximum of 100, the writer keeps no maximum",
            ]
        )
        func slug(_ constraints: TypeSchema.Constraints?) -> TypeSchema {
            structure(Field(key: 0, name: "slug", type: .string, constraints: constraints))
        }
        let pattern = TypeSchema.Constraints(maximumLength: 8, pattern: "[a-z]+")
        #expect(breaks(reader: slug(nil), writer: slug(pattern)).isEmpty)
        #expect(
            breaks(reader: slug(pattern), writer: slug(TypeSchema.Constraints(maximumLength: 4)))
                == ["slug: the reader requires the pattern [a-z]+, the writer does not keep it"]
        )
        #expect(
            breaks(reader: slug(TypeSchema.Constraints(minimumLength: 2)), writer: slug(pattern))
                == [
                    "slug: the reader requires a minimum length of 2, the writer keeps no minimum length"
                ]
        )
        // A named scalar's rules hold beside the field's.
        let named = [
            TypeDefinition(
                name: "box.Slug",
                schema: .string,
                constraints: TypeSchema.Constraints(pattern: "[a-z]+")
            )
        ]
        let byName = structure(Field(key: 0, name: "slug", type: .reference("box.Slug")))
        #expect(breaks(reader: slug(nil), writer: byName, writerTypes: named).isEmpty)
        #expect(
            breaks(reader: byName, readerTypes: named, writer: slug(nil)) == [
                "slug: the reader requires the pattern [a-z]+, the writer does not keep it"
            ]
        )
    }

    @Test("an integer and a floating bound order exactly below 2^53, and not past it")
    func mixedBounds() {
        func ratio(_ minimum: TypeSchema.Bound) -> TypeSchema {
            structure(
                Field(
                    key: 0,
                    name: "ratio",
                    type: .double,
                    constraints: TypeSchema.Constraints(minimum: minimum)
                )
            )
        }
        #expect(breaks(reader: ratio(.integer(1)), writer: ratio(.floating(1.5))).isEmpty)
        #expect(breaks(reader: ratio(.floating(0.5)), writer: ratio(.integer(1))).isEmpty)
        #expect(
            breaks(reader: ratio(.floating(1.5)), writer: ratio(.integer(1))) == [
                "ratio: the reader requires a minimum of 1.5, the writer keeps a minimum of 1"
            ]
        )
        // 2^53 + 1 and 2^53 are one double: no order.
        #expect(
            breaks(reader: ratio(.integer(1 << 53)), writer: ratio(.floating(0x1p53 + 2))).count
                == 1
        )
        func count(_ rules: TypeSchema.Constraints) -> TypeSchema {
            structure(Field(key: 0, name: "count", type: .int, constraints: rules))
        }
        // An int checks a floating bound through `Double`, where 2^53 + 1
        // is 2^53, and an integer bound exactly: the writer keeps 2^53 + 1
        // under a maximum of 2^53.0, the reader's maximum of 2^53 refuses it.
        #expect(
            breaks(
                reader: count(TypeSchema.Constraints(maximum: .integer(1 << 53))),
                writer: count(TypeSchema.Constraints(maximum: .floating(0x1p53)))
            ).count == 1
        )
        // And the writer keeps 2^53 above a minimum of 2^53.0, which the
        // reader's minimum of 2^53 + 1 refuses.
        #expect(
            breaks(
                reader: count(TypeSchema.Constraints(minimum: .integer((1 << 53) + 1))),
                writer: count(TypeSchema.Constraints(minimum: .floating(0x1p53)))
            ).count == 1
        )
    }

    @Test("references resolve through each side's own types; names are not compared")
    func references() {
        let priority = cases("low", "high")
        let reader = structure(Field(key: 0, name: "level", type: .reference("box.Priority")))
        let readerTypes = [TypeDefinition(name: "box.Priority", schema: priority)]
        // The writer renamed the type and kept its shape.
        let writer = structure(Field(key: 0, name: "level", type: .reference("box.Level")))
        let writerTypes = [TypeDefinition(name: "box.Level", schema: priority)]
        #expect(
            breaks(
                reader: reader,
                readerTypes: readerTypes,
                writer: writer,
                writerTypes: writerTypes
            )
            .isEmpty
        )
        #expect(
            breaks(
                reader: reader,
                readerTypes: readerTypes,
                writer: structure(Field(key: 0, name: "level", type: priority))
            ).isEmpty
        )
        // A type one side does not define cannot be judged.
        #expect(
            breaks(reader: reader, writer: writer, writerTypes: writerTypes) == [
                #"level: the reader has no type "box.Priority""#
            ]
        )
        // One name neither side defines is the same unknown type.
        #expect(breaks(reader: reader, writer: reader).isEmpty)
        let loop = [TypeDefinition(name: "box.Priority", schema: .reference("box.Priority"))]
        #expect(
            breaks(reader: reader, readerTypes: loop, writer: reader, writerTypes: readerTypes) == [
                #"level: the reader's type "box.Priority" resolves to itself"#
            ]
        )
    }

    @Test("a recursive type is compared once around its loop")
    func recursion() {
        func node(_ value: TypeSchema) -> [TypeDefinition] {
            [
                TypeDefinition(
                    name: "box.Node",
                    schema: structure(
                        Field(key: 0, name: "value", type: value),
                        Field(key: 1, name: "next", type: .optional(.reference("box.Node")))
                    )
                )
            ]
        }
        let root = TypeSchema.reference("box.Node")
        #expect(
            breaks(reader: root, readerTypes: node(.int), writer: root, writerTypes: node(.int))
                .isEmpty
        )
        #expect(
            breaks(reader: root, readerTypes: node(.int), writer: root, writerTypes: node(.string))
                == [
                    "value: read as int, written as string"
                ]
        )
    }

    /// Forty types, each holding the next twice: 2^40 paths to the last,
    /// which a walk that judged a type at every path never finishes.
    @Test(
        "a type many positions share is judged once, its breaks named at the first",
        .timeLimit(.minutes(1))
    )
    func sharedType() {
        func chain(_ last: TypeSchema) -> [TypeDefinition] {
            (0..<40).map { level in
                let next = TypeSchema.reference("chain.Level\(level + 1)")
                return TypeDefinition(
                    name: "chain.Level\(level)",
                    schema: structure(
                        Field(key: 0, name: "left", type: next),
                        Field(key: 1, name: "right", type: next)
                    )
                )
            } + [TypeDefinition(name: "chain.Level40", schema: last)]
        }
        let root = TypeSchema.reference("chain.Level0")
        #expect(
            breaks(reader: root, readerTypes: chain(.int), writer: root, writerTypes: chain(.int))
                .isEmpty
        )
        let first = Array(repeating: "left", count: 40).joined(separator: ".")
        #expect(
            breaks(
                reader: root,
                readerTypes: chain(.int),
                writer: root,
                writerTypes: chain(.string)
            ) == [
                "\(first): read as int, written as string"
            ]
        )
    }

    @Test("paths name array elements, map keys and values")
    func paths() {
        let reader = structure(
            Field(key: 0, name: "rows", type: .array(.int)),
            Field(key: 1, name: "index", type: .map(key: .string, value: .int))
        )
        let writer = structure(
            Field(key: 0, name: "rows", type: .array(.uint)),
            Field(key: 1, name: "index", type: .map(key: .int, value: .bool))
        )
        #expect(
            breaks(reader: reader, writer: writer) == [
                "rows[]: read as int, written as uint",
                "index[key]: read as string, written as int",
                "index[value]: read as int, written as bool",
            ]
        )
    }

    @Test("a kind this peer does not know matches only itself")
    func unknownKind() {
        // A later peer added a uuid field; this peer decodes the kind as unknown.
        let older = structure(Field(key: 0, name: "id", type: .int))
        let added = structure(
            Field(key: 0, name: "id", type: .int),
            Field(key: 1, name: "order", type: .optional(.unknown))
        )
        #expect(breaks(reader: older, writer: added).isEmpty)
        let changed = structure(Field(key: 0, name: "id", type: .unknown))
        #expect(
            breaks(reader: older, writer: changed) == [
                "id: read as int, written as a kind this peer does not know"
            ]
        )
    }

    @Test("a type definition is judged with its own rules, paths from its name")
    func definitions() {
        let local = TypeDefinition(
            name: "box.Limit",
            schema: .int,
            constraints: TypeSchema.Constraints(maximum: .integer(10))
        )
        var served = local
        served.constraints = nil
        #expect(
            TypeDefinition.compatibility(
                reader: local,
                readerTypes: TypeResolver([local]),
                writer: served,
                writerTypes: TypeResolver([served])
            )
                == .breaking([
                    SchemaBreak(
                        path: "box.Limit",
                        reason: "the reader requires a maximum of 10, the writer keeps no maximum"
                    )
                ])
        )
    }
}

@Suite("Method compatibility: the server reads requests, the client responses")
struct MethodCompatibilityTests {
    private static func method(
        access: AccessMode = .read,
        request: TypeSchema = .structure(fields: [Field(key: 0, name: "id", type: .int)]),
        response: TypeSchema = .structure(fields: [Field(key: 0, name: "ok", type: .bool)]),
        requestStream: TypeSchema? = nil,
        errors: TypeSchema? = nil,
        target: [EntityPattern]? = nil
    ) -> MethodSignature {
        MethodSignature(
            name: "box.get",
            access: access,
            request: request,
            response: response,
            requestStream: requestStream,
            errors: errors,
            target: target
        )
    }

    private static func verdict(client: MethodSignature, server: MethodSignature) -> [String] {
        MethodSignature.compatibility(
            client: client,
            clientTypes: TypeResolver([]),
            server: server,
            serverTypes: TypeResolver([])
        ).breaks.map(\.description)
    }

    @Test(
        "a field the server adds to the request must be optional; one it adds to the response need not be"
    )
    func directions() {
        let request = TypeSchema.structure(fields: [
            Field(key: 0, name: "id", type: .int),
            Field(key: 1, name: "size", type: .int),
        ])
        let response = TypeSchema.structure(fields: [
            Field(key: 0, name: "ok", type: .bool),
            Field(key: 1, name: "size", type: .int),
        ])
        #expect(
            Self.verdict(client: Self.method(), server: Self.method(request: request)) == [
                "request.size: required by the reader, not written"
            ]
        )
        #expect(Self.verdict(client: Self.method(request: request), server: Self.method()).isEmpty)
        #expect(
            Self.verdict(client: Self.method(), server: Self.method(response: response)).isEmpty
        )
        #expect(
            Self.verdict(client: Self.method(response: response), server: Self.method()) == [
                "response.size: required by the reader, not written"
            ]
        )
    }

    @Test("a changed access breaks")
    func access() {
        #expect(
            Self.verdict(client: Self.method(access: .read), server: Self.method(access: .all)) == [
                "access: the client expects r--, the server requires rwx"
            ]
        )
    }

    @Test("a target the server widens reads; one it narrows breaks, naming what it refuses")
    func targets() {
        func verdict(_ client: [EntityPattern]?, _ server: [EntityPattern]?) -> [String] {
            Self.verdict(client: Self.method(target: client), server: Self.method(target: server))
        }
        #expect(verdict(["journal.notes"], ["journal", "journal.*"]).isEmpty)
        #expect(verdict(["tenants.acme.journal"], ["tenants.*.journal"]).isEmpty)
        // Each pattern is taken by one of the server's.
        #expect(verdict(["journal.a", "journal.b.c"], ["journal.*"]).isEmpty)
        #expect(
            verdict(["journal.*", "system"], ["journal.notes", "system"]) == [
                "target: the client targets journal.*, the server only journal.notes, system"
            ]
        )
        #expect(
            verdict(["tenants.*.journal"], ["tenants.acme.journal"]) == [
                "target: the client targets tenants.*.journal, the server only tenants.acme.journal"
            ]
        )
        // A pattern of one more depth and one entity of that depth leave
        // the rest of that depth out.
        #expect(
            verdict(["journal.*"], ["journal.*.*", "journal.notes"]) == [
                "target: the client targets journal.*, the server only journal.*.*, journal.notes"
            ]
        )
        // No pattern but root's own takes root.
        #expect(
            verdict([.root], ["*"]) == ["target: the client targets (root), the server only *"]
        )
        #expect(
            verdict(["journal"], []) == ["target: the client targets journal, the server no entity"]
        )
    }

    @Test("no target restricts nothing")
    func absentTargets() {
        func verdict(_ client: [EntityPattern]?, _ server: [EntityPattern]?) -> [String] {
            Self.verdict(client: Self.method(target: client), server: Self.method(target: server))
        }
        #expect(verdict(nil, nil).isEmpty)
        #expect(verdict(["journal.*"], nil).isEmpty)
        #expect(verdict([.root], nil).isEmpty)
        #expect(verdict(nil, [.all, .root]).isEmpty)
        #expect(
            verdict(nil, ["journal.*"]) == [
                "target: the client targets any entity, the server only journal.*"
            ]
        )
        #expect(
            verdict(nil, [.all]) == ["target: the client targets any entity, the server only *"]
        )
    }

    @Test("a stream only one side declares breaks")
    func streams() {
        let lines = TypeSchema.structure(fields: [Field(key: 0, name: "line", type: .string)])
        #expect(
            Self.verdict(client: Self.method(), server: Self.method(requestStream: lines)) == [
                "request stream: declared by the server only"
            ]
        )
        #expect(
            Self.verdict(client: Self.method(requestStream: lines), server: Self.method()) == [
                "request stream: declared by the client only"
            ]
        )
    }

    @Test("an error case the server adds reads; one it renames breaks")
    func errors() {
        let busy = TypeSchema.union(cases: [TypeSchema.UnionCase(name: "busy")])
        let more = TypeSchema.union(cases: [
            TypeSchema.UnionCase(name: "busy"), TypeSchema.UnionCase(name: "gone"),
        ])
        #expect(
            Self.verdict(client: Self.method(errors: busy), server: Self.method(errors: more))
                .isEmpty
        )
        #expect(Self.verdict(client: Self.method(), server: Self.method(errors: busy)).isEmpty)
        #expect(Self.verdict(client: Self.method(errors: busy), server: Self.method()).isEmpty)
        let renamed = TypeSchema.union(cases: [TypeSchema.UnionCase(name: "overloaded")])
        #expect(
            Self.verdict(client: Self.method(errors: busy), server: Self.method(errors: renamed))
                == [
                    #"errors: renamed or replaced cases: reads "busy", writes "overloaded""#
                ]
        )
    }
}

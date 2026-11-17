// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    import HegelTesting
    @testable import MMSchema
    import MMWire
    import Testing

    /// One entry of a drawn fields block: a field, pinned or not, or a
    /// reservation of keys and names.
    enum DrawnBlockEntry: Sendable {
        case field(pinnedKey: Int?, name: String)
        case reserved(keys: [Int], names: [String])

        /// The entry as the DSL writes it.
        var source: String {
            switch self {
                case .field(let pinnedKey?, let name): #"Field(\#(pinnedKey), "\#(name)", .int)"#
                case .field(nil, let name): #"Field("\#(name)", .int)"#
                case .reserved(let keys, let names):
                    "Reserved(\((keys.map { "\($0)" } + names.map { "\"\($0)\"" }).joined(separator: ", ")))"
            }
        }

        /// The entry as the runtime DSL builds it.
        var runtime: [Field] {
            switch self {
                case .field(let pinnedKey?, let name): [Field(pinnedKey, name, .int)]
                case .field(nil, let name): [Field(name, .int)]
                case .reserved(let keys, let names):
                    SchemaFieldsBuilder.buildExpression(
                        FieldReservation(keys: keys, names: names)
                    )
            }
        }
    }

    /// A fields block with a contiguous run of its entries drawn into a
    /// group, and sometimes a run of the group's entries into an inner
    /// group the group uses.
    struct GroupedBlock: Sendable {
        var entries: [DrawnBlockEntry]
        /// The group's entries.
        var group: Range<Int>
        /// The inner group's entries, inside `group`; nil when the group
        /// uses none.
        var inner: Range<Int>?

        /// The fields in order, as `fieldKeys` takes them, and the block's
        /// reservations.
        func keyed(_ range: Range<Int>) -> Result<[Int], FieldKeyConflict> {
            var fields: [(pinnedKey: Int?, name: String)] = []
            var keys: Set<Int> = []
            var names: Set<String> = []
            for entry in self.entries[range] {
                switch entry {
                    case .field(let pinnedKey, let name): fields.append((pinnedKey, name))
                    case .reserved(let reservedKeys, let reservedNames):
                        keys.formUnion(reservedKeys)
                        names.formUnion(reservedNames)
                }
            }
            return fieldKeys(for: fields, reservedKeys: keys, reservedNames: names)
        }

        /// The names of the fields in `range`, in order.
        func names(_ range: Range<Int>) -> [String] {
            self.entries[range].compactMap { entry in
                if case .field(_, let name) = entry { name } else { nil }
            }
        }
    }

    enum SchemaCompositionGenerators {
        static let pins: [Int] = [0, 1, 2, 3, 7]

        /// A block of up to six fields, each pinned or not to a key no other
        /// field pins, and up to two reservations of keys no field pins and
        /// names no field takes, anywhere among them: a block every keying
        /// accepts, so a property that builds it never traps. A run of its
        /// entries, often empty or all of them, is the group.
        static let blocks: Gen<GroupedBlock> = Gen { tc in
            let names = try FingerprintGenerators.shuffled(["a", "b", "c", "d", "e", "f"], tc)
                .prefix(try tc.draw(.int(in: 0...6)))
            var pinned: Set<Int> = []
            var entries: [DrawnBlockEntry] = []
            for name in names {
                let pin = try tc.draw(Gen<Int?>.optional(.element(of: pins)))
                if let pin, pinned.insert(pin).inserted {
                    entries.append(.field(pinnedKey: pin, name: name))
                } else {
                    entries.append(.field(pinnedKey: nil, name: name))
                }
            }
            let free = pins.filter { !pinned.contains($0) }
            for _ in 0..<(try tc.draw(.int(in: 0...2))) {
                let keys = try tc.draw(Gen<[Int]>.array(of: .element(of: free + [9]), count: 0...2))
                let reservedNames = try tc.draw(
                    Gen<[String]>.array(
                        of: .element(of: ["old", "gone"]),
                        count: keys.isEmpty ? 1...2 : 0...1
                    )
                )
                let at = try tc.draw(.int(in: 0...entries.count))
                entries.insert(
                    .reserved(
                        keys: Array(Set(keys)).sorted(),
                        names: Array(Set(reservedNames)).sorted()
                    ),
                    at: at
                )
            }
            let group = try tc.draw(run(in: 0..<entries.count))
            let inner = try tc.draw(.optional(run(in: group)))
            return GroupedBlock(entries: entries, group: group, inner: inner)
        }

        /// A run of the indices in `range`: any, the empty one at the start,
        /// or all of them.
        static func run(in range: Range<Int>) -> Gen<Range<Int>> {
            .oneOf(
                Gen { tc in
                    let first = try tc.draw(.int(in: range.lowerBound...range.upperBound))
                    let last = try tc.draw(.int(in: first...range.upperBound))
                    return first..<last
                },
                .just(range.lowerBound..<range.lowerBound),
                .just(range)
            )
        }
    }

    /// One step down a part: into its assembly's base, into one of its
    /// assembly's other parts, or into its spare.
    enum PartStep: Sendable, Equatable {
        case base
        case part(Int)
        case spare

        /// The steps `part` offers: one for each part it holds.
        static func offered(by part: Catalog.Part) -> [PartStep] {
            var steps: [PartStep] = []
            if let assembly = part.assembly {
                steps.append(.base)
                steps += assembly.parts.indices.map(PartStep.part)
            }
            if part.spare.part != nil {
                steps.append(.spare)
            }
            return steps
        }

        /// Whether the step goes through the part's boxed assembly.
        var isThroughAssembly: Bool {
            self != .spare
        }
    }

    /// The change made to the part the steps lead to.
    enum PartChange: Sendable {
        case name(String)
        case assembly(Catalog.Assembly?)
        case spare(Catalog.Part?)
    }

    /// The part `step` leads to from `part`. The step is one `part` offers.
    func following(_ step: PartStep, from part: Catalog.Part) -> Catalog.Part {
        switch step {
            case .base: part.assembly!.base
            case .part(let index): part.assembly!.parts[index]
            case .spare: part.spare.part!
        }
    }

    /// Follows `steps` down `part`, each one the part it reaches offers,
    /// and makes `change` to the part they lead to.
    func changing(
        _ part: inout Catalog.Part,
        along steps: ArraySlice<PartStep>,
        by change: PartChange
    ) {
        guard let step = steps.first else {
            switch change {
                case .name(let name): part.name = name
                case .assembly(let assembly): part.assembly = assembly
                case .spare(let spare): part.spare.part = spare
            }
            return
        }
        switch step {
            case .base: changing(&part.assembly!.base, along: steps.dropFirst(), by: change)
            case .part(let index):
                changing(&part.assembly!.parts[index], along: steps.dropFirst(), by: change)
            case .spare: changing(&part.spare.part!, along: steps.dropFirst(), by: change)
        }
    }

    /// Whether two parts hold the same values, compared field by field
    /// without the generated equality.
    func sameParts(_ first: Catalog.Part, _ second: Catalog.Part) -> Bool {
        guard first.name == second.name else { return false }
        switch (first.spare.part, second.spare.part) {
            case (nil, nil): break
            case (let one?, let other?): guard sameParts(one, other) else { return false }
            default: return false
        }
        switch (first.assembly, second.assembly) {
            case (nil, nil): return true
            case (let one?, let other?):
                return sameParts(one.base, other.base) && one.parts.count == other.parts.count
                    && zip(one.parts, other.parts).allSatisfy { sameParts($0, $1) }
            default: return false
        }
    }

    @Suite("Schema composition properties", .hegel, .offTheCooperativePool)
    struct SchemaCompositionProperties {
        /// A fields block that uses a field group keys its fields as the
        /// block with the group's fields written in the group's place: a
        /// group in a group too, and a group with pinned fields and
        /// reservations.
        ///
        /// Mutation check: a group's fields put at the end of the block,
        /// or keyed as a block of their own, fail here.
        @Test
        func aGroupKeysItsFieldsWhereItIsUsed() throws {
            try property(
                reaching: ["a field after the group", "a group inside a group"],
                reachingAfter: [
                    "a pinned field in the group": 1_000, "a reservation in the group": 1_000,
                ]
            ) { tc in
                let block = try #draw(SchemaCompositionGenerators.blocks, from: tc)
                try recordShape(of: block, in: tc)
                let entries = block.entries.map(\.runtime)
                let before = Array(entries[..<block.group.lowerBound].joined())
                let after = Array(entries[block.group.upperBound...].joined())
                let group: FieldGroup
                if let inner = block.inner {
                    let innerGroup = FieldGroup { Array(entries[inner].joined()) }
                    let first = Array(entries[block.group.lowerBound..<inner.lowerBound].joined())
                    let last = Array(entries[inner.upperBound..<block.group.upperBound].joined())
                    group = FieldGroup {
                        first
                        innerGroup
                        last
                    }
                } else {
                    group = FieldGroup { Array(entries[block.group].joined()) }
                }
                #expect(
                    Fields {
                        before
                        group
                        after
                    } == Fields { Array(entries.joined()) }
                )
            }
        }

        /// `#schema` keys a fields block that uses a field group as the
        /// runtime keys the block with the group's fields written in the
        /// group's place, and keys a block holding only the group as the
        /// runtime keys the group's fields alone: a group in a group too,
        /// and a group with pinned fields and reservations.
        ///
        /// Mutation check: the macro reading a group's statements without
        /// the groups it uses, or leaving a use of a group out, fails here.
        @Test
        func theMacroKeysAGroupAsTheRuntimeDoes() throws {
            try property(
                reaching: ["a field after the group", "a group inside a group"],
                reachingAfter: [
                    "a pinned field in the group": 1_000, "a reservation in the group": 1_000,
                ]
            ) { tc in
                let block = try #draw(SchemaCompositionGenerators.blocks, from: tc)
                try recordShape(of: block, in: tc)
                func lines(_ range: Range<Int>) -> [String] {
                    block.entries[range].map(\.source)
                }
                var declarations: [String] = []
                var groupLines = lines(block.group)
                if let inner = block.inner {
                    declarations.append(
                        "let inner = FieldGroup {\n\(lines(inner).joined(separator: "\n"))\n}"
                    )
                    groupLines =
                        lines(block.group.lowerBound..<inner.lowerBound) + ["inner"]
                        + lines(inner.upperBound..<block.group.upperBound)
                }
                declarations.append(
                    "let group = FieldGroup {\n\(groupLines.joined(separator: "\n"))\n}"
                )
                let requestLines =
                    lines(0..<block.group.lowerBound) + ["group"]
                    + lines(block.group.upperBound..<block.entries.count)
                let source = """
                    #schema("box") {
                        \(declarations.joined(separator: "\n"))
                        Call("put") {
                            Access(.write)
                            Request {
                                \(requestLines.joined(separator: "\n"))
                            }
                            Response {
                                group
                            }
                        }
                    }
                    """
                try tc.note(source)
                guard case .success(let expansion) = schemaExpansion(source) else {
                    Issue.record(
                        "#schema refuses a block the runtime keys: \(schemaExpansion(source))"
                    )
                    return
                }
                // The request's struct comes first, then the response's.
                let parts = expansion.components(separatedBy: "public struct PutResponse")
                try #require(parts.count == 2)
                let request = try block.keyed(0..<block.entries.count).get()
                for (name, key) in zip(block.names(0..<block.entries.count), request) {
                    #expect(
                        parts[0].contains(#"TypeSchema.Field(key: \#(key), name: "\#(name)""#),
                        "request field \(name) is not keyed \(key)"
                    )
                }
                let response = try block.keyed(block.group).get()
                for (name, key) in zip(block.names(block.group), response) {
                    #expect(
                        parts[1].contains(#"TypeSchema.Field(key: \#(key), name: "\#(name)""#),
                        "response field \(name) is not keyed \(key)"
                    )
                }
                #expect(
                    parts[1].components(separatedBy: "TypeSchema.Field(key:").count - 1
                        == response.count
                )
            }
        }

        /// A change to a copy of a part, at any depth of parts held through
        /// boxed fields, never reaches the part: it keeps its bytes. The
        /// copy holds exactly the change: it equals, and hashes as, a part
        /// decoded from the part's bytes with the same change made. And the
        /// generated equality agrees with the parts' values.
        ///
        /// Mutation check: a box that copies share and change in place, an
        /// equality that ignores a boxed field, or a hash of the box rather
        /// than its value, fails here.
        @Test
        func aChangeToACopyNeverReachesTheOriginal() throws {
            try property(
                reaching: ["changed through an assembly", "changed through a spare"],
                reachingAfter: ["changed two parts down": 1_000]
            ) { tc in
                let shape = try #draw(CatalogGenerators.shapes, from: tc)
                let generators = CatalogGenerators(shape)
                // A part that may hold others itself, so most walks have
                // somewhere to go.
                let part = try #draw(
                    Gen { tc in
                        try Catalog.Part(
                            name: tc.draw(generators.text),
                            assembly: tc.draw(.optional(generators.assembly)),
                            spare: .init(part: tc.draw(.optional(generators.part)))
                        )
                    },
                    from: tc
                )
                // Each step is one of those the part it reaches offers, and the
                // walk stops anywhere: often at the part itself.
                var steps: [PartStep] = []
                var reached = part
                while case let offered = PartStep.offered(by: reached), !offered.isEmpty,
                    let step = try tc.draw(
                        Gen<PartStep?>.optional(.element(of: offered)),
                        named: "step"
                    )
                {
                    steps.append(step)
                    reached = following(step, from: reached)
                }
                let change = try #draw(
                    Gen<PartChange>.oneOf(
                        generators.text.map(PartChange.name),
                        Gen<Catalog.Assembly?>.optional(generators.assembly).map(
                            PartChange.assembly
                        ),
                        Gen<Catalog.Part?>.optional(generators.part).map(PartChange.spare)
                    ),
                    from: tc
                )
                let bytes = try encodedThroughGeneratedCode(part).get()
                var copy = part
                changing(&copy, along: steps[...], by: change)
                if steps.contains(where: \.isThroughAssembly) {
                    try tc.event("changed through an assembly")
                }
                if steps.contains(.spare) {
                    try tc.event("changed through a spare")
                }
                if steps.count >= 2 {
                    try tc.event("changed two parts down")
                }
                #expect(encodedThroughGeneratedCode(part) == .success(bytes))
                var fresh = try decodedThroughGeneratedCode(Catalog.Part.self, from: bytes).get()
                #expect(fresh == part)
                changing(&fresh, along: steps[...], by: change)
                #expect(fresh == copy)
                #expect(fresh.hashValue == copy.hashValue)
                #expect((copy == part) == sameParts(copy, part))
            }
        }
    }

    /// Records which shapes a drawn grouped block takes, for the statistics
    /// report (`HEGEL_STATISTICS=1`).
    func recordShape(of block: GroupedBlock, in tc: TestCase) throws {
        let groupEntries = block.entries[block.group]
        if groupEntries.contains(where: { if case .field(_?, _) = $0 { true } else { false } }) {
            try tc.event("a pinned field in the group")
        }
        if groupEntries.contains(where: { if case .reserved = $0 { true } else { false } }) {
            try tc.event("a reservation in the group")
        }
        if !block.names(block.group.upperBound..<block.entries.count).isEmpty {
            try tc.event("a field after the group")
        }
        if block.inner != nil {
            try tc.event("a group inside a group")
        }
    }

#endif

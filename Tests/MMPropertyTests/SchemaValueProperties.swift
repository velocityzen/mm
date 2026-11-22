// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    import HegelTesting
    import MMSchema
    import Testing

    @Suite("Schema value properties", .hegel)
    struct SchemaValueProperties {
        /// Every generated value fits its schema: `validated` gives it back
        /// unchanged, strings by their bytes and doubles by bit pattern. So
        /// the generator the other schema value properties build on makes
        /// canonical values, and `validated` takes every canonical value a
        /// schema can describe: each scalar kind at its edges, absent, null
        /// and present optional fields, arrays and maps empty and not,
        /// integer map keys, union cases with and without fields, reference
        /// chains, recursive definitions, a shadowed definition, and
        /// anything at all in an `.unknown` slot.
        ///
        /// Mutation check: `validated` refusing null in an optional slot,
        /// a non-finite double, `Int64.min` or a `uint` past `Int64.max`;
        /// reading a date or a timestamp as a datetime; requiring an
        /// optional field; giving a union case without fields an empty
        /// `fields` member; reading an integer map key as unsigned;
        /// accepting only an enumeration's first case; dropping an
        /// `.unknown` slot's value; or the resolver following only one
        /// reference or letting a later duplicate definition win, fails
        /// here. Each needs its slot at an edge, so a 100-case run catches
        /// most of them and a 1,000-case run catches every one.
        @Test
        func generatedValuesValidateToThemselves() throws {
            try property(
                reaching: ["a shadowed definition", "an optional field left out"],
                reachingAfter: [
                    "a bool": 1_000, "a date": 1_000, "a datetime": 1_000, "a double": 1_000,
                    "a float": 1_000, "a later enumeration case": 1_000,
                    "a map keyed by strings": 1_000, "a reference chain": 1_000, "a string": 1_000,
                    "a timestamp": 1_000, "a duration": 1_000, "a uint": 1_000, "a uuid": 1_000,
                    "a union case with fields": 1_000,
                    "a union case without fields": 1_000, "a value four levels deep": 1_000,
                    "an array with items": 1_000, "an empty array": 1_000, "an empty map": 1_000,
                    "an empty structure": 1_000, "an int": 1_000,
                    "an optional field set to null": 1_000, "an unknown slot": 1_000,
                    "bytes": 1_000, "null in an optional slot": 1_000,
                    "the first enumeration case": 1_000,
                ]
            ) { tc in
                var policy = try #draw(
                    SchemaValueGenerators.policies(unknownSlots: true),
                    from: tc
                )
                // A quarter of the cases are about maps, a quarter about
                // arrays, and a quarter about references, chains and
                // recursive definitions among them.
                let focus = try #draw(
                    Gen<SchemaValueFocus?>.element(of: [nil, .maps, .arrays, .references]),
                    from: tc
                )
                if let focus { policy.focus(on: focus) }
                let fitting = try #draw(SchemaValueGenerators.fitting(policy), from: tc)
                for label in reachLabels(of: fitting).sorted() {
                    try tc.event(label)
                }
                if policy.shadowedDefinition, !fitting.definitions.isEmpty {
                    try tc.event("a shadowed definition")
                }
                switch fitting.value.validated(against: fitting.schema, resolver: fitting.resolver)
                {
                    case .success(let canonical):
                        #expect(
                            identical(canonical, fitting.value),
                            "validated changed the value to \(canonical)"
                        )
                    case .failure(let error):
                        Issue.record("a generated value does not fit: \(error)")
                }
            }
        }

        /// A loose form of a canonical value validates to that value, and
        /// validating the result again changes nothing. The loose forms are
        /// what JSON input brings: a number in another kind that holds it
        /// exactly, bytes as base64 with or without padding, structure and
        /// union members out of order, a union's `fields` left out or given
        /// empty, and an integer map key respelled, which `validated` keeps
        /// as written.
        ///
        /// Mutation check: `validated` keeping structure members in the
        /// order they came in; keeping an int, a uint or a double in the
        /// kind it came in; making bytes base64 text; refusing base64 with
        /// two padding characters or swapping `+` and `/`; requiring a
        /// union's `fields` when its case has some; or keeping an empty
        /// `fields` for a case without any, fails here. A 100-case run
        /// catches most of them and a 1,000-case run catches every one.
        @Test
        func looseFormsValidateToTheCanonicalValue() throws {
            try property(
                reachingAfter: [
                    "members out of order": 1_000,
                    "a respelled map key": 1_000, "an int given as a double": 1_000,
                    "union fields given for a case without any": 1_000,
                    "union members out of order": 1_000,
                ]
            ) { tc in
                let policy = try #draw(SchemaValueGenerators.policies(unknownSlots: true), from: tc)
                let fitting = try #draw(SchemaValueGenerators.fitting(policy), from: tc)
                let looseRate = try #draw(Gen<Double>.element(of: [0.5, 1.0]), from: tc)
                var loosener = Loosener(
                    table: DefinitionTable(fitting.definitions),
                    rate: looseRate
                )
                let rewritten = try loosener.loosen(tc, fitting.value, fitting.schema)
                for label in loosener.labels.sorted() {
                    try tc.event(label)
                }
                switch rewritten.loose.validated(
                    against: fitting.schema,
                    resolver: fitting.resolver
                ) {
                    case .failure(let error):
                        Issue.record("the loose form \(rewritten.loose) does not fit: \(error)")
                    case .success(let canonical):
                        #expect(
                            identical(canonical, rewritten.expected),
                            "the loose form \(rewritten.loose) validated to \(canonical)"
                        )
                        try expectFixedPoint(canonical, fitting)
                }
            }
        }

        /// Whatever `validated` accepts, its result validates to itself.
        /// The input is a loose form with one node replaced by something
        /// close to it or by any tree at all, so it reaches what the
        /// generator never makes: a number in another kind whether or not
        /// it fits, any text as base64, a member dropped, repeated or
        /// added, an item dropped or repeated, null and empty containers
        /// where they may or may not fit.
        ///
        /// Mutation check: `validated` making bytes base64 text, which its
        /// next pass decodes back to bytes, fails here. The other mistakes
        /// `looseFormsValidateToTheCanonicalValue` catches leave `validated`
        /// idempotent, since every pass takes kinds and member order from
        /// the schema; that property is the check for them.
        @Test
        func validatedIsIdempotent() throws {
            try property(
                reaching: ["the input was refused"],
                reachingAfter: [
                    "accepted and rewritten": 1_000, "accepted as it was": 1_000,
                    "the input was accepted": 1_000,
                ]
            ) { tc in
                let policy = try #draw(SchemaValueGenerators.policies(unknownSlots: true), from: tc)
                let fitting = try #draw(SchemaValueGenerators.fitting(policy), from: tc)
                let looseRate = try #draw(Gen<Double>.element(of: [0.5, 1.0]), from: tc)
                var loosener = Loosener(
                    table: DefinitionTable(fitting.definitions),
                    rate: looseRate
                )
                let loose = try loosener.loosen(tc, fitting.value, fitting.schema).loose
                // An inner node when there is one: almost nothing fits in
                // place of a whole value, and a one-node value still puts
                // the root up for replacement.
                let count = nodeCount(loose)
                let position = try #draw(Gen<Int>.int(in: (count > 1 ? 1 : 0)..<count), from: tc)
                let original = node(of: loose, at: position) ?? .null
                let replacement = try #draw(
                    Gen<SchemaValue>.oneOf(
                        SchemaValueGenerators.nearby(original),
                        SchemaValueGenerators.looseValues
                    ),
                    from: tc
                )
                let input = replacing(loose, at: position, with: replacement)
                switch input.validated(against: fitting.schema, resolver: fitting.resolver) {
                    case .failure:
                        try tc.event("the input was refused")
                    case .success(let canonical):
                        try tc.event("the input was accepted")
                        try tc.event(
                            identical(canonical, input)
                                ? "accepted as it was" : "accepted and rewritten"
                        )
                        try expectFixedPoint(canonical, fitting)
                }
            }
        }

        /// `validated` takes its own result and gives it back unchanged.
        func expectFixedPoint(_ canonical: SchemaValue, _ fitting: FittingValue) throws {
            switch canonical.validated(against: fitting.schema, resolver: fitting.resolver) {
                case .failure(let error):
                    Issue.record("validated refuses its own result \(canonical): \(error)")
                case .success(let again):
                    #expect(
                        identical(again, canonical),
                        "validating \(canonical) again made \(again)"
                    )
            }
        }
    }

#endif

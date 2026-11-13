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
            try property { tc in
                let policy = try #draw(SchemaValueGenerators.policies(unknownSlots: true), from: tc)
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
    }

#endif

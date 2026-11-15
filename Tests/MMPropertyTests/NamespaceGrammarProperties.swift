// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    import HegelTesting
    import MMSchema
    import MMSchemaCodeGenerator
    import Testing

    enum NamespaceGrammarGenerators {
        /// Text to check as a namespace: the entity-name texts; valid names
        /// with one rule broken, drawn again so the alphabet's neighbours
        /// come up often; and the two shortest texts the rules turn on, root
        /// and a lone dot.
        static let texts: Gen<(String, String)> = .oneOf(
            EntityNameGenerators.texts,
            EntityNameGenerators.brokenNames.map { ($0, $1.rawValue) },
            Gen<String>.element(of: ["", "."]).map { ($0, $0.isEmpty ? "root" : "a lone dot") }
        )
    }

    @Suite("Namespace grammar properties", .hegel, .offTheCooperativePool)
    struct NamespaceGrammarProperties {
        /// The `#schema` and `#schemaTypes` macros check their namespace with
        /// `isValidLowerIdentifierPath`, which restates `EntityName.parse`'s
        /// grammar because a macro cannot call the runtime. It holds exactly
        /// when `parse` succeeds and the text is not empty: root parses, but
        /// names no namespace.
        ///
        /// Mutation check: an alphabet that admits `A`–`Z`, or `{`, a check
        /// that takes a trailing dot, or one that takes the empty path, fails
        /// here in every 100-case run.
        @Test
        func macroGrammarAgreesWithParse() throws {
            try property(
                reaching: ["a character outside the alphabet", "refused by parse"],
                reachingAfter: [
                    "a doubled dot": 1_000, "a leading dot": 1_000, "a lone dot": 1_000,
                    "a namespace": 1_000, "a trailing dot": 1_000, "a valid name": 1_000,
                    "root": 1_000, "root, which parses": 1_000,
                ]
            ) { tc in
                let (text, kind) = try #draw(NamespaceGrammarGenerators.texts, from: tc)
                try tc.event(kind)
                let parses = (try? EntityName.parse(text).get()) != nil
                let isNamespace = parses && !text.isEmpty
                try tc.event(
                    isNamespace ? "a namespace" : parses ? "root, which parses" : "refused by parse"
                )
                if isNamespace {
                    #expect(isValidLowerIdentifierPath(text), "refused \(text.debugDescription)")
                } else {
                    #expect(!isValidLowerIdentifierPath(text), "accepted \(text.debugDescription)")
                }
            }
        }
    }

#endif

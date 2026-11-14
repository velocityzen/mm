// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    import HegelTesting
    import MMSchema
    import MMWire
    import Testing

    /// The characters a segment may hold.
    let entityNameAlphabet = "abcdefghijklmnopqrstuvwxyz0123456789_-"

    /// The rules the text breaks, by the type's documentation: a segment is
    /// one or more of `a-z`, `0-9`, `_`, `-`, segments join by single dots,
    /// and the empty text is root. Read by Unicode scalar rather than by
    /// byte, so it agrees with the parser without copying it.
    func brokenEntityNameRules(_ text: String) -> Set<InvalidEntityNameReason> {
        guard !text.isEmpty else { return [] }
        var broken: Set<InvalidEntityNameReason> = []
        let parts = text.unicodeScalars.split(separator: ".", omittingEmptySubsequences: false)
        if parts.contains(where: \.isEmpty) { broken.insert(.emptySegment) }
        let allowed = Set(entityNameAlphabet.unicodeScalars).union(["."])
        if !text.unicodeScalars.allSatisfy(allowed.contains) { broken.insert(.invalidCharacter) }
        return broken
    }

    func entityName(_ segments: [String]) throws -> EntityName {
        try EntityName.parse(segments.joined(separator: ".")).get()
    }

    /// One way to break a valid name.
    enum EntityNameBreak: String, CaseIterable, Sendable {
        case leadingDot = "a leading dot"
        case trailingDot = "a trailing dot"
        case doubledDot = "a doubled dot"
        case strangeCharacter = "a character outside the alphabet"
    }

    /// How the second name of a pair relates to the first.
    enum NameRelation: String, CaseIterable, Sendable {
        case descendant = "a descendant"
        case same = "the same name"
        case longerSegment = "the last segment run on"
        case sibling = "a sibling"
        case unrelated = "an unrelated name"
    }

    enum EntityNameGenerators {
        /// A segment of any length, often a one-character edge.
        static let segments: Gen<String> = .oneOf(
            Hegel.zip(
                .character(of: .characters(entityNameAlphabet)),
                .string(of: .characters(entityNameAlphabet))
            )
            .map { String($0) + $1 },
            .element(of: ["a", "z", "0", "9", "_", "-", "-a", "a-", "__"])
        )

        /// Any valid name's segments; none is root.
        static let names: Gen<[String]> = .array(of: segments)

        /// Characters outside the alphabet: half of them the ASCII
        /// neighbours of its ranges, otherwise uppercase, non-ASCII ones that
        /// look or fold like allowed letters, or any character.
        static let strangers: Gen<String> = .oneOf(
            .element(of: ["`", "{", "/", ":", "^", ","]),
            .oneOf(
                .element(of: [
                    "A", "Z", " ", "\u{0}", "\u{7F}", "\u{E9}", "\u{212A}", "\u{0430}", "\u{0131}",
                    "\u{FF41}", "\u{0301}", "\u{1F600}",
                ]),
                Gen<Character>.character().map { String($0) }
            )
        )

        /// A valid name with one rule broken.
        static let brokenNames: Gen<(String, EntityNameBreak)> = Gen { tc in
            let segments = try tc.draw(names)
            // Half the breaks are a strange character, the rest any break.
            let textBreak = try tc.draw(
                Gen<EntityNameBreak>.oneOf(
                    .just(.strangeCharacter),
                    .element(of: EntityNameBreak.allCases)
                )
            )
            let name = segments.joined(separator: ".")
            switch textBreak {
                case .leadingDot:
                    return ("." + name, textBreak)
                case .trailingDot:
                    return (name + ".", textBreak)
                case .doubledDot:
                    let at = try tc.draw(Gen<Int>.int(in: 0...segments.count))
                    var doubled = segments
                    doubled.insert("", at: at)
                    return (doubled.joined(separator: "."), textBreak)
                case .strangeCharacter:
                    var characters = Array(name)
                    let at = try tc.draw(Gen<Int>.int(in: 0...characters.count))
                    characters.insert(contentsOf: try tc.draw(strangers), at: at)
                    return (String(characters), textBreak)
            }
        }

        /// Text to parse, labelled for the statistics report: a third valid
        /// names, a third valid names with one rule broken, a third strings
        /// over the alphabet and its neighbours or any text at all.
        static let texts: Gen<(String, String)> = .oneOf(
            names.map { ($0.joined(separator: "."), "a valid name") },
            brokenNames.map { ($0, $1.rawValue) },
            .oneOf(
                Gen<String>.string(of: .characters(entityNameAlphabet + ".`{/:^,AZ "))
                    .map { ($0, "the alphabet and its neighbours") },
                Gen<String>.string().map { ($0, "any text") }
            )
        )

        /// Two names, the second related to the first as drawn.
        static let pairs: Gen<([String], [String], NameRelation)> = Gen { tc in
            let first = try tc.draw(names)
            let relation = try tc.draw(Gen<NameRelation>.element(of: NameRelation.allCases))
            switch relation {
                case .descendant:
                    let extra = try tc.draw(Gen<[String]>.array(of: segments, count: 1...4))
                    return (first, first + extra, relation)
                case .same:
                    return (first, first, relation)
                case .longerSegment:
                    let more = try tc.draw(segments)
                    let second =
                        first.isEmpty ? [more] : first.dropLast() + [first[first.count - 1] + more]
                    return (first, second, relation)
                case .sibling:
                    let other = try tc.draw(segments)
                    return (first, first.dropLast() + [other], relation)
                case .unrelated:
                    return (first, try tc.draw(names), relation)
            }
        }
    }

    @Suite("EntityName properties", .hegel, .offTheCooperativePool)
    struct EntityNameProperties {
        /// `parse` succeeds exactly when the text keeps the documented rules,
        /// and otherwise names a rule it breaks. A parsed name keeps the text
        /// and its segments, and the MessagePack form decodes exactly when
        /// `parse` succeeds, to the same name.
        ///
        /// Mutation check: a parser that misses a trailing dot fails here.
        /// One that lets `{` into the alphabet fails at the nightly depth:
        /// `{` is one of six neighbours of the alphabet's ranges.
        @Test
        func parsingFollowsTheRules() throws {
            try property(
                reaching: [
                    "a character outside the alphabet", "a valid name",
                    "failed with invalidCharacter", "parsed",
                ],
                reachingAfter: [
                    "a doubled dot": 1_000, "a leading dot": 1_000, "any text": 1_000,
                    "failed with emptySegment": 1_000, "root": 1_000,
                    "the alphabet and its neighbours": 1_000,
                ]
            ) { tc in
                let (text, kind) = try #draw(EntityNameGenerators.texts, from: tc)
                let broken = brokenEntityNameRules(text)
                try tc.event(kind)
                let parsed = EntityName.parse(text)
                switch parsed {
                    case .success(let name):
                        try tc.event(name.isRoot ? "root" : "parsed")
                        #expect(broken.isEmpty, "\(text.debugDescription) breaks \(broken)")
                        #expect(name.rawValue == text)
                        #expect(name.isRoot == text.isEmpty)
                        #expect(
                            name.segments
                                == (text.isEmpty ? [] : text.split(separator: ".").map(String.init))
                        )
                        let encoded = try MMPackEncoder().encode(name).get()
                        #expect(
                            MMPackDecoder().decode(String.self, from: encoded) == .success(text)
                        )
                    case .failure(.invalidEntityName(let reported, let reason)):
                        try tc.event("failed with \(reason)")
                        #expect(reported == text)
                        #expect(
                            broken.contains(reason),
                            "\(text.debugDescription) breaks \(broken), not \(reason)"
                        )
                    case .failure(let other):
                        Issue.record("\(text.debugDescription) failed with \(other)")
                }
                let encodedText = try MMPackEncoder().encode(text).get()
                let decoded = MMPackDecoder().decode(EntityName.self, from: encodedText)
                #expect((try? decoded.get()) == (try? parsed.get()), "\(text.debugDescription)")
            }
        }

        /// `b.isDescendant(of: a)` holds exactly when `a`'s segments are a
        /// strict prefix of `b`'s, or `a` is root and `b` is not; that is,
        /// exactly when `a` is root or among `b`'s ancestors. A name's
        /// ancestors are its strict prefixes of one segment or more,
        /// outermost first.
        ///
        /// Mutation check: a descent check that ignores the dot boundary
        /// (`a.bc` under `a.b`, a name under itself), or ancestors missing
        /// the outermost one, fails here.
        @Test
        func descentAgreesWithAncestors() throws {
            try property(
                reaching: ["descends", "does not descend", "the first is a name"],
                reachingAfter: [
                    "a descendant": 1_000, "a sibling": 1_000, "an unrelated name": 1_000,
                    "the first is root": 1_000, "the last segment run on": 1_000,
                    "the same name": 1_000,
                ]
            ) { tc in
                let (firstSegments, secondSegments, relation) = try #draw(
                    EntityNameGenerators.pairs,
                    from: tc
                )
                let first = try entityName(firstSegments)
                let second = try entityName(secondSegments)
                try tc.event(relation.rawValue)
                try tc.event(first.isRoot ? "the first is root" : "the first is a name")
                let isPrefix =
                    firstSegments.count < secondSegments.count
                    && Array(secondSegments.prefix(firstSegments.count)) == firstSegments
                let descends = !second.isRoot && (first.isRoot || isPrefix)
                try tc.event(descends ? "descends" : "does not descend")
                #expect(second.isDescendant(of: first) == descends)
                #expect(
                    second.isDescendant(of: first)
                        == (!second.isRoot && (first.isRoot || second.ancestors.contains(first)))
                )
                let prefixes = (1..<max(1, secondSegments.count)).map {
                    Array(secondSegments.prefix($0))
                }
                #expect(second.ancestors.map(\.segments) == prefixes)
            }
        }

        /// A name's parent drops its last segment (a single segment's parent
        /// is root, and root has none), is its innermost ancestor, encloses
        /// it, and parses back to itself. Each step drops a segment, so
        /// following `parent` reaches root in as many steps as the name has
        /// segments.
        ///
        /// Mutation check: a single segment whose parent is nil instead of
        /// root fails here.
        @Test
        func parentStepsTowardRoot() throws {
            try property { tc in
                let segments = try #draw(EntityNameGenerators.names, from: tc)
                let name = try entityName(segments)
                try tc.event("segments", value: Double(segments.count))
                guard let parent = name.parent else {
                    #expect(name.isRoot, "\(name) has no parent")
                    #expect(name.ancestors.isEmpty && name.segments.isEmpty)
                    #expect(!name.isDescendant(of: .root))
                    return
                }
                #expect(parent.segments == Array(segments.dropLast()))
                #expect(parent == (name.ancestors.last ?? .root))
                #expect(parent.ancestors == Array(name.ancestors.dropLast()))
                #expect(name.isDescendant(of: parent))
                #expect(name.isDescendant(of: .root))
                #expect(EntityName.parse(parent.rawValue) == .success(parent))
            }
        }
    }

#endif

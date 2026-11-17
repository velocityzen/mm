// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    import Foundation
    import HegelTesting
    @testable import MMCLI
    @testable import MMSchema
    import MMSchemaCodeGenerator
    @testable import MMServer
    import MMTestSupport
    import MMWire
    import NIOCore
    import Testing

    /// Whether `pattern` matches the entity with these segments (none for
    /// root), by the grammar on `EntityPattern`: root matches only root; a
    /// literal segment matches its own text, `*` any one segment, and
    /// trailing depth one or more further segments.
    func modelAdmits(_ pattern: EntityPattern, _ entity: [String]) -> Bool {
        switch pattern.kind {
            case .root:
                return entity.isEmpty
            case .entities(let segments, let descendants):
                guard !entity.isEmpty,
                    descendants ? entity.count > segments.count : entity.count == segments.count
                else { return false }
                return zip(segments, entity).allSatisfy { segment, text in
                    guard case .literal(let literal) = segment else { return true }
                    return literal == text
                }
        }
    }

    func literals(of pattern: EntityPattern) -> [String] {
        guard case .entities(let segments, _) = pattern.kind else { return [] }
        return segments.compactMap {
            guard case .literal(let text) = $0 else { return nil }
            return text
        }
    }

    /// One entity of `pattern` that stands for all of them against
    /// `others`: each `*` filled with a segment longer than every literal
    /// in sight, and one such segment more for trailing depth. Nil for
    /// root, whose one entity is root.
    func witness(of pattern: EntityPattern, against others: [EntityPattern]) -> [String]? {
        guard case .entities(let segments, let descendants) = pattern.kind else { return nil }
        let longest = (others + [pattern]).flatMap(literals(of:)).map(\.count).max() ?? 0
        let fresh = String(repeating: "x", count: longest + 1)
        let filled = segments.map { segment -> String in
            guard case .literal(let text) = segment else { return fresh }
            return text
        }
        return filled + (descendants ? [fresh] : [])
    }

    /// Whether every entity of `pattern` matches one of `outer`. A segment
    /// name can be anything, so no pattern of `outer` can tell the witness,
    /// whose filled segments none of its literals name, from any other
    /// entity of `pattern`: the set covers the pattern exactly when it
    /// admits the witness. Root falls within root only.
    func modelWithin(_ pattern: EntityPattern, _ outer: [EntityPattern]) -> Bool {
        guard let witness = witness(of: pattern, against: outer) else {
            return outer.contains(.root)
        }
        return outer.contains { modelAdmits($0, witness) }
    }

    /// How a second pattern is drawn from a first.
    enum PatternRelation: String, CaseIterable, Sendable {
        case same = "the same pattern"
        case literalWidened = "a literal widened to *"
        case wildcardNarrowed = "a * narrowed to a literal"
        case shorterWithDepth = "a prefix with trailing depth"
        case segmentAdded = "a segment added"
        case segmentDropped = "a segment dropped"
        case depthToggled = "trailing depth toggled"
        case literalChanged = "a literal changed"
        case unrelated = "an unrelated pattern"
    }

    /// What an entity drawn near a pattern is.
    enum EntityNearPattern: String, CaseIterable, Sendable {
        case member = "an entity of the pattern"
        case segmentChanged = "a segment changed"
        case segmentMore = "a segment more"
        case segmentFewer = "a segment fewer"
        case root = "root"
        case anyName = "any name"
    }

    enum EntityPatternGenerators {
        /// A literal segment, often one of a few, so patterns share them.
        static let literals: Gen<String> = .oneOf(
            .element(of: ["a", "b", "journal", "entries"]),
            EntityNameGenerators.segments
        )

        static let segments: Gen<EntityPattern.Segment> = .oneOf(
            literals.map { .literal($0) },
            .just(.anyOne)
        )

        /// The pattern the grammar reads these segments as: a final `*`
        /// with no trailing depth is trailing depth (`"a.*"`), and no
        /// segments without it is root (`""`).
        static func pattern(_ segments: [EntityPattern.Segment], descendants: Bool) -> EntityPattern
        {
            var segments = segments
            var descendants = descendants
            if !descendants, segments.last == .anyOne {
                segments.removeLast()
                descendants = true
            }
            guard descendants || !segments.isEmpty else { return .root }
            return EntityPattern(kind: .entities(segments: segments, descendants: descendants))
        }

        static let entityPatterns: Gen<EntityPattern> = Hegel.zip(
            .array(of: segments, count: 0...4),
            .bool()
        )
        .map { pattern($0, descendants: $1) }

        /// Segments with a `*` among them, as `"tenants.*.journal"`.
        static let wildcardPatterns: Gen<EntityPattern> = Gen { tc in
            var segments = try tc.draw(
                Gen<[EntityPattern.Segment]>.array(of: segments, count: 0...3)
            )
            segments.insert(.anyOne, at: try tc.draw(Gen<Int>.int(in: 0...segments.count)))
            if try tc.draw(.bool()) { segments.append(.literal(try tc.draw(literals))) }
            return pattern(segments, descendants: try tc.draw(.bool()))
        }

        /// Root or every entity a quarter of the time, a pattern with a `*`
        /// segment another quarter, otherwise segments with or without
        /// trailing depth.
        static let patterns: Gen<EntityPattern> = .oneOf(
            .element(of: [EntityPattern.root, .all]),
            wildcardPatterns,
            entityPatterns,
            entityPatterns
        )

        /// One exact pattern of literals: a target that names one entity.
        static let soleEntityPatterns: Gen<EntityPattern> = Gen<[String]>.array(
            of: literals,
            count: 1...3
        )
        .map { pattern($0.map { .literal($0) }, descendants: false) }

        /// The relations that have a place in `pattern`: root's relatives
        /// are itself and any other pattern.
        static func relations(of pattern: EntityPattern) -> [PatternRelation] {
            guard case .entities(let segments, _) = pattern.kind else {
                return [.same, .unrelated]
            }
            let hasLiteral = segments.contains { $0 != .anyOne }
            return PatternRelation.allCases.filter {
                switch $0 {
                    case .literalWidened, .literalChanged: hasLiteral
                    case .wildcardNarrowed: segments.contains(.anyOne)
                    case .segmentDropped: !segments.isEmpty
                    default: true
                }
            }
        }

        /// A pattern drawn from `pattern` by a relation drawn from those
        /// with a place in it, and the relation's label.
        static func related(
            _ pattern: EntityPattern,
            _ tc: TestCase
        ) throws -> (pattern: EntityPattern, label: String) {
            let relation = try tc.draw(Gen<PatternRelation>.element(of: relations(of: pattern)))
            guard case .entities(var segments, let descendants) = pattern.kind else {
                return relation == .same
                    ? (pattern, relation.rawValue) : (try tc.draw(patterns), relation.rawValue)
            }
            func place(where test: (EntityPattern.Segment) -> Bool) throws -> Int {
                let places = segments.indices.filter { test(segments[$0]) }
                return places[try FingerprintGenerators.pick(places.count, tc)]
            }
            switch relation {
                case .same:
                    return (pattern, relation.rawValue)
                case .literalWidened:
                    segments[try place(where: { $0 != .anyOne })] = .anyOne
                case .wildcardNarrowed:
                    segments[try place(where: { $0 == .anyOne })] = .literal(try tc.draw(literals))
                case .shorterWithDepth:
                    let count = try tc.draw(Gen<Int>.int(in: 0...segments.count))
                    return (
                        Self.pattern(Array(segments.prefix(count)), descendants: true),
                        relation.rawValue
                    )
                case .segmentAdded:
                    segments.insert(
                        try tc.draw(Self.segments),
                        at: try tc.draw(Gen<Int>.int(in: 0...segments.count))
                    )
                case .segmentDropped:
                    segments.remove(at: try FingerprintGenerators.pick(segments.count, tc))
                case .depthToggled:
                    return (Self.pattern(segments, descendants: !descendants), relation.rawValue)
                case .literalChanged:
                    segments[try place(where: { $0 != .anyOne })] = .literal(try tc.draw(literals))
                case .unrelated:
                    return (try tc.draw(patterns), relation.rawValue)
            }
            return (Self.pattern(segments, descendants: descendants), relation.rawValue)
        }

        /// Patterns drawn from `pattern`, each by a drawn relation.
        static func relatives(of pattern: EntityPattern, count: ClosedRange<Int>) -> Gen<
            [EntityPattern]
        > {
            .array(
                of: Gen { tc in try related(pattern, tc).pattern },
                count: count
            )
        }

        /// A target as contracts declare one: a pattern and up to two of
        /// its relatives, in any order, or, a quarter of the time, one
        /// entity alone.
        static let targets: Gen<[EntityPattern]> = .oneOf(
            Gen { tc in
                let anchor = try tc.draw(patterns)
                let others = try tc.draw(relatives(of: anchor, count: 0...2))
                return try FingerprintGenerators.shuffled([anchor] + others, tc)
            },
            Gen { tc in
                let anchor = try tc.draw(patterns)
                let others = try tc.draw(relatives(of: anchor, count: 0...2))
                return try FingerprintGenerators.shuffled([anchor] + others, tc)
            },
            Gen { tc in
                let anchor = try tc.draw(patterns)
                let others = try tc.draw(relatives(of: anchor, count: 0...2))
                return try FingerprintGenerators.shuffled([anchor] + others, tc)
            },
            soleEntityPatterns.map { [$0] }
        )

        /// An entity of `pattern`: each `*` and each segment past the
        /// prefix of trailing depth drawn. Root for root.
        static func member(of pattern: EntityPattern, _ tc: TestCase) throws -> [String] {
            guard case .entities(let segments, let descendants) = pattern.kind else { return [] }
            let filled = try segments.map { segment -> String in
                guard case .literal(let text) = segment else { return try tc.draw(literals) }
                return text
            }
            let deeper =
                descendants ? try tc.draw(Gen<[String]>.array(of: literals, count: 1...3)) : []
            return filled + deeper
        }

        /// An entity near `pattern`, as drawn, and what it is.
        static func entity(near pattern: EntityPattern, _ tc: TestCase) throws -> (
            [String], EntityNearPattern
        ) {
            let kind = try tc.draw(Gen<EntityNearPattern>.element(of: EntityNearPattern.allCases))
            var member = try member(of: pattern, tc)
            switch kind {
                case .member:
                    return (member, kind)
                case .segmentChanged:
                    guard !member.isEmpty else { return (member, .member) }
                    member[try FingerprintGenerators.pick(member.count, tc)] = try tc.draw(literals)
                case .segmentMore:
                    member.insert(
                        try tc.draw(literals),
                        at: try tc.draw(Gen<Int>.int(in: 0...member.count))
                    )
                case .segmentFewer:
                    guard !member.isEmpty else { return (member, .member) }
                    member.remove(at: try FingerprintGenerators.pick(member.count, tc))
                case .root:
                    return ([], kind)
                case .anyName:
                    return (try tc.draw(EntityNameGenerators.names), kind)
            }
            return (member, kind)
        }

        /// Segments no pattern grammar reads, so a pattern built on one
        /// stands for a pattern from a newer grammar.
        static let unreadableLiterals: Gen<String> = .element(of: [
            "jour*", "*x", "A", "a..b", "\u{E9}", " ", "a.",
        ])
    }

    /// The text of a pattern with one grammar rule broken, and the rule.
    enum PatternBreak: String, CaseIterable, Sendable {
        case leadingDot = "a leading dot"
        case trailingDot = "a trailing dot"
        case doubledDot = "a doubled dot"
        case strangeCharacter = "a character outside the alphabet"
        case partialWildcard = "a partial wildcard"
    }

    extension EntityPatternGenerators {
        /// Text to read as a pattern, labelled: half a pattern's text, a
        /// quarter a pattern's text with one rule broken, otherwise text
        /// over the grammar's alphabet and its neighbours or any text.
        static let texts: Gen<(String, String)> = .oneOf(
            patterns.map { ($0.text, $0 == .root ? "the empty text" : "a pattern's text") },
            entityPatterns.map { ($0.text, $0 == .root ? "the empty text" : "a pattern's text") },
            brokenTexts.map { ($0, $1.rawValue) },
            .oneOf(
                Gen<String>.string(of: .characters(entityNameAlphabet + ".*`{/:^,AZ "))
                    .map { ($0, "the alphabet and its neighbours") },
                Gen<String>.string().map { ($0, "any text") }
            )
        )

        static let brokenTexts: Gen<(String, PatternBreak)> = Gen { tc in
            var written = try tc.draw(entityPatterns).text.split(separator: ".").map(String.init)
            if written.isEmpty { written = ["a"] }
            let textBreak = try tc.draw(Gen<PatternBreak>.element(of: PatternBreak.allCases))
            switch textBreak {
                case .leadingDot:
                    return ("." + written.joined(separator: "."), textBreak)
                case .trailingDot:
                    return (written.joined(separator: ".") + ".", textBreak)
                case .doubledDot:
                    written.insert("", at: try tc.draw(Gen<Int>.int(in: 0...written.count)))
                case .strangeCharacter:
                    let at = try FingerprintGenerators.pick(written.count, tc)
                    var characters = Array(written[at] == "*" ? "a" : written[at])
                    characters.insert(
                        contentsOf: try tc.draw(EntityNameGenerators.strangers),
                        at: try tc.draw(Gen<Int>.int(in: 0...characters.count))
                    )
                    written[at] = String(characters)
                case .partialWildcard:
                    let at = try FingerprintGenerators.pick(written.count, tc)
                    let literal = written[at] == "*" ? try tc.draw(literals) : written[at]
                    written[at] = try tc.draw(
                        .element(of: [literal + "*", "*" + literal, "**", "*" + literal + "*"])
                    )
            }
            return (written.joined(separator: "."), textBreak)
        }
    }

    /// The runtime's reason for the macro's problem with a non-empty text.
    func runtimeReason(_ problem: TargetPatternProblem) -> InvalidEntityPatternReason? {
        switch problem {
            case .empty: nil
            case .emptySegment: .emptySegment
            case .invalidCharacter: .invalidCharacter
            case .partialWildcard: .partialWildcard
        }
    }

    @Suite("EntityPattern properties", .hegel, .offTheCooperativePool)
    struct EntityPatternProperties {
        /// `admits` matches an entity exactly when the grammar does, for
        /// entities of the pattern and for near misses: a segment changed,
        /// one more or one fewer, root, and any name. A set of one pattern
        /// admits what the pattern does.
        ///
        /// Mutation check: a trailing depth that admits the prefix entity
        /// itself fails here.
        @Test
        func admitsFollowsTheGrammar() throws {
            try property(
                reaching: ["admitted", "refused"],
                reachingAfter: Dictionary(
                    uniqueKeysWithValues: EntityNearPattern.allCases.map { ($0.rawValue, 1_000) }
                )
            ) { tc in
                let pattern = try #draw(EntityPatternGenerators.patterns, from: tc)
                let (segments, kind) = try EntityPatternGenerators.entity(near: pattern, tc)
                let entity = try entityName(segments)
                let admitted = pattern.admits(entity)
                try tc.event(kind.rawValue)
                try tc.event(admitted ? "admitted" : "refused")
                #expect(admitted == modelAdmits(pattern, segments), "\(pattern) admits \(entity)")
                #expect(EntityPattern.admits([pattern], entity) == admitted)
            }
        }

        /// One pattern falls within another exactly when the witness model
        /// says so, and within a set exactly when the set admits the
        /// witness: no set covers a pattern that none of its patterns
        /// covers. An entity of a pattern within another matches the other.
        ///
        /// Mutation check: a fixed depth within trailing depth of the same
        /// length, a trailing depth within a fixed depth of the same
        /// length, a `*` within a literal, or a set that must cover with
        /// all its patterns rather than one, fails here.
        @Test
        func containmentAgreesWithTheWitnessModel() throws {
            try property(
                reaching: ["within", "outside"],
                reachingAfter: Dictionary(
                    uniqueKeysWithValues: PatternRelation.allCases.map { ($0.rawValue, 1_000) }
                ).merging(["root within root": 1_000, "within the set": 1_000]) { $1 }
            ) { tc in
                let pattern = try #draw(EntityPatternGenerators.patterns, from: tc)
                let (first, label) = try EntityPatternGenerators.related(pattern, tc)
                let others = try #draw(
                    EntityPatternGenerators.relatives(of: pattern, count: 0...2),
                    from: tc
                )
                let outer = try FingerprintGenerators.shuffled([first] + others, tc)
                try tc.event(label)

                let within = pattern.isWithin(first)
                try tc.event(within ? "within" : "outside")
                if within, pattern == .root { try tc.event("root within root") }
                #expect(within == modelWithin(pattern, [first]), "\(pattern) within \(first)")

                let withinSet = EntityPattern.firstOutside([pattern], outer) == nil
                if withinSet { try tc.event("within the set") }
                #expect(
                    withinSet == modelWithin(pattern, outer),
                    "\(pattern) within \(EntityPattern.listed(outer))"
                )

                let member = try EntityPatternGenerators.member(of: pattern, tc)
                #expect(modelAdmits(pattern, member), "\(pattern) has \(member)")
                #expect(!within || modelAdmits(first, member), "\(first) misses \(member)")
            }
        }

        /// A pattern's text reads back as the same pattern, and MessagePack
        /// and JSON carry that text and decode it to the same pattern. It
        /// shows as its text, root as `(root)`. Every entity of the
        /// pattern starts with its literal prefix, and the pattern names a
        /// sole entity exactly when it is literals with no trailing depth,
        /// that entity.
        ///
        /// Mutation check: a text that drops trailing depth, or a literal
        /// prefix that takes literals past a `*`, fails here.
        @Test
        func patternsReadBackFromTheirText() throws {
            try property(
                reachingAfter: ["root": 1_000, "a sole entity": 1_000, "a literal prefix": 1_000]
            ) { tc in
                // A third of the time one entity's pattern, which few
                // drawn patterns are.
                let pattern = try #draw(
                    .oneOf(
                        EntityPatternGenerators.patterns,
                        EntityPatternGenerators.patterns,
                        EntityPatternGenerators.soleEntityPatterns
                    ),
                    from: tc
                )
                let text = pattern.text
                #expect(EntityPattern.parse(text) == .success(pattern), "\(text.debugDescription)")
                #expect(pattern.description == (pattern == .root ? "(root)" : text))
                if pattern == .root { try tc.event("root") }

                let packed = try MMPackEncoder().encode(pattern).get()
                #expect(MMPackDecoder().decode(String.self, from: packed) == .success(text))
                #expect(
                    MMPackDecoder().decode(EntityPattern.self, from: packed) == .success(pattern)
                )
                let json = try JSONEncoder().encode([pattern])
                #expect(try JSONDecoder().decode([String].self, from: json) == [text])
                #expect(try JSONDecoder().decode([EntityPattern].self, from: json) == [pattern])

                let member = try EntityPatternGenerators.member(of: pattern, tc)
                if !pattern.literalPrefix.isEmpty { try tc.event("a literal prefix") }
                #expect(
                    member.joined(separator: ".").hasPrefix(pattern.literalPrefix),
                    "\(member) under \(pattern.literalPrefix.debugDescription)"
                )

                let sole = EntityPattern.soleEntity(of: [pattern])
                var named: EntityName? = nil
                if case .entities(let segments, descendants: false) = pattern.kind,
                    !segments.contains(.anyOne)
                {
                    named = try entityName(literals(of: pattern))
                }
                if sole != nil { try tc.event("a sole entity") }
                #expect(sole == named, "\(pattern)")
            }
        }

        /// `#schema` reads a `Target` pattern's text as the runtime does:
        /// the same text, entity and literal prefix when both read it, the
        /// same broken rule when neither does, except that the macro
        /// refuses the empty text, which the runtime reads as root, so that
        /// root in source is always `.root`.
        ///
        /// Mutation check: a macro that lets uppercase letters into a
        /// segment, or reads `jour*` as a wildcard, fails here.
        @Test
        func theMacroReadsPatternsAsTheRuntimeDoes() throws {
            try property(
                reaching: ["read"],
                reachingAfter: Dictionary(
                    uniqueKeysWithValues: PatternBreak.allCases.map { ($0.rawValue, 1_000) }
                ).merging(
                    [
                        "the empty text": 1_000, "refused: emptySegment": 1_000,
                        "refused: invalidCharacter": 1_000, "refused: partialWildcard": 1_000,
                    ]
                ) { $1 }
            ) { tc in
                let (text, kind) = try #draw(EntityPatternGenerators.texts, from: tc)
                try tc.event(kind)
                let runtime = EntityPattern.parse(text)
                let macro = targetPattern(parsing: text)
                switch (runtime, macro) {
                    case (.success(let pattern), .failure(.empty)):
                        #expect(text.isEmpty && pattern == .root, "\(text.debugDescription)")
                    case (.success(let pattern), .success(let read)):
                        try tc.event("read")
                        #expect(read.text == pattern.text)
                        #expect(read.entity == pattern.entity?.rawValue)
                        #expect(read.literalPrefix == pattern.literalPrefix)
                    case (
                        .failure(.invalidEntityPattern(let reported, let reason)),
                        .failure(let problem)
                    ):
                        try tc.event("refused: \(reason)")
                        #expect(reported == text)
                        #expect(runtimeReason(problem) == reason, "\(text.debugDescription)")
                    default:
                        Issue.record("\(text.debugDescription): runtime \(runtime), macro \(macro)")
                }
            }
        }

        /// A signature's target crosses the wire as its contract states it:
        /// each pattern once, in byte order of its text, in MessagePack and
        /// in JSON, where an undeclared target is no key at all. A target
        /// this side cannot read, holding a pattern from a newer grammar,
        /// reads as undeclared with the rest of the signature intact.
        ///
        /// Mutation check: a decoder that fails the signature on an
        /// unreadable target, or that keeps the patterns in the order they
        /// came in, fails here.
        @Test
        func targetsCrossTheWireAsDeclared() throws {
            try property(
                reachingAfter: [
                    "no target": 1_000, "a target": 1_000, "an unreadable pattern": 1_000,
                ]
            ) { tc in
                let signature = try #draw(FingerprintGenerators.signatures, from: tc)
                let target = try #draw(.optional(EntityPatternGenerators.targets), from: tc)
                let unreadable = try #draw(
                    .optional(EntityPatternGenerators.unreadableLiterals),
                    from: tc
                )
                var sent = signature
                // Set in place, past the initializer's normalizing.
                sent.target = target
                var expected = signature
                expected.target = target.map(EntityPattern.normalized)
                if let unreadable, let target {
                    let newer = EntityPattern(
                        kind: .entities(segments: [.literal(unreadable)], descendants: false)
                    )
                    sent.target = try FingerprintGenerators.shuffled(target + [newer], tc)
                    expected.target = nil
                    try tc.event("an unreadable pattern")
                } else {
                    try tc.event(target == nil ? "no target" : "a target")
                }

                let packed = try MMPackEncoder().encode(sent).get()
                let decoded = try MMPackDecoder().decode(MethodSignature.self, from: packed).get()
                #expect(decoded.target == expected.target)
                #expect(try packedBytes(decoded) == packedBytes(expected))

                // JSON as `mm discover` prints it, on a signature whose
                // schemas JSON can always hold.
                var plain = MethodSignature(
                    name: "echo.call",
                    access: .read,
                    request: .structure(fields: []),
                    response: .structure(fields: [])
                )
                plain.target = sent.target
                let json = try JSONEncoder().encode(plain)
                let object = try JSONSerialization.jsonObject(with: json) as? [String: Any]
                #expect(
                    (object?["target"] as? [String]) == sent.target.map { $0.map(\.text) }
                )
                let read = try JSONDecoder().decode(MethodSignature.self, from: json)
                #expect(read.target == expected.target)
            }
        }

        /// The router's boot check finds, in a route's own `Accepts`, the
        /// first pattern outside its call's declared target, by the witness
        /// model, and nothing when the route declares no `Accepts` or its
        /// call no target. A route without `Accepts` accepts the declared
        /// target, or every entity but root when there is none.
        ///
        /// Mutation check: a boot check that tests only the first `Accepts`
        /// pattern, or that lets an `Accepts` pattern through when it
        /// overlaps the target without falling within it, fails here.
        @Test
        func theBootCheckFindsTheFirstAcceptOutsideTheTarget() throws {
            try property(
                reaching: ["an Accepts pattern outside"],
                reachingAfter: [
                    "every Accepts pattern within the target": 1_000, "no target": 1_000,
                    "no Accepts": 1_000, "a later pattern outside": 1_000,
                ]
            ) { tc in
                let target = try #draw(
                    Gen<[EntityPattern]?>.oneOf(
                        EntityPatternGenerators.targets.map { Optional($0) },
                        EntityPatternGenerators.targets.map { Optional($0) },
                        EntityPatternGenerators.targets.map { Optional($0) },
                        .just(nil)
                    ),
                    from: tc
                )
                let anchor = try #draw(
                    target.map { Gen<EntityPattern>.element(of: $0) }
                        ?? EntityPatternGenerators.patterns,
                    from: tc
                )
                let accepts = try #draw(
                    Gen<[EntityPattern]?>.oneOf(
                        EntityPatternGenerators.relatives(of: anchor, count: 1...3).map {
                            Optional($0)
                        },
                        EntityPatternGenerators.relatives(of: anchor, count: 1...3).map {
                            Optional($0)
                        },
                        EntityPatternGenerators.relatives(of: anchor, count: 1...3).map {
                            Optional($0)
                        },
                        .just(nil)
                    ),
                    from: tc
                )
                let route = Handle(
                    Method<EchoRequest, EchoResponse>(
                        name: "echo.call",
                        access: .read,
                        target: target
                    ),
                    accepts.map { Accepts(patterns: $0) }
                ) { _, _ in .success(EchoResponse(value: 0)) }

                let expected = target.flatMap { target in
                    accepts?.first { !modelWithin($0, target) }
                }
                if target == nil { try tc.event("no target") }
                if accepts == nil { try tc.event("no Accepts") }
                if target != nil, let accepts {
                    try tc.event(
                        expected == nil
                            ? "every Accepts pattern within the target"
                            : "an Accepts pattern outside"
                    )
                    if let expected, accepts.first != expected {
                        try tc.event("a later pattern outside")
                    }
                }
                #expect(route.patternOutsideTarget == expected)
                #expect(
                    route.accepts.patterns
                        == (accepts ?? target.map(EntityPattern.normalized) ?? [.all])
                )
            }
        }
    }

    /// Grants every peer every access on every entity, so only a route's
    /// targets refuse.
    struct GrantingACLProvider: EntityACLProvider {
        @concurrent func acl(for entity: EntityName) async -> Result<EntityACL?, ACLProviderError> {
            .success(EntityACL(owner: 1000, group: 1000, mode: 0o777))
        }

        @concurrent func invalidate(_ entity: EntityName) async {}
    }

    /// What the caller passes for the entity, as drawn.
    enum EntityArgument: String, CaseIterable, Sendable {
        case omitted = "omitted"
        case empty = "empty"
        case member = "an entity of the target"
        case nearMiss = "a near miss"
        case anyName = "any name"
        case invalid = "an invalid entity"
    }

    @Suite("Declared target properties", .hegel)
    struct DeclaredTargetProperties {
        /// The CLI's early check accepts an entity for a call with a
        /// declared target exactly when the router does on a route that
        /// takes the target and grants every access, and resolves it to the
        /// same entity: an omitted or empty one is the target's sole entity
        /// when it names one, else root. A refusal of a valid entity names
        /// the target.
        ///
        /// Mutation check: an early check that infers the sole entity from
        /// a target of several patterns, or that admits root without
        /// `.root`, fails here.
        @Test
        func theCLIEarlyCheckAgreesWithTheRouter() async throws {
            try await property(
                reaching: ["accepted", "refused"],
                reachingAfter: Dictionary(
                    uniqueKeysWithValues: EntityArgument.allCases.map { ($0.rawValue, 1_000) }
                ).merging(["an inferred entity": 1_000, "root accepted": 1_000]) { $1 }
            ) { tc in
                let target = try tc.draw(EntityPatternGenerators.targets, named: "target")
                let kind = try tc.draw(
                    Gen<EntityArgument>.element(of: EntityArgument.allCases),
                    named: "kind"
                )
                let pattern = try tc.draw(Gen<EntityPattern>.element(of: target), named: "pattern")
                let argument: String?
                switch kind {
                    case .omitted: argument = nil
                    case .empty: argument = ""
                    case .member:
                        argument = try EntityPatternGenerators.member(of: pattern, tc)
                            .joined(separator: ".")
                    case .nearMiss:
                        argument = try EntityPatternGenerators.entity(near: pattern, tc).0
                            .joined(separator: ".")
                    case .anyName:
                        argument = try tc.draw(EntityNameGenerators.names).joined(separator: ".")
                    case .invalid:
                        argument = try tc.draw(EntityNameGenerators.brokenNames).0
                }
                try tc.event(kind.rawValue)
                tc.note("argument: \(argument.debugDescription)")

                let method = Method<EchoRequest, EchoResponse>(
                    name: "echo.call",
                    access: .read,
                    target: target
                )
                let route = Handle(method) { _, _ in .success(EchoResponse(value: 0)) }
                let router = Router(aclProvider: GrantingACLProvider()) { route }
                let context = MMContext(
                    peer: PeerIdentity(uid: 1000, gid: 1000, supplementaryGroups: [], pid: 1),
                    protocolVersion: 1,
                    connectionID: 1
                )
                let served = await router.authorize(
                    route: route,
                    entity: argument ?? "",
                    context: context,
                    method: method.name
                )
                let early = Result {
                    try MMCLIFailure.entity(argument, method: method.name, target: target)
                }

                switch (early, served) {
                    case (.success(let checked), .success(let entity)):
                        try tc.event("accepted")
                        if entity.isRoot { try tc.event("root accepted") }
                        if (argument ?? "").isEmpty, !entity.isRoot {
                            try tc.event("an inferred entity")
                        }
                        #expect(checked.entity == entity)
                        #expect(checked.argument == entity.rawValue)
                    case (.failure(let error), .failure):
                        try tc.event("refused")
                        if kind != .invalid {
                            #expect(
                                "\(error)".contains(EntityPattern.listed(target)),
                                "\(error)"
                            )
                        }
                    default:
                        Issue.record("the CLI \(early), the router \(served)")
                }
            }
        }
    }

#endif

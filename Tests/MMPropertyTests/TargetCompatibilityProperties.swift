// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    import HegelTesting
    import MMClient
    import MMSchema
    import Testing

    /// Targets of patterns over a few names, and every entity those patterns
    /// can tell apart: whether a set of patterns matches an entity depends
    /// only on the names the patterns spell, and on depth up to one past
    /// their longest prefix. So the entities of depth 1 to 4 over the
    /// spelled names and one other, and root, stand for every entity.
    enum TargetGenerators {
        static let names = ["a", "b", "journal"]

        /// Patterns of up to three segments, each a name or `*`, with or
        /// without a trailing `*`, as the grammar reads their text; root and
        /// `*` one time in five.
        static let pattern: Gen<EntityPattern> = {
            let written: Gen<EntityPattern> = Hegel.zip(
                .array(of: .element(of: names + ["*"]), count: 1...3),
                .bool()
            )
            .map { segments, descendants in
                let text = (segments + (descendants ? ["*"] : [])).joined(separator: ".")
                // Every segment is a name or `*`, so the text always reads.
                return (try? EntityPattern.parse(text).get()) ?? .root
            }
            return .oneOf(written, written, written, written, .element(of: [.root, .all]))
        }()

        /// No target one time in ten, no patterns one in ten, else one to
        /// three patterns.
        static let target: Gen<[EntityPattern]?> = Hegel.zip(
            .int(in: 0...9),
            .array(of: pattern, count: 1...3)
        )
        .map { kind, patterns in
            switch kind {
                case 0: nil
                case 1: []
                default: patterns
            }
        }

        static let universe: [EntityName] = {
            let segments = names + ["other"]
            var level: [[String]] = [[]]
            var entities: [EntityName] = [.root]
            for _ in 1...4 {
                level = level.flatMap { prefix in segments.map { prefix + [$0] } }
                entities += level.compactMap {
                    try? EntityName.parse($0.joined(separator: ".")).get()
                }
            }
            return entities
        }()

        /// A pattern that takes every entity `pattern` takes, and often
        /// more: its segment at `position` (wrapping) written as `*`.
        static func widened(_ pattern: EntityPattern, at position: Int) -> EntityPattern {
            guard pattern != .root else { return pattern }
            var segments = pattern.text.split(separator: ".").map(String.init)
            segments[position % segments.count] = "*"
            return (try? EntityPattern.parse(segments.joined(separator: ".")).get()) ?? pattern
        }

        /// Whether `target` takes `entity`: no target takes every one.
        static func takes(_ target: [EntityPattern]?, _ entity: EntityName) -> Bool {
            target.map { EntityPattern.admits($0, entity) } ?? true
        }
    }

    /// How the server's target relates to the client's, drawn first so
    /// cases differ in kind: the same patterns in another order and
    /// repeated, wider patterns and maybe one more, one pattern fewer, any
    /// other target, or none.
    enum TargetRevision: CaseIterable, Sendable {
        case same, widened, narrowed, independent, dropped

        /// The two that can refuse an entity twice as often as the rest:
        /// at one in five each, a refusal came up in as few as 16 cases in
        /// 100.
        static let weighted: Gen<TargetRevision> = .element(of: [
            .same, .widened, .narrowed, .narrowed, .independent, .independent, .dropped,
        ])
    }

    @Suite("Target compatibility", .hegel)
    struct TargetCompatibilityProperties {
        private static func method(target: [EntityPattern]?) -> MethodSignature {
            MethodSignature(
                name: "box.get",
                access: .read,
                request: .structure(fields: [TypeSchema.Field(key: 0, name: "id", type: .int)]),
                response: .structure(fields: [TypeSchema.Field(key: 0, name: "ok", type: .bool)]),
                target: target
            )
        }

        /// A target change breaks exactly when the server's target refuses an
        /// entity the client's takes, and the break names exactly the
        /// client's patterns that take such an entity. Discovery reports the
        /// change when the targets differ as sets, and calls it breaking
        /// exactly then.
        @Test
        func aTargetBreaksExactlyWhenTheServerRefusesAnEntityTheClientNames() throws {
            try property(
                reaching: [
                    "the server refuses an entity the client names",
                    "the server takes every entity the client names",
                    "a changed target that reads",
                ],
                reachingAfter: [
                    "the client declares no target": 1_000,
                    "the server declares no target": 1_000,
                    "root in the client's target": 1_000,
                    "a pattern another of the server's takes": 1_000,
                    "a pattern fewer that still takes every entity": 1_000,
                    "the same target in another order": 1_000,
                ]
            ) { tc in
                var client = try #draw(TargetGenerators.target, from: tc)
                // A wider form of the first pattern beside it, so that a
                // pattern fewer can still take every entity.
                let nested = try #draw(.bool(probability: 0.3), from: tc)
                let nestedAt = try #draw(.int(in: 0...3), from: tc)
                if nested, let first = client?.first {
                    client?.append(TargetGenerators.widened(first, at: nestedAt))
                }
                let change = try #draw(TargetRevision.weighted, from: tc)
                var server: [EntityPattern]?
                switch change {
                    case .same:
                        let repeated = try #draw(.bool(), from: tc)
                        server = client.map {
                            $0.reversed() + (repeated ? Array($0.prefix(1)) : [])
                        }
                    case .widened:
                        // Each pattern widened at a drawn segment, or kept
                        // at position 4.
                        let positions = try #draw(
                            .array(of: .int(in: 0...4), count: 4...4),
                            from: tc
                        )
                        let more = try #draw(
                            .array(of: TargetGenerators.pattern, count: 0...1),
                            from: tc
                        )
                        server =
                            (client ?? []).enumerated().map { index, pattern in
                                positions[index] == 4
                                    ? pattern
                                    : TargetGenerators.widened(pattern, at: positions[index])
                            } + more
                    case .narrowed:
                        let index = try #draw(.int(in: 0...3), from: tc)
                        if var patterns = client, !patterns.isEmpty {
                            patterns.remove(at: index % patterns.count)
                            server = patterns
                        } else {
                            server = try #draw(TargetGenerators.target, from: tc)
                        }
                    case .independent:
                        server = try #draw(TargetGenerators.target, from: tc)
                    case .dropped:
                        server = nil
                }
                // Set directly, so discovery sees the order the server sent.
                let clientMethod = Self.method(target: client)
                var serverMethod = Self.method(target: nil)
                serverMethod.target = server

                let refused = TargetGenerators.universe.filter {
                    TargetGenerators.takes(client, $0) && !TargetGenerators.takes(server, $0)
                }
                if client == nil { try tc.event("the client declares no target") }
                if server == nil { try tc.event("the server declares no target") }
                if client?.contains(.root) == true { try tc.event("root in the client's target") }
                try tc.event(
                    refused.isEmpty
                        ? "the server takes every entity the client names"
                        : "the server refuses an entity the client names"
                )
                if let client, let server,
                    client.contains(where: { pattern in
                        !server.contains(pattern) && server.contains { pattern.isWithin($0) }
                    })
                {
                    try tc.event("a pattern another of the server's takes")
                }
                if change == .narrowed, refused.isEmpty, let client, !client.isEmpty {
                    try tc.event("a pattern fewer that still takes every entity")
                }
                if change == .same, let client, client.count > 1 {
                    try tc.event("the same target in another order")
                }

                let verdict = MethodSignature.compatibility(
                    client: clientMethod,
                    clientTypes: TypeResolver([]),
                    server: serverMethod,
                    serverTypes: TypeResolver([])
                )
                let targetBreaks = verdict.breaks.filter { $0.path == "target" }
                #expect(targetBreaks.isEmpty == refused.isEmpty, "refused \(refused)")
                #expect(verdict.breaks.count == targetBreaks.count, "\(verdict)")
                if let client, server != nil, let reason = targetBreaks.first?.reason {
                    let named = EntityPattern.normalized(client).filter { pattern in
                        TargetGenerators.universe.contains {
                            pattern.admits($0) && !TargetGenerators.takes(server, $0)
                        }
                    }
                    #expect(
                        reason.hasPrefix("the client targets \(EntityPattern.listed(named)), "),
                        "\(reason)"
                    )
                }

                let difference = SchemaDifference(
                    local: [clientMethod],
                    remote: SchemaResponse(fingerprint: 0, methods: [serverMethod])
                )
                let changed =
                    client.map(EntityPattern.normalized) != server.map(EntityPattern.normalized)
                #expect(difference.targetChanged.isEmpty == !changed, "\(difference)")
                #expect(difference.isBreaking == !refused.isEmpty, "\(difference)")
                if changed, refused.isEmpty { try tc.event("a changed target that reads") }
            }
        }
    }

#endif

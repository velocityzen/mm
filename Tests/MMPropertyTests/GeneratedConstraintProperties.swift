// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    import HegelTesting
    import Logging
    import MMClient
    import MMSchema
    import MMServer
    import MMTestSupport
    import MMWire
    import NIOConcurrencyHelpers
    import Testing

    #if canImport(Darwin)
        import Darwin
    #elseif canImport(Glibc)
        import Glibc
    #endif

    /// A call whose request holds a rule of every kind: on fields, on a
    /// nested type's fields, on a union case's field, on a map's values and
    /// on named scalars.
    enum Rules: MethodNamespace {
        #schema("rules") {
            Alias("Code", .string, constraints: .length(1...4), .pattern("[a-z]+"))
            Alias("Level", .int, constraints: .range(-5...5))
            Alias("Ratio", .double, constraints: .range(0.0...1.0))
            Type("Item") {
                Field("name", .string, constraints: .length(...3))
                Field("count", .uint, constraints: .range(1...))
            }
            Union("Mark") {
                Case("level") {
                    Field("level", .reference("Level"))
                }
                Case("note") {
                    Field("text", .string, constraints: .nonEmpty)
                }
                Case("cleared")
            }
            Call("put") {
                Access { .write }
                Request {
                    Field("code", .reference("Code"))
                    Field("limit", .optional(.int), constraints: .range(0...10))
                    Field("ratio", .reference("Ratio"))
                    Field("scale", .float, constraints: .range(-1.0...1.0))
                    Field("items", .array(.reference("Item")), constraints: .length(...3))
                    Field("weights", .map(key: .string, value: .reference("Ratio")), constraints: .length(1...))
                    Field("mark", .reference("Mark"))
                    Field("blob", .bytes, constraints: .length(...4))
                }
                Response {
                    Field("ok", .bool)
                }
            }
        }
    }

    /// `rules.put` as a release build of the declaring module describes it:
    /// the client sends whatever it is given, and the server's ingress
    /// answers.
    let releasedPut = Method<Rules.PutRequest, Rules.PutResponse>(
        name: "rules.put", access: .write,
        requestCheck: MMConstraintCheck(beforeSending: false))

    let rulesEntity = try! EntityName.parse("rules").get()

    @Suite("Generated constraint checks", .hegel)
    struct GeneratedConstraintProperties {
        /// A generated request type's check names what validating its
        /// value against the contract names (the first value that breaks a
        /// rule, by path, and the rule), a map's entries taken in key order
        /// as the check documents. Through a live server, a release client's
        /// call reaches the handler exactly when there is none, and is
        /// otherwise refused at ingress with code 3 naming the same path and
        /// rule; a debug client refuses the same request before sending it,
        /// with the same path and rule.
        @Test
        func generatedChecksAgreeWithTheContractAtBothEnds() async throws {
            try await withRulesServer { connection, handled in
                try await property(
                    reaching: ["accepted", "refused"],
                    reachingAfter: [
                        "refused at code": 1_000,
                        "refused at limit": 1_000,
                        "refused at ratio": 1_000,
                        "refused at scale": 1_000,
                        "refused at items": 1_000,
                        "refused at weights": 1_000,
                        "refused at mark": 1_000,
                        "refused at blob": 1_000,
                        "refused inside an item": 1_000,
                        "refused on a map's value": 1_000,
                        "refused inside a union case": 1_000,
                        "refused inside an item of a list too long": 1_000,
                        "refused on the first of several broken map values": 1_000,
                    ]
                ) { tc in
                    let breakRate = try #draw(.element(of: [0.0, 0.2, 0.5]), from: tc)
                    let request = try #draw(RulesRequests.requests(breakRate: breakRate), from: tc)
                    let oracle = try contractViolation(of: request)
                    for label in reachLabels(for: oracle) {
                        try tc.event(label)
                    }
                    if let oracle, oracle.path.hasPrefix("items["), request.items.count > 3 {
                        try tc.event("refused inside an item of a list too long")
                    }
                    let brokenWeights = request.weights.values.filter { !(0...1).contains($0.rawValue) }
                    if let oracle, oracle.path.hasPrefix("weights."), brokenWeights.count > 1 {
                        try tc.event("refused on the first of several broken map values")
                    }
                    #expect(request.constraintViolation(at: "") == oracle)

                    let before = handled.value
                    let released = await connection.call(releasedPut, on: rulesEntity, request)
                    if let oracle {
                        let refusal = MMError(
                            code: 3, message: "malformed params: \(oracle.path): \(oracle.problem)")
                        #expect(released == .failure(.malformedParams(refusal)))
                    } else {
                        #expect(released == .success(Rules.PutResponse(ok: true)))
                    }

                    let checked = await connection.call(Rules.put, on: rulesEntity, request)
                    #if DEBUG
                        if let oracle {
                            #expect(checked == .failure(.invalidRequest(path: oracle.path, problem: oracle.problem)))
                        } else {
                            #expect(checked == .success(Rules.PutResponse(ok: true)))
                        }
                    #else
                        #expect(checked.map { _ in () } == released.map { _ in () })
                    #endif
                    #expect(handled.value - before == (oracle == nil ? 2 : 0))
                }
            }
        }
    }

    /// The first value in `request` that breaks a rule, as validating its
    /// value against the contract finds it, or nil.
    func contractViolation(of request: Rules.PutRequest) throws -> SchemaValueError? {
        let schema = try Rules.put.signature().get().request
        let validated = schemaValue(of: request).validated(
            against: schema, resolver: TypeResolver(Rules.types), checkingConstraints: true)
        guard case .failure(let error) = validated else { return nil }
        return error
    }

    /// `request` as a `SchemaValue`, by hand: an absent optional left out, a
    /// float slot holding its double, a map's entries in key order.
    func schemaValue(of request: Rules.PutRequest) -> SchemaValue {
        var members: [SchemaValue.Member] = [.init("code", .string(request.code.rawValue))]
        if let limit = request.limit {
            members.append(.init("limit", .int(Int64(limit))))
        }
        let mark: SchemaValue
        switch request.mark {
            case .level(let level):
                mark = .object([
                    .init("case", .string("level")),
                    .init("fields", .object([.init("level", .int(Int64(level.rawValue)))])),
                ])
            case .note(let text):
                mark = .object([
                    .init("case", .string("note")),
                    .init("fields", .object([.init("text", .string(text))])),
                ])
            case .cleared:
                mark = .object([.init("case", .string("cleared"))])
            case .unknown:
                // The requests drawn hold no case this peer does not know;
                // null fits no union, so one would fail the check visibly.
                mark = .null
        }
        members += [
            .init("ratio", .double(request.ratio.rawValue)),
            .init("scale", .double(Double(request.scale))),
            .init(
                "items",
                .array(
                    request.items.map { item in
                        .object([.init("name", .string(item.name)), .init("count", .uint(UInt64(item.count)))])
                    })),
            .init(
                "weights",
                .object(
                    request.weights.sorted { $0.key < $1.key }.map { .init($0.key, .double($0.value.rawValue)) })),
            .init("mark", mark),
            .init("blob", .bytes(request.blob.bytes)),
        ]
        return .object(members)
    }

    /// Where a refusal lands: the request's field, and the composite it is
    /// inside of.
    func reachLabels(for violation: SchemaValueError?) -> [String] {
        guard let violation else { return ["accepted"] }
        let field = violation.path.prefix { $0 != "." && $0 != "[" }
        var labels = ["refused", "refused at \(field)"]
        if violation.path.hasPrefix("items[") { labels.append("refused inside an item") }
        if violation.path.hasPrefix("weights.") { labels.append("refused on a map's value") }
        if violation.path.hasPrefix("mark.fields.") { labels.append("refused inside a union case") }
        return labels
    }

    /// `rules.put` requests that keep every rule, or whose first broken
    /// field is drawn among the eight and each later field breaks one too
    /// at `breakRate`, so refusals land on every field and the check must
    /// name the first. Inside a field, too, several values may break: two
    /// items, a list too long holding a broken item, several map values.
    enum RulesRequests {
        static func requests(breakRate: Double) -> Gen<Rules.PutRequest> {
            Gen { tc in
                // The list and the map are drawn twice as often: a refusal
                // inside them has more ways to land.
                let firstBroken =
                    try tc.draw(.bool(probability: 0.35))
                    ? nil : try tc.draw(.element(of: [0, 1, 2, 3, 4, 4, 5, 5, 6, 7]))
                func breaking(_ field: Int) throws -> Bool {
                    guard let firstBroken, field >= firstBroken else { return false }
                    return field == firstBroken ? true : try tc.draw(.bool(probability: breakRate))
                }
                let code = try tc.draw(
                    .element(of: try breaking(0) ? ["", "abcde", "A", "a1", "é", "a-b"] : ["a", "ab", "zz", "abcd"]))
                let limit: Int? =
                    try breaking(1)
                    ? try tc.draw(.element(of: [-1, 11, .min, .max]))
                    : try tc.draw(.optional(.element(of: [0, 1, 5, 10])))
                let ratio = try tc.draw(
                    .element(
                        of: try breaking(2)
                            ? [-0.5, 1.5, .nan, .infinity, -.infinity, -.leastNonzeroMagnitude]
                            : [0, -0.0, 0.5, 1, .leastNonzeroMagnitude]))
                let scale: Float = try tc.draw(
                    .element(of: try breaking(3) ? [-1.5, 1.5, .nan, .infinity] : [-1, 0, 0.25, 1]))
                var items = try tc.draw(.array(of: Self.items(breaking: false), count: 0...3))
                if try breaking(4) {
                    // One or two items that break a rule of their own, too
                    // many items, or both: the items come before the list's
                    // own length.
                    let shape = try tc.draw(.int(in: 0...4))
                    let brokenItems = shape == 1 ? 0 : try tc.draw(.int(in: 1...2))
                    if shape >= 1 {
                        items = try tc.draw(.array(of: Self.items(breaking: false), count: 4...5))
                    } else {
                        items = Array(items.prefix(3 - brokenItems))
                    }
                    for _ in 0..<brokenItems {
                        let broken = try tc.draw(Self.items(breaking: true))
                        items.insert(broken, at: try tc.draw(.int(in: 0...items.count)))
                    }
                }
                var weights: [String: Rules.Ratio] = [:]
                for key in try tc.draw(.array(of: .element(of: ["a", "b", "c", "d"]), count: 1...3)) {
                    weights[key] = Rules.Ratio(try tc.draw(.element(of: [0, 0.25, 1])))
                }
                if try breaking(5) {
                    // Mostly entries whose values break their rule, one or
                    // several, else no entry at all.
                    if try tc.draw(.bool(probability: 0.2)) {
                        weights = [:]
                    } else {
                        for key in try tc.draw(.array(of: .element(of: ["a", "b", "c", "d"]), count: 1...3)) {
                            weights[key] = Rules.Ratio(try tc.draw(.element(of: [-1, 2, .nan])))
                        }
                    }
                }
                let mark: Rules.Mark
                if try breaking(6) {
                    mark =
                        try tc.draw(.bool())
                        ? .level(level: Rules.Level(try tc.draw(.element(of: [-6, 6, .min, .max]))))
                        : .note(text: "")
                } else {
                    switch try tc.draw(.int(in: 0...2)) {
                        case 0: mark = .level(level: Rules.Level(try tc.draw(.element(of: [-5, 0, 5]))))
                        case 1: mark = .note(text: try tc.draw(.element(of: ["x", "a note"])))
                        default: mark = .cleared
                    }
                }
                let blob = MMBytes(try tc.draw(.bytes(count: try breaking(7) ? 5...6 : 0...4)))
                return Rules.PutRequest(
                    code: Rules.Code(code), limit: limit, ratio: Rules.Ratio(ratio), scale: scale, items: items,
                    weights: weights, mark: mark, blob: blob)
            }
        }

        static func items(breaking: Bool) -> Gen<Rules.Item> {
            Gen { tc in
                guard breaking else {
                    return Rules.Item(
                        name: try tc.draw(.element(of: ["", "a", "abc"])),
                        count: try tc.draw(.element(of: [1, 2, .max])))
                }
                return try tc.draw(.bool())
                    ? Rules.Item(name: "abcd", count: 1)
                    : Rules.Item(name: "a", count: 0)
            }
        }
    }

    /// Runs `body` with a client connected to a server, on a socket of its
    /// own, that serves `rules.put` and counts the requests its handler
    /// gets.
    func withRulesServer(
        _ body: @escaping @Sendable (MMClientConnection, HandledCount) async throws -> Void
    ) async throws {
        let handled = HandledCount()
        try await withTempSocketPath(prefix: "mm-rules-") { path in
            let server = ServerRuntime(
                configuration: MMServerConfiguration(endpoint: .unix(path: path)),
                namespaces: [Rules.self],
                aclProvider: InMemoryACLProvider([
                    rulesEntity: EntityACL(owner: getuid(), group: getgid(), mode: 0o700)
                ]),
                logger: quietLogger("mm.property.rules.server")
            ) {
                Handle(Rules.put) { _, _ in
                    handled.increment()
                    return .success(Rules.PutResponse(ok: true))
                }
            }
            try await withListeningServer(server, seconds: 3_600) { _ in
                let connection = try await MMClientConnection.connect(
                    to: .unix(path: path),
                    logger: quietLogger("mm.property.rules.client")
                ).get()
                _ = try await withClientRunLoop(
                    connection: connection,
                    context: handled,
                    bodySeconds: 3_600,
                    joinSeconds: 30
                ) { handled in
                    try await body(connection, handled)
                }
            }
        }
    }

    /// How many requests a handler got.
    final class HandledCount: Sendable {
        private let count = NIOLockedValueBox(0)

        func increment() { self.count.withLockedValue { $0 += 1 } }

        var value: Int { self.count.withLockedValue { $0 } }
    }

#endif

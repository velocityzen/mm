// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    import HegelTesting
    import MMSchemaCodeGenerator
    import SwiftParser
    import SwiftSyntax
    import Testing

    /// A field a nested-structure contract declares: a scalar, or a block of
    /// fields, `Field("a") { ... }`, which generates the nested struct `A`.
    indirect enum NestedField: Sendable {
        case scalar(String)
        case block(String, [NestedField])

        var source: String {
            switch self {
                case .scalar(let name):
                    #"Field("\#(name)", .int)"#
                case .block(let name, let fields):
                    #"Field("\#(name)") { \#(fields.map(\.source).joined(separator: "; ")) }"#
            }
        }

        /// The struct a block generates, `A` for `a`.
        static func structName(_ name: String) -> String {
            name.prefix(1).uppercased() + name.dropFirst()
        }
    }

    /// The type that holds a contract's top-level blocks.
    enum NestingHolder: String, CaseIterable, Sendable {
        case type = "a type"
        case union = "a union"
        case request = "a request"

        /// The holder's Swift name, which its nested structs' paths start with.
        var name: String {
            switch self {
                case .type: "T"
                case .union: "U"
                case .request: "PutRequest"
            }
        }
    }

    /// How a test case's blocks are drawn: how many fields a block holds at
    /// most, how often a field is a block, and how deep blocks nest.
    struct NestingPolicy: Sendable {
        var maxFields: Int
        var blockRate: Double
        var maxDepth: Int
    }

    enum NestedStructureGenerators {
        /// Field names: few, so one struct name comes up in several places,
        /// beside itself and inside itself.
        static let names = ["a", "b", "c"]

        static let policies: Gen<NestingPolicy> = Gen { tc in
            NestingPolicy(
                maxFields: try tc.draw(.int(in: 1...3)),
                blockRate: try tc.draw(.element(of: [0.3, 0.6, 0.9])),
                maxDepth: try tc.draw(.int(in: 1...4))
            )
        }

        /// The fields of a block nested `depth` deep in the type named
        /// `holder`, `minimum` of them or more: each name once, and no block
        /// that generates a struct of its holder's name, a clash `#schema`
        /// does not check yet (MM-137).
        static func fields(
            _ tc: TestCase,
            policy: NestingPolicy,
            depth: Int,
            holder: String,
            minimum: Int = 0
        ) throws -> [NestedField] {
            var unused = names
            var fields: [NestedField] = []
            for _ in 0..<(try tc.draw(.int(in: minimum...policy.maxFields))) {
                let name = try tc.draw(.element(of: unused))
                unused.removeAll { $0 == name }
                let structName = NestedField.structName(name)
                if depth < policy.maxDepth, structName != holder,
                    try tc.draw(.bool(probability: policy.blockRate))
                {
                    let nested = try Self.fields(
                        tc,
                        policy: policy,
                        depth: depth + 1,
                        holder: structName
                    )
                    fields.append(.block(name, nested))
                } else {
                    fields.append(.scalar(name))
                }
            }
            return fields
        }
    }

    /// The paths of the structs `fields` generate in `holder`, each in the
    /// type that holds its block: `T.A`, then `T.A.B` for a `b` block in it.
    func nestedStructPaths(_ fields: [NestedField], in holder: String) -> [String] {
        fields.flatMap { field -> [String] in
            guard case .block(let name, let nested) = field else { return [] }
            let path = "\(holder).\(NestedField.structName(name))"
            return [path] + nestedStructPaths(nested, in: path)
        }
    }

    /// The `#schema` in `source`, expanded: its declarations, or the
    /// diagnosis that refuses it.
    enum NestedExpansion {
        case declarations([String])
        case refused(String)
    }

    func nestedExpansion(_ source: String) -> NestedExpansion {
        let item = Parser.parse(source: source).statements.first?.item
        do {
            if let declaration = item?.as(MacroExpansionDeclSyntax.self) {
                return .declarations(try SchemaCodeGenerator.expandSchema(declaration).declarations)
            } else if let expression = item?.as(MacroExpansionExprSyntax.self) {
                return .declarations(try SchemaCodeGenerator.expandSchema(expression).declarations)
            }
            return .refused("not a macro expansion")
        } catch {
            return .refused("\(error)")
        }
    }

    /// The dotted path of every struct in `declarations`, read from the
    /// generator's layout, which indents a declaration four spaces a level
    /// into the struct or enum that holds it. The macro tests walk the
    /// syntax instead; parsing a whole expansion costs ten times what the
    /// rest of a case does.
    func generatedStructPaths(_ declarations: [String]) -> [String] {
        let modifiers: Set<Substring> = ["public", "private", "indirect"]
        var enclosing: [Substring] = []
        var paths: [String] = []
        for line in declarations.lazy.flatMap({ $0.split(separator: "\n") }) {
            let indent = line.prefix { $0 == " " }.count
            let words = line.dropFirst(indent).split(separator: " ").drop { modifiers.contains($0) }
            guard let kind = words.first, kind == "struct" || kind == "enum", words.count > 1 else {
                continue
            }
            let name = words[words.startIndex + 1].prefix {
                $0.isLetter || $0.isNumber || $0 == "_"
            }
            enclosing = Array(enclosing.prefix(indent / 4)) + [name]
            if kind == "struct" { paths.append(enclosing.joined(separator: ".")) }
        }
        return paths
    }

    @Suite("Nested structure properties", .hegel, .offTheCooperativePool)
    struct NestedStructureProperties {
        /// Every `Field("a") { ... }` block generates its struct once, in the
        /// type that holds the block: in the type, the union or the request
        /// for a top-level block, and in the enclosing block's struct below
        /// that. Blocks in different structs may generate structs of one
        /// name. A union's cases hold their top-level blocks' structs
        /// together, so `#schema` refuses two cases whose top-level blocks
        /// generate one name, and only those.
        ///
        /// Mutation check: collecting every struct nested at any depth,
        /// which generates `T.B` beside `T.A.B`, fails here, in a type, a
        /// union and a request alike; so does refusing two union cases whose
        /// structs of one name are nested deeper.
        @Test
        func eachNestedStructLivesInTheTypeThatHoldsItsBlock() throws {
            try property(
                reaching: ["in a type", "in a union", "in a request"],
                reachingAfter: [
                    "a struct nested two deep": 1_000,
                    "a struct nested three deep": 1_000,
                    "one struct name in two places": 1_000,
                    "a struct named like one it is nested in": 1_000,
                    "two cases nest one name": 1_000,
                ]
            ) { tc in
                let policy = try #draw(NestedStructureGenerators.policies, from: tc)
                let holder = try #draw(.element(of: NestingHolder.allCases), from: tc)
                var blocks: [[NestedField]] = []
                for _ in 0..<(holder == .union ? try #draw(.int(in: 1...3), from: tc) : 1) {
                    // A type declares a field or more; a union case and a
                    // request may declare none.
                    blocks.append(
                        try NestedStructureGenerators.fields(
                            tc,
                            policy: policy,
                            depth: 0,
                            holder: holder.name,
                            minimum: holder == .type ? 1 : 0
                        )
                    )
                }
                func body(_ fields: [NestedField]) -> String {
                    fields.map(\.source).joined(separator: "; ")
                }
                let cases = zip(["left", "right", "up"], blocks).map { name, fields in
                    #"Case("\#(name)") { \#(body(fields)) }"#
                }
                let declarations =
                    switch holder {
                        case .type:
                            """
                            Type("T") { \(body(blocks[0])) }
                            Call("put") {
                                Access(.write)
                                Request { Field("t", "T") }
                            }
                            """
                        case .union:
                            """
                            Union("U") { \(cases.joined(separator: "; ")) }
                            Call("put") {
                                Access(.write)
                                Request { Field("u", "U") }
                            }
                            """
                        case .request:
                            """
                            Call("put") {
                                Access(.write)
                                Request { \(body(blocks[0])) }
                            }
                            """
                    }
                let source = "#schema(\"box\") {\n\(declarations)\n}"
                try tc.note(source)

                let expected = blocks.flatMap { nestedStructPaths($0, in: holder.name) }
                // The first struct name a later case's top-level block
                // generates again, which the union refuses.
                var declared: Set<String> = []
                let repeated = blocks.lazy.flatMap { fields in
                    fields.compactMap { field -> String? in
                        guard case .block(let name, _) = field else { return nil }
                        return NestedField.structName(name)
                    }
                }
                .first { !declared.insert($0).inserted }

                try tc.event("in \(holder.rawValue)")
                if expected.contains(where: { $0.split(separator: ".").count >= 3 }) {
                    try tc.event("a struct nested two deep")
                }
                if expected.contains(where: { $0.split(separator: ".").count >= 4 }) {
                    try tc.event("a struct nested three deep")
                }
                let names = expected.map { $0.split(separator: ".").last! }
                if Set(names).count < names.count { try tc.event("one struct name in two places") }
                if expected.contains(where: { path in
                    let parts = path.split(separator: ".").dropFirst()
                    return parts.dropLast().contains(parts.last!)
                }) {
                    try tc.event("a struct named like one it is nested in")
                }
                if repeated != nil { try tc.event("two cases nest one name") }

                let refusal = repeated.map {
                    #"Union("U"): nested struct "\#($0)" is declared by two cases — rename one field"#
                }
                switch nestedExpansion(source) {
                    case .refused(let diagnosis):
                        #expect(diagnosis == refusal, "refused: \(diagnosis)")
                    case .declarations(let declarations):
                        #expect(refusal == nil, "expanded, though two cases nest \(refusal ?? "")")
                        let generated = generatedStructPaths(declarations)
                            .filter { $0.hasPrefix("\(holder.name).") }
                        #expect(generated.sorted() == expected.sorted(), "generated \(generated)")
                }
            }
        }
    }

#endif

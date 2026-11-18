// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    import HegelTesting
    import Testing

    /// A field a name-clash contract declares: a scalar, a reference to the
    /// declared `User`, an inline enumeration, which generates a nested enum,
    /// or a block, which generates a nested struct. Both take the field's
    /// name with its first letter capitalized.
    indirect enum ClashField: Sendable {
        case scalar(String)
        case reference(String)
        case enumeration(String)
        case block(String, [ClashField])

        var name: String {
            switch self {
                case .scalar(let name), .reference(let name), .enumeration(let name),
                    .block(let name, _):
                    name
            }
        }

        var source: String {
            switch self {
                case .scalar(let name):
                    #"Field("\#(name)", .int)"#
                case .reference(let name):
                    #"Field("\#(name)", "User")"#
                case .enumeration(let name):
                    #"Field("\#(name)", .enumeration(cases: [.init(name: "a")]))"#
                case .block(let name, let fields):
                    #"Field("\#(name)") { \#(fields.map(\.source).joined(separator: "; ")) }"#
            }
        }

        /// Whether the field or a field nested in its block names `User`.
        var namesUser: Bool {
            switch self {
                case .reference: true
                case .block(_, let fields): fields.contains(where: \.namesUser)
                default: false
            }
        }

        /// The nested type the field generates: `B` for `b`, nil for a
        /// scalar or a reference.
        var nestedTypeName: String? {
            switch self {
                case .enumeration(let name), .block(let name, _):
                    name.prefix(1).uppercased() + name.dropFirst()
                default: nil
            }
        }
    }

    /// The names a test case's fields draw besides plain ones, each a way a
    /// nested type's name may clash.
    enum ClashFamily: CaseIterable, Sendable {
        /// Names Swift or the generated code keeps.
        case kept
        /// The name of the type that holds the field.
        case owner
        /// Names of members the union or struct generates.
        case member
        /// `user`, whose struct would hide the declared `User`.
        case hidden
        /// `b`, `B` and `_b` alone, whose nested types take one name, the
        /// field's own or another field's.
        case letterCase
    }

    /// How a test case's fields are drawn: how many a block holds at most,
    /// how often a nested field is a block, how often a field that is no
    /// block is an enumeration or a reference, how deep blocks nest, and how
    /// often a name comes from the clash family. How often a top-level field
    /// is a block is drawn for each union case, so one case may hold blocks
    /// and another enumerations of the same names.
    struct ClashPolicy: Sendable {
        var maxFields: Int
        var blockRate: Double
        var enumerationRate: Double
        var referenceRate: Double
        var maxDepth: Int
        /// How many plain names fields draw: with one, every block and
        /// every union case repeats it.
        var plainNames: Int
        var family: ClashFamily
        var clashRate: Double
    }

    enum NestedTypeNameGenerators {
        /// The names Swift or the generated code keeps, which a nested type
        /// must not take, besides any name that starts with `MM`.
        static let keptNames: Set<String> = [
            "Type", "Protocol", "Self", "Any",
            "Bool", "Int", "Int32", "Int64", "UInt64", "Float", "Double", "String", "Duration",
            "Hasher", "Decoder", "Encoder", "CodingKey", "Codable", "Decodable", "Encodable",
            "Hashable", "Sendable", "CaseIterable", "RawRepresentable", "Error", "Swift",
            "TypeSchema", "SchemaDescribable", "SchemaValueError", "Writer", "Reader", "Value",
        ]

        /// Field names that generate a kept name: every kept name, and two
        /// that start with `MM`.
        static let keptFieldNames: [String] =
            keptNames.sorted().map { $0.prefix(1).lowercased() + $0.dropFirst() }
            + ["mMPackWriter", "mMThing"]

        /// The union's cases, in order; `Up` makes `Field("up")` generate a
        /// member's name.
        static let caseNames = ["left", "Up", "right"]

        /// The fields that generate the names of the union's members: a
        /// case's name, a case's coding keys, and the union's.
        static let unionMemberNames = ["up", "leftCodingKeys", "rightCodingKeys", "codingKeys"]

        static let policies: Gen<ClashPolicy> = Gen { tc in
            ClashPolicy(
                maxFields: try tc.draw(.int(in: 1...4)),
                blockRate: try tc.draw(.element(of: [0.2, 0.4, 0.6])),
                enumerationRate: try tc.draw(.element(of: [0.3, 0.6, 0.9])),
                referenceRate: try tc.draw(.element(of: [0.2, 0.6])),
                maxDepth: try tc.draw(.int(in: 1...3)),
                plainNames: try tc.draw(.int(in: 1...3)),
                family: try tc.draw(.element(of: ClashFamily.allCases)),
                clashRate: try tc.draw(.element(of: [0.1, 0.3, 0.6]))
            )
        }

        /// A field name for a block nested in the type named `owner`: one of
        /// a few plain names, which repeat across a union's cases, or a name
        /// from the test case's clash family. `memberNames` generate the
        /// names of the owner's members.
        static func name(
            _ tc: TestCase,
            policy: ClashPolicy,
            owner: String,
            memberNames: [String]
        ) throws -> String {
            if policy.family == .letterCase {
                return try tc.draw(.element(of: ["b", "B", "_b"]))
            }
            guard try tc.draw(.bool(probability: policy.clashRate)) else {
                return try tc.draw(.element(of: Array(["b", "a", "c"].prefix(policy.plainNames))))
            }
            let names =
                switch policy.family {
                    case .kept: keptFieldNames
                    case .owner: [owner.prefix(1).lowercased() + owner.dropFirst()]
                    case .member: memberNames
                    case .hidden, .letterCase: ["user"]
                }
            return try tc.draw(.element(of: names))
        }

        /// The fields of a block nested `depth` deep in the type named
        /// `owner`, `minimum` of them or more, each name once. A struct's
        /// only generated member is `CodingKeys`.
        static func fields(
            _ tc: TestCase,
            policy: ClashPolicy,
            depth: Int,
            owner: String,
            memberNames: [String] = ["codingKeys"],
            minimum: Int = 0
        ) throws -> [ClashField] {
            let blockRate =
                depth == 0 ? try tc.draw(.element(of: [0.0, 0.4, 0.8])) : policy.blockRate
            var fields: [ClashField] = []
            for _ in 0..<(try tc.draw(.int(in: minimum...policy.maxFields))) {
                let name = try Self.name(
                    tc,
                    policy: policy,
                    owner: owner,
                    memberNames: memberNames
                )
                guard !fields.contains(where: { $0.name == name }) else { continue }
                if depth < policy.maxDepth, try tc.draw(.bool(probability: blockRate)) {
                    let structName = name.prefix(1).uppercased() + name.dropFirst()
                    let nested = try Self.fields(
                        tc,
                        policy: policy,
                        depth: depth + 1,
                        owner: structName
                    )
                    fields.append(.block(name, nested))
                } else if try tc.draw(.bool(probability: policy.enumerationRate)) {
                    fields.append(.enumeration(name))
                } else if try tc.draw(.bool(probability: policy.referenceRate)) {
                    fields.append(.reference(name))
                } else {
                    fields.append(.scalar(name))
                }
            }
            // A field that names `User`, which a `User` struct would hide.
            if policy.family == .hidden, try tc.draw(.bool(probability: 0.8)) {
                fields.append(.reference("owner"))
            }
            if fields.count < minimum { fields.append(.scalar("x")) }
            return fields
        }
    }

    /// Why `#schema` refuses a nested type's name, as its diagnosis says it,
    /// and the claim the reason reaches.
    struct NameClash: Sendable {
        var message: String
        var claim: String
        /// Whether the clash is in a struct nested in the holder.
        var nested = false
    }

    /// The first nested type among `fields` whose name clashes in `owner`,
    /// the struct or union that holds them, then in each nested struct in
    /// turn, depth first. A struct is checked before the enums of its
    /// scope, and a name clashes with, in this order: a kept name, the
    /// owner's own name, a member the owner generates, a field when fields
    /// are the owner's members, an earlier nested type, and a type a field
    /// names, which the nested type would hide.
    func firstNameClash(
        owner: String,
        fields: [ClashField],
        fieldsAreMembers: Bool,
        members: Set<String>
    ) -> NameClash? {
        let fieldNames = fieldsAreMembers ? Set(fields.map(\.name)) : []
        let userNamedBy = fields.first(where: \.namesUser)?.name
        func reason(
            for name: String,
            of field: ClashField,
            earlier: [String: (reason: String, claim: String)]
        ) -> (reason: String, claim: String)? {
            if name.hasPrefix("MM") || NestedTypeNameGenerators.keptNames.contains(name) {
                ("a name Swift or the generated code keeps", "a kept name")
            } else if name == owner {
                ("the name of \(owner) itself", "the owner's name")
            } else if members.contains(name) {
                ("the name of a member \(owner) generates", "a member's name")
            } else if fieldNames.contains(name) {
                name == field.name
                    ? ("the name of the field itself", "the field's own name")
                    : ("the name of another field", "another field's name")
            } else if let earlier = earlier[name] {
                earlier
            } else if name == "User", let user = userNamedBy {
                ("which would hide the type User that field \"\(user)\" names", "a hidden type")
            } else {
                nil
            }
        }
        var earlier: [String: (reason: String, claim: String)] = [:]
        for field in fields {
            guard case .block = field, let name = field.nestedTypeName else { continue }
            if let (reason, claim) = reason(for: name, of: field, earlier: earlier) {
                return NameClash(
                    message:
                        "\(owner): field \"\(field.name)\" generates the nested struct \(name), \(reason) — rename the field or declare a named Type",
                    claim: claim
                )
            }
            earlier[name] = (
                "which another field \"\(field.name)\" generates too", "another nested type"
            )
        }
        for field in fields {
            guard case .block = field, let name = field.nestedTypeName else { continue }
            earlier[name] = (
                "the name of a nested struct in \(owner)", "an enum named like a struct"
            )
        }
        for field in fields {
            guard case .enumeration = field, let name = field.nestedTypeName else { continue }
            if let (reason, claim) = reason(for: name, of: field, earlier: earlier) {
                return NameClash(
                    message:
                        "\(owner): field \"\(field.name)\" generates the nested enum \(name), \(reason) — rename the field or declare a named Enum",
                    claim: claim
                )
            }
            earlier[name] = (
                "which another field \"\(field.name)\" generates too", "another nested type"
            )
        }
        for case .block(let name, let nested) in fields {
            let structName = name.prefix(1).uppercased() + name.dropFirst()
            if let clash = firstNameClash(
                owner: structName,
                fields: nested,
                fieldsAreMembers: true,
                members: ["CodingKeys"]
            ) {
                return NameClash(message: clash.message, claim: clash.claim, nested: true)
            }
        }
        return nil
    }

    /// A test case's contract, in which `holder` holds the drawn fields,
    /// beside the declared `User`, and the clash `#schema` must refuse it
    /// for, nil when it must accept it.
    func nameClashCase(
        _ tc: TestCase,
        holder: NestingHolder
    ) throws -> (source: String, clash: NameClash?) {
        let policy = try #draw(NestedTypeNameGenerators.policies, from: tc)
        var blocks: [[ClashField]] = []
        for _ in 0..<(holder == .union ? try #draw(.int(in: 1...3), from: tc) : 1) {
            // A type declares a field or more; a union case and a request
            // may declare none.
            blocks.append(
                try NestedTypeNameGenerators.fields(
                    tc,
                    policy: policy,
                    depth: 0,
                    owner: holder.name,
                    memberNames: holder == .union
                        ? NestedTypeNameGenerators.unionMemberNames : ["codingKeys"],
                    minimum: holder == .type ? 1 : 0
                )
            )
        }
        func body(_ fields: [ClashField]) -> String {
            fields.map(\.source).joined(separator: "; ")
        }
        let caseNames = Array(NestedTypeNameGenerators.caseNames.prefix(blocks.count))
        let cases = zip(caseNames, blocks).map { name, fields in
            #"Case("\#(name)") { \#(body(fields)) }"#
        }
        // The call leaves the CLI out, which would refuse two request fields
        // whose options take one name first.
        let declarations =
            switch holder {
                case .type:
                    """
                    Type("T") { \(body(blocks[0])) }
                    Call("put") {
                        CLI(.omitted)
                        Access(.write)
                        Request { Field("t", "T") }
                    }
                    """
                case .union:
                    """
                    Union("U") { \(cases.joined(separator: "; ")) }
                    Call("put") {
                        CLI(.omitted)
                        Access(.write)
                        Request { Field("u", "U") }
                    }
                    """
                case .request:
                    """
                    Call("put") {
                        CLI(.omitted)
                        Access(.write)
                        Request { \(body(blocks[0])) }
                    }
                    """
            }
        let source =
            "#schema(\"box\") {\nType(\"User\") { Field(\"id\", .int) }\n\(declarations)\n}"

        // The first struct name a case's top-level block generates that an
        // earlier case's generates too, which the union refuses first. Two
        // of one case's are a clash like the others.
        var declared: Set<String> = []
        var repeated: String?
        for fields in blocks where repeated == nil {
            let names = fields.compactMap { field -> String? in
                guard case .block = field else { return nil }
                return field.nestedTypeName
            }
            repeated = names.first(where: declared.contains)
            declared.formUnion(names)
        }
        if let repeated {
            let message =
                #"Union("U"): nested struct "\#(repeated)" is declared by two cases — rename one field"#
            return (source, NameClash(message: message, claim: "two cases"))
        }
        let unionMembers = caseNames.flatMap {
            [$0, $0.prefix(1).uppercased() + $0.dropFirst() + "CodingKeys"]
        }
        let clash = firstNameClash(
            owner: holder.name,
            fields: blocks.flatMap { $0 },
            fieldsAreMembers: holder != .union,
            members: Set(["CodingKeys"] + (holder == .union ? unionMembers : []))
        )
        return (source, clash)
    }

    /// Expands a test case's contract for `holder` and checks that
    /// `#schema` refuses it with the first clash's diagnosis, or accepts it
    /// when no name clashes.
    func checkNameClashes(_ tc: TestCase, holder: NestingHolder) throws {
        let (source, clash) = try nameClashCase(tc, holder: holder)
        try tc.note(source)
        try tc.event("in \(holder.rawValue)")
        if let clash {
            try tc.event("refused")
            try tc.event(clash.claim)
            // One rule, which words the clash with the field's own name and
            // with another field's apart.
            if ["the field's own name", "another field's name"].contains(clash.claim) {
                try tc.event("a field's name")
            }
            if clash.nested { try tc.event("a clash in a nested struct") }
        } else {
            try tc.event("accepted")
        }
        switch nestedExpansion(source) {
            case .refused(let diagnosis):
                #expect(diagnosis == clash?.message, "refused: \(diagnosis)")
            case .declarations:
                #expect(clash == nil, "expanded, though \(clash?.message ?? "")")
        }
    }

    @Suite("Nested type name properties", .hegel, .offTheCooperativePool)
    struct NestedTypeNameProperties {
        /// `#schema` refuses a nested struct or enum whose name clashes in
        /// the type or request that holds it, or in a struct nested in them,
        /// with the first clash's diagnosis, and accepts every other name.
        @Test
        func aNestedTypeIsRefusedExactlyWhenItsNameClashes() throws {
            try property(
                reaching: ["in a type", "in a request", "accepted", "refused"],
                reachingAfter: [
                    "a kept name": 1_000,
                    "the owner's name": 1_000,
                    "a member's name": 1_000,
                    "a field's name": 1_000,
                    "a hidden type": 1_000,
                    "a clash in a nested struct": 1_000,
                ]
            ) { tc in
                let holder = try #draw(.element(of: [NestingHolder.type, .request]), from: tc)
                try checkNameClashes(tc, holder: holder)
            }
        }

        /// A union's cases share one scope for the nested types their
        /// fields generate: `#schema` refuses two cases whose top-level
        /// blocks generate one name before any other clash, then a nested
        /// type whose name clashes with a kept name, the union's, one of its
        /// members, another nested type or a type a field names, and accepts
        /// every other name.
        @Test
        func aUnionsCasesShareOneScopeForTheirNestedTypes() throws {
            try property(
                reaching: ["accepted", "refused"],
                reachingAfter: [
                    "two cases": 1_000,
                    "a kept name": 1_000,
                    "the owner's name": 1_000,
                    "a member's name": 1_000,
                    "another nested type": 1_000,
                    "an enum named like a struct": 1_000,
                    "a hidden type": 1_000,
                    "a clash in a nested struct": 1_000,
                ]
            ) { tc in
                try checkNameClashes(tc, holder: .union)
            }
        }
    }

#endif

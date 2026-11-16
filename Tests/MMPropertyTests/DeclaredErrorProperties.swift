// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    import HegelTesting
    import MMSchema
    import MMSchemaCodeGenerator
    import MMWire
    import NIOCore
    import SwiftParser
    import SwiftSyntax
    import Testing

    /// A call that fails with errors of every kind: a namespace error, a
    /// named error with fields and one without, a case carrying a `Type`,
    /// and a case with inline fields.
    enum Depot: MethodNamespace {
        #schema("depot") {
            Errors {
                Case("sealed", exitCode: 10)
            }
            Error("Full", exitCode: 12) {
                Field("capacity", .int)
                Field("note", .optional(.string))
            }
            Error("Empty", exitCode: 13)
            Type("Conflict") {
                Field("existing", .string)
                Field("tags", .array(.string))
            }
            Call("put") {
                Access { .write }
                Errors {
                    Case(.reference("Full"))
                    Case(.reference("Empty"))
                    Case("conflict", .reference("Conflict"), exitCode: 11)
                    Case("tooLong", exitCode: 14) {
                        Field("limit", .uint)
                        Field("hint", .optional(.string))
                        Field("blob", .bytes)
                    }
                }
            }
        }
    }

    /// A declared error a newer build sends: any tag, and fields this build
    /// cannot read.
    struct UnknownDeclaredError: Encodable {
        enum Fields: Encodable {
            case map([String: Int])
            case text(String)
            case number(Int)

            func encode(to encoder: any Encoder) throws {
                var container = encoder.singleValueContainer()
                switch self {
                    case .map(let map): try container.encode(map)
                    case .text(let text): try container.encode(text)
                    case .number(let number): try container.encode(number)
                }
            }
        }

        var name: String
        var fields: Fields?

        enum CodingKeys: Int, CodingKey {
            case name = 0
            case fields = 1
        }
    }

    /// The declared-error rules `#schema` enforces, as the model names them.
    enum ErrorRule: String, CaseIterable, Sendable {
        case exitCodeOutOfRange = "an exit code out of range"
        case reservedName = "a reserved name"
        case duplicateDeclaration = "a duplicate declaration"
        case nameCollision = "a name collision"
        case unresolvedReference = "an unresolved reference"
        case duplicateCase = "a duplicate case"
        case namespaceClash = "a namespace clash"
        case exitCodeClash = "an exit-code clash"
    }

    /// One `Errors` entry of a drawn contract.
    struct DrawnErrorCase: Sendable {
        enum Kind: Sendable {
            /// `Case("busy", exitCode: 10)`.
            case plain
            /// `Case("busy", exitCode: 10) { Field("limit", .int) }`.
            case fields
            /// `Case("busy", .reference("Conflict"), exitCode: 10)`.
            case carrying(String)
            /// `Case(.reference("Full"))`; the name and exit code are the
            /// named error's.
            case named(String)
        }

        var name: String
        var exitCode: Int
        var kind: Kind

        var source: String {
            switch self.kind {
                case .plain:
                    "Case(\"\(self.name)\", exitCode: \(self.exitCode))"
                case .fields:
                    "Case(\"\(self.name)\", exitCode: \(self.exitCode)) { Field(\"limit\", .int) }"
                case .carrying(let type):
                    "Case(\"\(self.name)\", .reference(\"\(type)\"), exitCode: \(self.exitCode))"
                case .named(let type):
                    "Case(.reference(\"\(type)\"))"
            }
        }
    }

    /// One `Error("Full", exitCode:)` of a drawn contract.
    struct DrawnNamedError: Sendable {
        var name: String
        var exitCode: Int
        var hasFields: Bool

        var source: String {
            "Error(\"\(self.name)\", exitCode: \(self.exitCode))"
                + (self.hasFields ? " { Field(\"capacity\", .int) }" : "")
        }
    }

    /// A `#schema` block with a `Type("Conflict")`, an `Enum("Kind")`, one
    /// call, and drawn errors.
    struct DrawnErrorContract: Sendable {
        var namedErrors: [DrawnNamedError]
        var namespaceErrors: [DrawnErrorCase]?
        var callErrors: [DrawnErrorCase]?

        var source: String {
            var lines = [
                "#schema(\"box\") {",
                "Type(\"Conflict\") { Field(\"existing\", .string) }",
                "Enum(\"Kind\") { Case(\"a\") }",
            ]
            lines += self.namedErrors.map(\.source)
            if let namespaceErrors {
                lines += ["Errors {"] + namespaceErrors.map(\.source) + ["}"]
            }
            lines += ["Call(\"ping\") {", "Access(.read)"]
            if let callErrors {
                lines += ["Errors {"] + callErrors.map(\.source) + ["}"]
            }
            lines += ["}", "}"]
            return lines.joined(separator: "\n")
        }

        /// The rules the contract breaks, by the declared-error rules alone:
        /// exit codes in 2...63; `unknown` and `Error` reserved; no name
        /// declared twice or shared with a type; references to a `Type` or
        /// `Error` of the block; no case twice in a block; a call's cases
        /// apart from the namespace's, in name and in exit code.
        var violations: Set<ErrorRule> {
            var found: Set<ErrorRule> = []
            let names = self.namedErrors.map(\.name)
            if self.namedErrors.contains(where: { !declaredErrorExitCodes.contains($0.exitCode) }) {
                found.insert(.exitCodeOutOfRange)
            }
            if names.contains("Error") { found.insert(.reservedName) }
            if Set(names).count < names.count { found.insert(.duplicateDeclaration) }
            if names.contains(where: { $0 == "Kind" || $0 == "Conflict" }) {
                found.insert(.nameCollision)
            }
            let named = Dictionary(
                self.namedErrors.map { ($0.name, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            func resolved(_ errorCase: DrawnErrorCase) -> (name: String, exitCode: Int)? {
                switch errorCase.kind {
                    case .named(let type):
                        guard let error = named[type] else {
                            found.insert(.unresolvedReference)
                            return nil
                        }
                        let name = MMSchema.errorCaseName(forNamedError: type)
                        if name == "unknown" { found.insert(.reservedName) }
                        return (name, error.exitCode)
                    case .plain, .fields, .carrying:
                        if !declaredErrorExitCodes.contains(errorCase.exitCode) {
                            found.insert(.exitCodeOutOfRange)
                        }
                        if errorCase.name == "unknown" { found.insert(.reservedName) }
                        if case .carrying(let type) = errorCase.kind, type != "Conflict",
                            named[type] == nil
                        {
                            found.insert(.unresolvedReference)
                        }
                        return (errorCase.name, errorCase.exitCode)
                }
            }
            let namespace = (self.namespaceErrors ?? []).compactMap(resolved)
            let own = (self.callErrors ?? []).compactMap(resolved)
            for block in [namespace, own] where Set(block.map(\.name)).count < block.count {
                found.insert(.duplicateCase)
            }
            if !Set(namespace.map(\.name)).isDisjoint(with: own.map(\.name)) {
                found.insert(.namespaceClash)
            }
            let all = namespace + own
            if Set(all.map(\.exitCode)).count < all.count {
                found.insert(.exitCodeClash)
            }
            return found
        }

        /// Both blocks' cases, the namespace's first.
        var allCases: [DrawnErrorCase] { (self.namespaceErrors ?? []) + (self.callErrors ?? []) }

        /// An exit code in 2...63 no declaration takes yet.
        var freshExitCode: Int {
            let taken = Set(self.namedErrors.map(\.exitCode) + self.allCases.map(\.exitCode))
            return declaredErrorExitCodes.first { !taken.contains($0) } ?? 2
        }

        /// A case name no case takes yet.
        var freshCaseName: String { "spare\(self.allCases.count)" }

        /// The case's name in its enum: a listed named error's is derived.
        func caseName(of errorCase: DrawnErrorCase) -> String {
            if case .named(let type) = errorCase.kind {
                return MMSchema.errorCaseName(forNamedError: type)
            }
            return errorCase.name
        }

        /// The case's exit code: a listed named error's is the error's.
        func exitCode(of errorCase: DrawnErrorCase) -> Int {
            if case .named(let type) = errorCase.kind {
                return self.namedErrors.first { $0.name == type }?.exitCode ?? 0
            }
            return errorCase.exitCode
        }

        mutating func append(_ errorCase: DrawnErrorCase, toNamespace: Bool) {
            if toNamespace {
                self.namespaceErrors = (self.namespaceErrors ?? []) + [errorCase]
            } else {
                self.callErrors = (self.callErrors ?? []) + [errorCase]
            }
        }
    }

    enum DeclaredErrorGenerators {
        static let putErrors: Gen<Depot.PutError> = .oneOf(
            .just(.sealed),
            Hegel.zip(Gen<Int>.int(), .optional(.string())).map {
                .full(Depot.Full(capacity: $0, note: $1))
            },
            .just(.empty(Depot.Empty())),
            Hegel.zip(Gen<String>.string(), .array(of: .string(), count: 0...3)).map {
                .conflict(Depot.Conflict(existing: $0, tags: $1))
            },
            Hegel.zip(Gen<UInt64>.integer(), .optional(.string()), Gen<[UInt8]>.bytes(count: 0...8))
                .map { .tooLong(limit: $0, hint: $1, blob: MMBytes($2)) }
        )

        static let knownCaseNames: Set<String> = ["sealed", "full", "empty", "conflict", "tooLong"]

        /// Tags `Depot.PutError` does not know: near misses of its own, the
        /// reserved `unknown`, or any text.
        static let unknownCaseNames: Gen<String> = Gen<String>.oneOf(
            .element(of: ["Full", "full ", "sealed2", "tooLong\u{0}", "conflicT", "unknown", ""]),
            .string()
        )
        .filter { !knownCaseNames.contains($0) }

        static let unknownFields: Gen<UnknownDeclaredError.Fields?> = .optional(
            .oneOf(
                Gen<[(String, Int)]>.array(of: Hegel.zip(.string(), .int()), count: 0...3).map {
                    .map(Dictionary($0, uniquingKeysWith: { first, _ in first }))
                },
                Gen<String>.string().map { .text($0) },
                Gen<Int>.int().map { .number($0) }
            )
        )

        /// Type names: identifiers over capitals, lowercase letters, digits
        /// and `_`, ASCII and not; a run of capitals then the rest, the shape
        /// the rule turns on; or any text.
        static let typeNames: Gen<String> = .oneOf(
            .string(
                of: .characters("ABZabz09_\u{C9}\u{E9}\u{3A3}\u{1C5}\u{DF}\u{130}"),
                count: 0...8
            ),
            Hegel.zip(
                .string(of: .characters("ABZ\u{C9}\u{3A3}"), count: 1...4),
                .string(of: .characters("abz09_\u{E9}\u{DF}"), count: 0...4)
            ).map { $0 + $1 },
            .string()
        )

        static func exitCodes(wide: Bool) -> Gen<Int> {
            let inRange: Gen<Int> = .element(of: [2, 10, 11, 12, 13, 14, 63])
            guard wide else { return inRange }
            return .oneOf(inRange, .element(of: [0, 1, 64, 100, -1]), .int())
        }

        /// A contract that keeps every rule: distinct names and exit codes,
        /// and references only to what the block declares, each named error
        /// listed at most once.
        static let validContracts: Gen<DrawnErrorContract> = Gen { tc in
            var codes = Array(try tc.draw(Gen<Int>.int(in: 2...56))...63)
            var names = try FingerprintGenerators.shuffled(
                ["busy", "late", "idle", "gone", "jammed"],
                tc
            )
            let errorNames = try FingerprintGenerators.shuffled(["Full", "Empty"], tc)
                .prefix(try tc.draw(Gen<Int>.int(in: 0...2)))
            var namedErrors: [DrawnNamedError] = []
            for name in errorNames {
                namedErrors.append(
                    DrawnNamedError(
                        name: name,
                        exitCode: codes.removeFirst(),
                        hasFields: try tc.draw(Gen<Bool>.bool())
                    )
                )
            }
            var unlisted = namedErrors.map(\.name)
            let carried = ["Conflict"] + namedErrors.map(\.name)
            func nextCase() throws -> DrawnErrorCase {
                let kind = try tc.draw(Gen<Int>.int(in: 0...3))
                if kind == 3, !unlisted.isEmpty {
                    let type = unlisted.removeFirst()
                    return DrawnErrorCase(
                        name: MMSchema.errorCaseName(forNamedError: type),
                        exitCode: 0,
                        kind: .named(type)
                    )
                }
                return DrawnErrorCase(
                    name: names.removeFirst(),
                    exitCode: codes.removeFirst(),
                    kind: kind == 0
                        ? .plain
                        : kind == 1 ? .fields : .carrying(try tc.draw(.element(of: carried)))
                )
            }
            var namespace: [DrawnErrorCase] = []
            for _ in 0..<(try tc.draw(Gen<Int>.int(in: 0...2))) { namespace.append(try nextCase()) }
            var call: [DrawnErrorCase] = []
            for _ in 0..<(try tc.draw(Gen<Int>.int(in: 0...3))) { call.append(try nextCase()) }
            return DrawnErrorContract(
                namedErrors: namedErrors,
                namespaceErrors: namespace.isEmpty ? nil : namespace,
                callErrors: call.isEmpty ? nil : call
            )
        }

        /// The contract with one declaration added that breaks `rule`, and
        /// only it when the contract kept every rule before.
        static func breaking(
            _ rule: ErrorRule,
            _ contract: DrawnErrorContract,
            _ tc: TestCase
        ) throws -> DrawnErrorContract {
            var contract = contract
            let fresh = contract.freshExitCode
            let toNamespace = try tc.draw(Gen<Bool>.bool())
            switch rule {
                case .exitCodeOutOfRange:
                    let bad = try tc.draw(
                        Gen<Int>.oneOf(.element(of: [0, 1, 64, 65, 100, -1]), .int())
                            .filter { !declaredErrorExitCodes.contains($0) }
                    )
                    if try tc.draw(Gen<Bool>.bool()) {
                        contract.namedErrors.append(
                            DrawnNamedError(name: "Spare", exitCode: bad, hasFields: false)
                        )
                    } else {
                        contract.append(
                            DrawnErrorCase(
                                name: contract.freshCaseName,
                                exitCode: bad,
                                kind: .plain
                            ),
                            toNamespace: toNamespace
                        )
                    }
                case .reservedName:
                    switch try tc.draw(Gen<Int>.int(in: 0...2)) {
                        case 0:
                            contract.append(
                                DrawnErrorCase(name: "unknown", exitCode: fresh, kind: .fields),
                                toNamespace: toNamespace
                            )
                        case 1:
                            contract.namedErrors.append(
                                DrawnNamedError(name: "Error", exitCode: fresh, hasFields: false)
                            )
                        default:
                            contract.namedErrors.append(
                                DrawnNamedError(name: "Unknown", exitCode: fresh, hasFields: true)
                            )
                            contract.append(
                                DrawnErrorCase(
                                    name: "unknown",
                                    exitCode: 0,
                                    kind: .named("Unknown")
                                ),
                                toNamespace: toNamespace
                            )
                    }
                case .duplicateDeclaration:
                    let name =
                        try contract.namedErrors.isEmpty
                        ? "Spare" : tc.draw(.element(of: contract.namedErrors.map(\.name)))
                    if contract.namedErrors.isEmpty {
                        contract.namedErrors.append(
                            DrawnNamedError(name: name, exitCode: fresh, hasFields: false)
                        )
                    }
                    contract.namedErrors.append(
                        DrawnNamedError(
                            name: name,
                            exitCode: contract.freshExitCode,
                            hasFields: true
                        )
                    )
                case .nameCollision:
                    contract.namedErrors.append(
                        DrawnNamedError(
                            name: try tc.draw(.element(of: ["Kind", "Conflict"])),
                            exitCode: fresh,
                            hasFields: false
                        )
                    )
                case .unresolvedReference:
                    let kind: DrawnErrorCase.Kind = try tc.draw(
                        .element(of: [
                            .carrying("Kind"), .carrying("Missing"), .named("Missing"),
                            .named("Conflict"),
                        ])
                    )
                    contract.append(
                        DrawnErrorCase(name: contract.freshCaseName, exitCode: fresh, kind: kind),
                        toNamespace: toNamespace
                    )
                case .duplicateCase:
                    let block = (toNamespace ? contract.namespaceErrors : contract.callErrors) ?? []
                    let name =
                        try block.isEmpty
                        ? contract.freshCaseName
                        : contract.caseName(of: tc.draw(.element(of: block)))
                    if block.isEmpty {
                        contract.append(
                            DrawnErrorCase(name: name, exitCode: fresh, kind: .plain),
                            toNamespace: toNamespace
                        )
                    }
                    contract.append(
                        DrawnErrorCase(name: name, exitCode: contract.freshExitCode, kind: .fields),
                        toNamespace: toNamespace
                    )
                case .namespaceClash:
                    if contract.namespaceErrors == nil {
                        contract.append(
                            DrawnErrorCase(
                                name: contract.freshCaseName,
                                exitCode: fresh,
                                kind: .plain
                            ),
                            toNamespace: true
                        )
                    }
                    let clashing = try tc.draw(.element(of: contract.namespaceErrors ?? []))
                    contract.append(
                        DrawnErrorCase(
                            name: contract.caseName(of: clashing),
                            exitCode: contract.freshExitCode,
                            kind: .plain
                        ),
                        toNamespace: false
                    )
                case .exitCodeClash:
                    if contract.allCases.isEmpty {
                        contract.append(
                            DrawnErrorCase(
                                name: contract.freshCaseName,
                                exitCode: fresh,
                                kind: .plain
                            ),
                            toNamespace: !toNamespace
                        )
                    }
                    let clashing = try tc.draw(.element(of: contract.allCases))
                    contract.append(
                        DrawnErrorCase(
                            name: contract.freshCaseName,
                            exitCode: contract.exitCode(of: clashing),
                            kind: .plain
                        ),
                        toNamespace: toNamespace
                    )
            }
            return contract
        }

        /// A contract under a drawn policy: some cases keep to valid exit
        /// codes and names that resolve, so whole contracts are accepted;
        /// others draw from menus that break one rule or several.
        static let wildContracts: Gen<DrawnErrorContract> = Gen { tc in
            let wideExitCodes = try tc.draw(Gen<Bool>.bool())
            let reservedNames = try tc.draw(Gen<Bool>.bool())
            let unresolvable = try tc.draw(Gen<Bool>.bool())
            let exitCodes = Self.exitCodes(wide: wideExitCodes)
            let caseNames: Gen<String> = .element(
                of: ["busy", "late", "full", "empty"] + (reservedNames ? ["unknown"] : [])
            )
            let errorNames: Gen<String> = .element(
                of: ["Full", "Empty"]
                    + (reservedNames ? ["Unknown", "Error", "Kind", "Conflict"] : [])
            )
            let carried: Gen<String> = .element(
                of: ["Conflict", "Full"] + (unresolvable ? ["Kind", "Missing"] : [])
            )
            let referenced: Gen<String> = .element(
                of: ["Full", "Empty"] + (reservedNames ? ["Unknown"] : [])
                    + (unresolvable ? ["Missing", "Conflict"] : [])
            )
            let kinds: Gen<DrawnErrorCase.Kind> = .oneOf(
                .just(.plain),
                .just(.fields),
                carried.map { .carrying($0) },
                referenced.map { .named($0) }
            )
            let cases: Gen<DrawnErrorCase> = Gen { tc in
                DrawnErrorCase(
                    name: try tc.draw(caseNames),
                    exitCode: try tc.draw(exitCodes),
                    kind: try tc.draw(kinds)
                )
            }
            let namedErrors: Gen<DrawnNamedError> = Gen { tc in
                DrawnNamedError(
                    name: try tc.draw(errorNames),
                    exitCode: try tc.draw(exitCodes),
                    hasFields: try tc.draw(Gen<Bool>.bool())
                )
            }
            return DrawnErrorContract(
                namedErrors: try tc.draw(.array(of: namedErrors, count: 0...2)),
                namespaceErrors: try tc.draw(.optional(.array(of: cases, count: 1...2))),
                callErrors: try tc.draw(.optional(.array(of: cases, count: 1...3)))
            )
        }

        /// A valid contract with one rule broken, drawn twice as often as
        /// the others so each rule is the only one broken in a good share of
        /// cases; a valid contract; or a wild one, where rules break
        /// together.
        static let contracts: Gen<DrawnErrorContract> = {
            let broken: Gen<DrawnErrorContract> = Gen { tc in
                try breaking(
                    try tc.draw(.element(of: ErrorRule.allCases)),
                    try tc.draw(validContracts),
                    tc
                )
            }
            return .oneOf(broken, broken, validContracts, wildContracts)
        }()
    }

    /// `#schema`'s verdict on the source: nil when it expands, else its
    /// diagnosis.
    func schemaDiagnosis(_ source: String) -> String? {
        let item = Parser.parse(source: source).statements.first?.item
        do {
            if let declaration = item?.as(MacroExpansionDeclSyntax.self) {
                _ = try SchemaCodeGenerator.expandSchema(declaration)
            } else if let expression = item?.as(MacroExpansionExprSyntax.self) {
                _ = try SchemaCodeGenerator.expandSchema(expression)
            } else {
                return "not a macro expansion"
            }
            return nil
        } catch {
            return "\(error)"
        }
    }

    @Suite("Declared error properties", .hegel, .offTheCooperativePool)
    struct DeclaredErrorProperties {
        /// Every declared error crosses the wire as itself: code 64, its
        /// case as the message, and a payload the call's error type decodes
        /// back to the same value. A reader that knows only the namespace's
        /// errors sees a call's own error as unknown, by its name.
        ///
        /// Mutation check: a message other than the case name fails here.
        @Test
        func declaredErrorsCrossTheWire() throws {
            try property(
                reaching: ["conflict"],
                reachingAfter: ["empty": 1_000, "full": 1_000, "sealed": 1_000, "tooLong": 1_000]
            ) { tc in
                let value = try #draw(DeclaredErrorGenerators.putErrors, from: tc)
                try tc.event(value.caseName)
                var buffer = ByteBuffer()
                try MMError.declaring(value).get().encode(into: &buffer).get()
                let error = try MMError.decode(from: &buffer).get()
                #expect(buffer.readableBytes == 0)
                #expect(error.code == MMError.declaredErrorCode)
                #expect(error.message == value.caseName)
                #expect(error.declared(as: Depot.PutError.self) == value)
                #expect(
                    error.declared(as: Depot.Error.self)
                        == (value == .sealed ? .sealed : .unknown(value.caseName))
                )
            }
        }

        /// A tag the receiver does not know decodes to `unknown` with that
        /// tag, whatever its fields hold, and forwards with the tag alone.
        ///
        /// Mutation check: a generated decoder whose `unknown` case forgets
        /// the tag it arrived with fails here.
        @Test
        func unknownCasesKeepTheirName() throws {
            try property(
                reaching: ["no fields"],
                reachingAfter: [
                    "map fields": 1_000, "number fields": 1_000, "text fields": 1_000,
                    "the tag unknown": 1_000,
                ]
            ) { tc in
                let name = try #draw(DeclaredErrorGenerators.unknownCaseNames, from: tc)
                let fields = try #draw(DeclaredErrorGenerators.unknownFields, from: tc)
                if name == "unknown" { try tc.event("the tag unknown") }
                switch fields {
                    case nil: try tc.event("no fields")
                    case .map?: try tc.event("map fields")
                    case .text?: try tc.event("text fields")
                    case .number?: try tc.event("number fields")
                }
                let payload = try MMPackEncoder().encode(
                    UnknownDeclaredError(name: name, fields: fields)
                ).get()
                let error = MMError(
                    code: MMError.declaredErrorCode,
                    message: name,
                    payload: payload
                )
                #expect(error.declared(as: Depot.PutError.self) == .unknown(name))
                let forwarded = try MMError.declaring(Depot.PutError.unknown(name)).get()
                #expect(forwarded.message == name)
                #expect(forwarded.declared(as: Depot.PutError.self) == .unknown(name))
            }
        }

        /// The runtime DSL and `#schema` derive the same case from a named
        /// error, so the contract a namespace serves and the enum it
        /// generates agree. For an ASCII identifier the case differs from
        /// the name only in case, and starts with no capital.
        ///
        /// Mutation check: lowering the whole run of leading capitals in
        /// either copy (`URLTooLong` → `urltooLong`) fails here.
        @Test
        func namedErrorCaseNamesAgree() throws {
            try property(
                reaching: ["an ASCII identifier", "no leading capital"],
                reachingAfter: [
                    "a run of capitals before a digit or mark": 1_000,
                    "a run of capitals before a word": 1_000, "all capitals": 1_000,
                    "one leading capital": 1_000,
                ]
            ) { tc in
                let name = try #draw(DeclaredErrorGenerators.typeNames, from: tc)
                let capitals = name.prefix(while: \.isUppercase).count
                let next = name.dropFirst(capitals).first
                try tc.event(
                    capitals == 0
                        ? "no leading capital"
                        : capitals == name.count
                            ? "all capitals"
                            : capitals == 1
                                ? "one leading capital"
                                : next?.isLowercase == true
                                    ? "a run of capitals before a word"
                                    : "a run of capitals before a digit or mark"
                )
                let runtime = MMSchema.errorCaseName(forNamedError: name)
                #expect(runtime == MMSchemaCodeGenerator.errorCaseName(forNamedError: name))
                let isASCIIIdentifier =
                    name.first.map { $0.isASCII && ($0.isLetter || $0 == "_") } ?? false
                    && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
                if isASCIIIdentifier {
                    try tc.event("an ASCII identifier")
                    #expect(runtime.lowercased() == name.lowercased())
                    #expect(runtime.first?.isUppercase == false)
                }
            }
        }

        /// `#schema` accepts a contract's errors exactly when it keeps the
        /// declared-error rules: exit codes in 2...63, `unknown` and `Error`
        /// reserved, no name declared twice or shared with a type,
        /// references to a `Type` or `Error` of the block, no case twice in
        /// a block, and a call's cases apart from the namespace's in name
        /// and exit code.
        ///
        /// Mutation check: dropping the exit-code clash check, or the check
        /// that a call's case does not reuse a namespace case's name, fails
        /// here.
        @Test
        func schemaKeepsTheErrorRules() throws {
            try property(
                reaching: ["accepted"],
                reachingAfter: Dictionary(
                    uniqueKeysWithValues: ErrorRule.allCases.map { ("only \($0.rawValue)", 1_000) }
                )
            ) { tc in
                let contract = try #draw(DeclaredErrorGenerators.contracts, from: tc)
                let violations = contract.violations.map(\.rawValue).sorted()
                for violation in violations { try tc.event(violation) }
                if violations.isEmpty { try tc.event("accepted") }
                if violations.count == 1 { try tc.event("only \(violations[0])") }
                let diagnosis = schemaDiagnosis(contract.source)
                #expect(
                    (diagnosis == nil) == violations.isEmpty,
                    "\(contract.source)\nmodel: \(violations)\n#schema: \(diagnosis ?? "accepted")"
                )
            }
        }
    }

#endif

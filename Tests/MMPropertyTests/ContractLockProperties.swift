// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    import Foundation
    import HegelTesting
    import MMClient
    import MMContractLock
    import MMSchema
    import Testing

    enum LockGenerators {
        /// Doubles at and around their edges, infinities among them, which
        /// the lock writes as text. A NaN is no bound and no default (the
        /// schema refuses both), and the lock's JSON keeps no NaN's sign or
        /// payload, so it becomes an infinity here.
        static let doubles: Gen<Double> = SchemaValueGenerators.doubles(edgeRate: 0.3).map {
            $0.isNaN ? .infinity : $0
        }

        /// Floating numbers, half of them whole, which JSON writes as
        /// integers.
        static let floatings: Gen<Double> = .oneOf(
            doubles,
            SchemaValueGenerators.int64s(edgeRate: 0.3).map { Double($0) }
        )

        static let bounds: Gen<TypeSchema.Bound> = .oneOf(
            SchemaValueGenerators.int64s(edgeRate: 0.3).map { .integer($0) },
            floatings.map { .floating($0) },
            DurationGenerators.durations.map { .duration($0) }
        )

        static let lengths: Gen<Int> = .oneOf(.element(of: [0, 1, -1, .max, .min]), .int())

        /// Rules of every kind, each there or not, so some constraints hold
        /// no rule at all.
        static let constraints: Gen<TypeSchema.Constraints> = Gen { tc in
            TypeSchema.Constraints(
                minimum: try tc.draw(.optional(bounds)),
                maximum: try tc.draw(.optional(bounds)),
                minimumLength: try tc.draw(.optional(lengths)),
                maximumLength: try tc.draw(.optional(lengths)),
                pattern: try tc.draw(.optional(FingerprintGenerators.names))
            )
        }

        /// A default of any kind on any field: the lock writes what the
        /// contract holds, whether or not a reader could take it.
        static let defaults: Gen<TypeSchema.Default> = .oneOf(
            Gen<Bool>.bool().map { .bool($0) },
            SchemaValueGenerators.int64s(edgeRate: 0.3).map { .integer($0) },
            floatings.map { .floating($0) },
            FingerprintGenerators.names.map { .string($0) },
            DurationGenerators.durations.map { .duration($0) }
        )

        static func fields(_ schemas: Gen<TypeSchema>) -> Gen<TypeSchema.Field> {
            Gen { tc in
                TypeSchema.Field(
                    key: try tc.draw(FingerprintGenerators.keys),
                    name: try tc.draw(FingerprintGenerators.names),
                    type: try tc.draw(schemas),
                    description: try tc.draw(FingerprintGenerators.descriptions),
                    constraints: try tc.draw(.optional(constraints)),
                    defaultValue: try tc.draw(.optional(defaults)),
                    deprecation: try tc.draw(FingerprintGenerators.descriptions)
                )
            }
        }

        static func unions(_ schemas: Gen<TypeSchema>) -> Gen<TypeSchema> {
            Gen<[TypeSchema.UnionCase]>.array(
                of: Hegel.zip(
                    FingerprintGenerators.names,
                    .array(of: fields(schemas), count: 0...3),
                    FingerprintGenerators.descriptions
                )
                .map { TypeSchema.UnionCase(name: $0, fields: $1, description: $2) }
            )
            .map { .union(cases: $0) }
        }

        /// Schemas of every kind, nested at most four deep.
        static let schemas: Gen<TypeSchema> = Self.schemas(leaves: FingerprintGenerators.leaves)

        /// Schemas of every kind on `leaves`, nested at most four deep.
        static func schemas(leaves: Gen<TypeSchema>) -> Gen<TypeSchema> {
            .recursive(maxDepth: 4, maxLeaves: 8, leaf: leaves) { schema in
                .oneOf(
                    schema.map { .optional($0) },
                    schema.map { .array($0) },
                    Hegel.zip(schema, schema).map { .map(key: $0, value: $1) },
                    Gen<[TypeSchema.Field]>.array(of: fields(schema), count: 0...4).map {
                        .structure(fields: $0)
                    },
                    Gen<[TypeSchema.EnumCase]>.array(
                        of: FingerprintGenerators.enumCases,
                        count: 0...4
                    )
                    .map { .enumeration(cases: $0) },
                    unions(schema)
                )
            }
        }

        /// A request or response: half the time a structure, as most are.
        static func payloads(_ schemas: Gen<TypeSchema>) -> Gen<TypeSchema> {
            .oneOf(
                Gen<[TypeSchema.Field]>.array(of: fields(schemas), count: 0...4).map {
                    .structure(fields: $0)
                },
                schemas
            )
        }

        static let signatures: Gen<MethodSignature> = Self.signatures(schemas)

        static func signatures(_ schemas: Gen<TypeSchema>) -> Gen<MethodSignature> {
            Gen { tc in
                MethodSignature(
                    name: try tc.draw(FingerprintGenerators.names),
                    access: try tc.draw(FingerprintGenerators.accesses),
                    request: try tc.draw(payloads(schemas)),
                    response: try tc.draw(payloads(schemas)),
                    requestStream: try tc.draw(.optional(schemas)),
                    responseStream: try tc.draw(.optional(schemas)),
                    errors: try tc.draw(.optional(unions(schemas))),
                    description: try tc.draw(FingerprintGenerators.descriptions),
                    deprecation: try tc.draw(FingerprintGenerators.descriptions),
                    target: try tc.draw(FingerprintGenerators.targets)
                )
            }
        }

        static let definitions: Gen<TypeDefinition> = Self.definitions(
            schemas,
            names: FingerprintGenerators.names
        )

        static func definitions(_ schemas: Gen<TypeSchema>, names: Gen<String>) -> Gen<
            TypeDefinition
        > {
            Gen { tc in
                TypeDefinition(
                    name: try tc.draw(names),
                    schema: try tc.draw(schemas),
                    description: try tc.draw(FingerprintGenerators.descriptions),
                    constraints: try tc.draw(.optional(constraints)),
                    deprecation: try tc.draw(FingerprintGenerators.descriptions)
                )
            }
        }

        /// Type names, mostly from a pool of four, so definitions refer to
        /// one another, or any name.
        static let typeNames: Gen<String> = Gen { tc in
            try tc.draw(.bool(probability: 0.8))
                ? try tc.draw(.element(of: ["T", "U", "V", "W"]))
                : try tc.draw(FingerprintGenerators.names)
        }

        /// Schemas whose references name one of `pool` half the time.
        static func referring(to pool: [String]) -> Gen<TypeSchema> {
            Self.schemas(
                leaves: .oneOf(
                    FingerprintGenerators.leaves,
                    Gen<String>.element(of: pool).map { .reference($0) }
                )
            )
        }

        /// A field none of `fields` pairs with: a key none of them has, or
        /// no key, and a name none of them has.
        static func freshField(
            _ tc: TestCase,
            among fields: [TypeSchema.Field],
            type: TypeSchema
        ) throws -> TypeSchema.Field {
            let keys = Set(fields.compactMap(\.key))
            let key = try tc.draw(FingerprintGenerators.keys).map {
                FingerprintGenerators.unusedKey(from: $0, avoiding: keys)
            }
            var name = try tc.draw(FingerprintGenerators.names)
            while fields.contains(where: { $0.name == name }) { name += "'" }
            return TypeSchema.Field(key: key, name: name, type: type)
        }

        /// `elements`, the first of each name kept: a contract's methods
        /// and types each have a name of their own.
        static func uniquelyNamed<Element>(
            _ elements: [Element],
            name: (Element) -> String
        ) -> [Element] {
            var seen: Set<String> = []
            return elements.filter { seen.insert(name($0)).inserted }
        }

        /// A contract's methods and types, each name once.
        static let contracts: Gen<ContractLock> = Hegel.zip(
            .array(of: signatures, count: 0...4),
            .array(of: definitions, count: 0...4)
        )
        .map {
            ContractLock(
                methods: uniquelyNamed($0, name: \.name),
                types: uniquelyNamed($1, name: \.name)
            )
        }
    }

    /// A change to a contract whose judgment the compatibility rule fixes:
    /// the lock is the client, built before the change, and the changed
    /// contract the server.
    enum ContractEdit: String, CaseIterable, Sendable {
        case addMethod = "a method added"
        case removeMethod = "a method removed"
        case changeAccess = "an access changed"
        case addRequiredRequestField = "a required request field added"
        case addOptionalRequestField = "an optional request field added"
        case addRequiredResponseField = "a required response field added"
        case describe = "descriptions changed"

        /// What a peer built against the contract before the edit makes of
        /// the server after it.
        enum Judgment: Sendable {
            case unchanged, compatible, breaking
        }

        var judgment: Judgment {
            switch self {
                case .addMethod, .addOptionalRequestField, .addRequiredResponseField: .compatible
                case .removeMethod, .changeAccess, .addRequiredRequestField: .breaking
                case .describe: .unchanged
            }
        }

        /// The indices of `methods` the edit can change.
        func places(in methods: [MethodSignature]) -> [Int] {
            switch self {
                case .addMethod: [0]
                case .removeMethod, .changeAccess, .describe: Array(methods.indices)
                case .addRequiredRequestField, .addOptionalRequestField:
                    methods.indices.filter {
                        if case .structure = methods[$0].request { true } else { false }
                    }
                case .addRequiredResponseField:
                    methods.indices.filter {
                        if case .structure = methods[$0].response { true } else { false }
                    }
            }
        }

        /// The contract after the edit, or nil when it has no place to make
        /// it.
        func applied(to contract: ContractLock, _ tc: TestCase) throws -> ContractLock? {
            var methods = contract.methods
            let places = self.places(in: methods)
            guard !places.isEmpty else { return nil }
            let place = try tc.draw(Gen<Int>.element(of: places))
            func addField(_ part: WritableKeyPath<MethodSignature, TypeSchema>, optional: Bool)
                throws
            {
                guard case .structure(let fields) = methods[place][keyPath: part] else { return }
                let type = try tc.draw(Gen<TypeSchema>.element(of: CompatibilityGenerators.leaves))
                let added = try LockGenerators.freshField(
                    tc,
                    among: fields,
                    type: optional ? .optional(type) : type
                )
                methods[place][keyPath: part] = .structure(fields: fields + [added])
            }
            switch self {
                case .addMethod:
                    var added = try tc.draw(LockGenerators.signatures)
                    added.name = try CompatibilityGenerators.freshName(
                        tc,
                        avoiding: methods.map(\.name)
                    )
                    methods.append(added)
                case .removeMethod:
                    methods.remove(at: place)
                case .changeAccess:
                    let access = methods[place].access.rawValue
                    let other = try tc.draw(Gen<UInt8>.integer(in: 1...UInt8.max))
                    methods[place].access = AccessMode(rawValue: access &+ other)
                case .addRequiredRequestField:
                    try addField(\.request, optional: false)
                case .addOptionalRequestField:
                    try addField(\.request, optional: true)
                case .addRequiredResponseField:
                    try addField(\.response, optional: false)
                case .describe:
                    let text = try tc.draw(FingerprintGenerators.descriptions)
                    methods[place] = describing(methods[place], text ?? "described")
            }
            return ContractLock(methods: methods, types: contract.types)
        }
    }

    /// What a check finds, without the difference it carries.
    enum CheckKind: String, Sendable {
        case unchanged, compatible, breaking, created, failed

        init(_ outcome: ContractLockCheck.Outcome) {
            switch outcome {
                case .unchanged: self = .unchanged
                case .compatible: self = .compatible
                case .breaking: self = .breaking
                case .created: self = .created
                case .failed: self = .failed
            }
        }
    }

    /// A step of the lock-file property, each followed by a check.
    enum LockStep: String, CaseIterable, Sendable {
        case edit = "the contract edited"
        case delete = "the lock deleted"
        case damage = "the lock damaged"
        case reformat = "the lock reformatted"
        case nothing = "a check again"
    }

    @Suite("Contract lock properties", .hegel, .offTheCooperativePool)
    struct ContractLockProperties {
        /// Every field anywhere in `schema`.
        static func fields(in schema: TypeSchema) -> [TypeSchema.Field] {
            switch schema {
                case .optional(let wrapped), .array(let wrapped): fields(in: wrapped)
                case .map(let key, let value): fields(in: key) + fields(in: value)
                case .structure(let list): list + list.flatMap { fields(in: $0.type) }
                case .union(let cases):
                    cases.flatMap { $0.fields + $0.fields.flatMap { fields(in: $0.type) } }
                default: []
            }
        }

        static func schemas(of lock: ContractLock) -> [TypeSchema] {
            lock.methods.flatMap {
                [$0.request, $0.response]
                    + [$0.requestStream, $0.responseStream, $0.errors].compactMap { $0 }
            } + lock.types.map(\.schema)
        }

        static func unionCases(in schema: TypeSchema) -> [TypeSchema.UnionCase] {
            switch schema {
                case .optional(let wrapped), .array(let wrapped): unionCases(in: wrapped)
                case .map(let key, let value): unionCases(in: key) + unionCases(in: value)
                case .structure(let list): list.flatMap { unionCases(in: $0.type) }
                case .union(let cases):
                    cases + cases.flatMap { $0.fields.flatMap { unionCases(in: $0.type) } }
                default: []
            }
        }

        /// The index of the first hexadecimal digit of a lock text's
        /// fingerprint.
        static func fingerprintDigit(in text: String) -> String.Index? {
            text.range(of: "\"fingerprint\" : \"0x").map(\.upperBound)
        }

        static func isWhole(_ value: Double) -> Bool {
            value.isFinite && value == value.rounded()
        }

        /// A lock reads back from its text as itself, and writes that text
        /// again: every kind, every rule and default of every kind, whole
        /// floating numbers, infinities and negative zeros, durations,
        /// targets, accesses past `rwx`, and any names.
        ///
        /// Mutation check: a floating bound or default written as a bare
        /// number, which reads back as an integer, bits past `rwx` dropped,
        /// constraints with no rule left out, or a union case's fields
        /// dropped, fails here.
        @Test
        func aLockReadsBackAsItsText() throws {
            try property(
                reaching: ["a field", "a method"],
                reachingAfter: [
                    "a whole floating bound": 1_000, "a whole floating default": 1_000,
                    "a duration bound": 1_000, "a duration default": 1_000,
                    "constraints with no rule": 1_000, "an access past rwx": 1_000,
                    "a target": 1_000, "a union case with no fields": 1_000,
                    "a union case with fields": 1_000, "an infinite or negative zero number": 1_000,
                    "a named scalar's constraints": 1_000,
                ]
            ) { tc in
                let lock = try #draw(
                    Hegel.zip(
                        .array(of: LockGenerators.signatures, count: 0...4),
                        .array(of: LockGenerators.definitions, count: 0...4)
                    )
                    .map { ContractLock(methods: $0, types: $1) },
                    from: tc
                )
                let schemas = Self.schemas(of: lock)
                let fields = schemas.flatMap(Self.fields(in:))
                let bounds = fields.compactMap(\.constraints).flatMap { [$0.minimum, $0.maximum] }
                    .compactMap { $0 }
                let floatings =
                    bounds.compactMap { if case .floating(let value) = $0 { value } else { nil } }
                    + fields.compactMap {
                        if case .floating(let value)? = $0.defaultValue { value } else { nil }
                    }
                if !fields.isEmpty { try tc.event("a field") }
                if !lock.methods.isEmpty { try tc.event("a method") }
                if bounds.contains(where: {
                    if case .floating(let value) = $0 { Self.isWhole(value) } else { false }
                }) {
                    try tc.event("a whole floating bound")
                }
                if fields.contains(where: {
                    if case .floating(let value)? = $0.defaultValue {
                        Self.isWhole(value)
                    } else {
                        false
                    }
                }) {
                    try tc.event("a whole floating default")
                }
                if bounds.contains(where: { if case .duration = $0 { true } else { false } }) {
                    try tc.event("a duration bound")
                }
                if fields.contains(where: {
                    if case .duration? = $0.defaultValue { true } else { false }
                }) {
                    try tc.event("a duration default")
                }
                if fields.contains(where: { $0.constraints?.isEmpty == true }) {
                    try tc.event("constraints with no rule")
                }
                if lock.methods.contains(where: {
                    $0.access.rawValue & ~AccessMode.all.rawValue != 0
                }) {
                    try tc.event("an access past rwx")
                }
                if lock.methods.contains(where: { $0.target != nil }) { try tc.event("a target") }
                let cases = schemas.flatMap(Self.unionCases(in:))
                if cases.contains(where: \.fields.isEmpty) {
                    try tc.event("a union case with no fields")
                }
                if cases.contains(where: { !$0.fields.isEmpty }) {
                    try tc.event("a union case with fields")
                }
                if floatings.contains(where: { $0.isInfinite || ($0 == 0 && $0.sign == .minus) }) {
                    try tc.event("an infinite or negative zero number")
                }
                if lock.types.contains(where: { $0.constraints != nil }) {
                    try tc.event("a named scalar's constraints")
                }

                let text = lock.text
                tc.note(text)
                guard case .success(let read) = ContractLock.parse(text) else {
                    Issue.record("the lock's own text did not read: \(ContractLock.parse(text))")
                    return
                }
                #expect(read == lock, "the lock read back as another contract")
                #expect(read.text == text, "the lock read back writes other text")
            }
        }

        /// A lock's text depends only on the contract: not on the order of
        /// its methods and types, not on the order of a target's patterns
        /// or a pattern stated twice, and not on any description or
        /// deprecation.
        ///
        /// Mutation check: methods or types left in declaration order, or
        /// descriptions kept, fails here.
        @Test
        func aLocksTextHoldsOnlyTheContract() throws {
            try property(
                reaching: ["two methods", "two types"],
                reachingAfter: ["two methods of one name": 1_000, "a target restated": 1_000]
            ) { tc in
                let methods = try #draw(
                    .array(of: LockGenerators.signatures, count: 0...4),
                    from: tc
                )
                let types = try #draw(
                    .array(of: LockGenerators.definitions, count: 0...4),
                    from: tc
                )
                if methods.count >= 2 { try tc.event("two methods") }
                if types.count >= 2 { try tc.event("two types") }
                if Set(methods.map(\.name)).count < methods.count {
                    try tc.event("two methods of one name")
                }
                let text = try #draw(FingerprintGenerators.descriptions, from: tc)
                let restatedMethods = try methods.map { method in
                    var described = describing(method, text)
                    if let target = method.target, !target.isEmpty {
                        try tc.event("a target restated")
                        let doubled = try target.filter { _ in try tc.draw(.bool(probability: 0.3))
                        }
                        described.target = try FingerprintGenerators.shuffled(target + doubled, tc)
                    }
                    return described
                }
                let restatedTypes = types.map {
                    TypeDefinition(
                        name: $0.name,
                        schema: describing($0.schema, text),
                        description: text,
                        constraints: $0.constraints,
                        deprecation: text
                    )
                }
                let lock = ContractLock(methods: methods, types: types)
                let restated = ContractLock(
                    methods: try FingerprintGenerators.shuffled(restatedMethods, tc),
                    types: try FingerprintGenerators.shuffled(restatedTypes, tc)
                )
                #expect(restated.text == lock.text, "the same contract restated wrote other text")
                #expect(restated == lock, "the same contract restated locked another")
            }
        }

        /// A lock judges a contract as verification judges a server for a
        /// peer built against the lock: itself unchanged; an added method,
        /// an optional request field or a required response field
        /// compatible; a removed method, a changed access or a required
        /// request field breaking; and descriptions nothing at all.
        ///
        /// Mutation check: the lock judged as the server and the contract as
        /// the client fails here.
        @Test
        func aLockJudgesAsAPeerBuiltAgainstIt() throws {
            try property(
                reachingAfter: Dictionary(
                    uniqueKeysWithValues: ContractEdit.allCases.map { ($0.rawValue, 1_000) }
                )
            ) { tc in
                let locked = try #draw(LockGenerators.contracts, from: tc)
                #expect(locked.difference(to: locked).isEmpty, "a lock judged itself changed")
                let edit = try #draw(Gen<ContractEdit>.element(of: ContractEdit.allCases), from: tc)
                guard let current = try edit.applied(to: locked, tc) else { return }
                try tc.event(edit.rawValue)
                let difference = locked.difference(to: current)
                tc.note("difference: \(difference); breaks: \(difference.breakingReasons)")
                switch edit.judgment {
                    case .unchanged:
                        #expect(difference.isEmpty, "\(edit.rawValue), judged a change")
                    case .compatible:
                        #expect(!difference.isEmpty, "\(edit.rawValue), judged no change")
                        #expect(!difference.isBreaking, "\(edit.rawValue), judged breaking")
                    case .breaking:
                        #expect(difference.isBreaking, "\(edit.rawValue), judged compatible")
                }
            }
        }

        /// A contract's lock holds exactly the named types its methods
        /// reach, directly or through other types, a name both a contract
        /// and the shared types define taken from the contract, and no type
        /// no method reaches.
        ///
        /// Mutation check: only the types a method names directly locked,
        /// or the shared definition taken over the contract's own, fails
        /// here.
        @Test
        func aLockHoldsTheTypesItsMethodsReach() throws {
            try property(
                reaching: ["a type reached"],
                reachingAfter: [
                    "a type reached only through another": 1_000, "a shared type reached": 1_000,
                    "a type no method reaches": 1_000, "a name both sides define, reached": 1_000,
                ]
            ) { tc in
                // Methods name only half the pool, so the rest is reached, if
                // at all, through other types.
                let methods = try #draw(
                    .array(
                        of: LockGenerators.signatures(LockGenerators.referring(to: ["T", "U"])),
                        count: 0...3
                    ),
                    from: tc
                )
                let definitions = LockGenerators.definitions(
                    LockGenerators.referring(to: ["T", "U", "V", "W"]),
                    names: LockGenerators.typeNames
                )
                let own = try #draw(.array(of: definitions, count: 0...4), from: tc)
                let shared = try #draw(.array(of: definitions, count: 0...3), from: tc)
                let contract = SchemaDeclaration(namespace: "n", signatures: methods, types: own)
                let lock = ContractLock(
                    [contract],
                    sharedTypes: [TypeNamespaceDeclaration(namespace: "s", types: shared)]
                )

                // The model: names referenced, grown until no reached
                // definition adds one; a name's first definition stands for it.
                var first: [String: TypeDefinition] = [:]
                for definition in own + shared where first[definition.name] == nil {
                    first[definition.name] = definition
                }
                func referenced(_ schema: TypeSchema) -> Set<String> {
                    var names: Set<String> = []
                    schema.collectReferencedTypeNames(into: &names)
                    return names
                }
                var direct: Set<String> = []
                for method in methods { method.collectReferencedTypeNames(into: &direct) }
                var reached = direct
                var growing = true
                while growing {
                    growing = false
                    for name in reached {
                        guard let definition = first[name] else { continue }
                        let more = referenced(definition.schema).subtracting(reached)
                        if !more.isEmpty {
                            reached.formUnion(more)
                            growing = true
                        }
                    }
                }
                let expected = reached.compactMap { first[$0]?.strippingDescriptions }
                    .sorted { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }

                if !expected.isEmpty { try tc.event("a type reached") }
                if expected.contains(where: { !direct.contains($0.name) }) {
                    try tc.event("a type reached only through another")
                }
                let ownNames = Set(own.map(\.name))
                if expected.contains(where: { !ownNames.contains($0.name) }) {
                    try tc.event("a shared type reached")
                }
                if (own + shared).contains(where: { !reached.contains($0.name) }) {
                    try tc.event("a type no method reaches")
                }
                if expected.contains(where: { name in
                    ownNames.contains(name.name) && shared.contains { $0.name == name.name }
                }) {
                    try tc.event("a name both sides define, reached")
                }
                #expect(lock.types == expected, "the lock holds other types than its methods reach")
            }
        }

        /// The lock file follows its checks, one after each step: a check
        /// writes the contract where there is no lock and fails, passes and
        /// leaves the file for the locked contract, passes and writes the
        /// contract for a compatible change, and fails and leaves the file
        /// for a breaking change or a damaged lock; a lock laid out another
        /// way still holds its contract, and deleting the lock lets the next
        /// check write it anew.
        ///
        /// Mutation check: a check that writes the lock on a break, leaves
        /// it on a compatible change or where there is none, reads a damaged
        /// lock, takes a lock laid out another way for a change, or passes
        /// where there was no lock, fails here.
        @Test
        func theLockFileFollowsItsChecks() throws {
            try property(
                reaching: [
                    "created", "unchanged", "the lock deleted", "the contract edited",
                    "the lock damaged",
                ],
                reachingAfter: [
                    "compatible": 1_000, "breaking": 1_000, "failed": 1_000,
                    "a check after a break": 1_000, "a damaged lock": 1_000,
                    "the locked contract written another way": 1_000,
                ]
            ) { tc in
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("mm-lock-property-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: directory) }
                let path = directory.appendingPathComponent("lock.json").path
                func file() -> String? {
                    (try? Data(contentsOf: URL(fileURLWithPath: path))).map {
                        String(decoding: $0, as: UTF8.self)
                    }
                }

                var contract = try #draw(LockGenerators.contracts, from: tc)
                // The model: the file's text, and whether it is a lock the
                // check reads.
                var modelFile: String? = nil
                var damaged = false
                var lastBroke = false
                let steps = try #draw(
                    .array(of: Gen<LockStep>.element(of: LockStep.allCases), count: 1...8),
                    from: tc
                )
                for step in steps {
                    switch step {
                        case .nothing:
                            try tc.event(step.rawValue)
                        case .edit:
                            let edit = try tc.draw(
                                Gen<ContractEdit>.element(of: ContractEdit.allCases)
                            )
                            if let edited = try edit.applied(to: contract, tc) {
                                contract = edited
                                try tc.event(step.rawValue)
                            }
                        case .delete:
                            try? FileManager.default.removeItem(atPath: path)
                            modelFile = nil
                            damaged = false
                            try tc.event(step.rawValue)
                        case .reformat:
                            // The same JSON laid out another way: a raw line
                            // break never falls inside a JSON string, so
                            // removing each, and the indentation after it,
                            // keeps every value.
                            guard let text = file() else { break }
                            let compact = text.split(separator: "\n")
                                .map { $0.drop(while: { $0 == " " }) }
                                .joined()
                            try Data(compact.utf8).write(to: URL(fileURLWithPath: path))
                            modelFile = compact
                            try tc.event(step.rawValue)
                        case .damage:
                            guard let text = file() else { break }
                            // The fingerprint's first digit changed, which
                            // reads as a damaged lock, or the text cut short,
                            // which does not read at all.
                            let changed: String
                            if try tc.draw(.bool()), let digit = Self.fingerprintDigit(in: text) {
                                let digits = Array("0123456789abcdef")
                                let place = digits.firstIndex(of: text[digit]) ?? 0
                                changed = text.replacingCharacters(
                                    in: digit...digit,
                                    with: String(digits[(place + 1) % digits.count])
                                )
                                try tc.event("a fingerprint digit changed")
                            } else {
                                changed = String(text.prefix(text.count / 2))
                            }
                            try Data(changed.utf8).write(to: URL(fileURLWithPath: path))
                            modelFile = changed
                            damaged = true
                            try tc.event(step.rawValue)
                    }

                    let expected: CheckKind
                    let expectedFile: String?
                    if let locked = modelFile {
                        if damaged {
                            expected = .failed
                            expectedFile = locked
                        } else if locked == contract.text {
                            expected = .unchanged
                            expectedFile = locked
                        } else if case .success(let lock) = ContractLock.parse(locked),
                            lock == contract
                        {
                            try tc.event("the locked contract written another way")
                            expected = .unchanged
                            expectedFile = locked
                        } else if case .success(let lock) = ContractLock.parse(locked),
                            lock.difference(to: contract).isBreaking
                        {
                            expected = .breaking
                            expectedFile = locked
                        } else {
                            expected = .compatible
                            expectedFile = contract.text
                        }
                    } else {
                        expected = .created
                        expectedFile = contract.text
                    }
                    if lastBroke { try tc.event("a check after a break") }
                    let check = contract.check(lockFileAt: path)
                    let found = CheckKind(check.outcome)
                    if case .failed(.damaged) = check.outcome { try tc.event("a damaged lock") }
                    try tc.event(found.rawValue)
                    tc.note("check: \(check)")
                    #expect(found == expected, "expected \(expected), found \(check)")
                    #expect(
                        file() == expectedFile,
                        "after \(found.rawValue), the file is not what the check leaves"
                    )
                    #expect(
                        check.passed == (expected == .unchanged || expected == .compatible),
                        "\(found.rawValue) passed as \(check.passed)"
                    )
                    modelFile = expectedFile
                    lastBroke = expected == .breaking
                }
            }
        }
    }

#endif
